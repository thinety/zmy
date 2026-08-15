const std = @import("std");

const Client = @import("Client.zig");
const Daemon = @import("Daemon.zig");

pub const std_options: std.Options = .{
    // TODO: FIXME: submit patch to zig (errno=111 below)
    .unexpected_error_tracing = true,
};
const log = std.log.scoped(.zmy);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const rundir = if (init.environ_map.get("ZMY_DIR")) |zmy_rundir|
        try arena.dupe(u8, zmy_rundir)
    else if (init.environ_map.get("XDG_RUNTIME_DIR")) |xdg_rundir|
        try std.fs.path.join(arena, &.{ xdg_rundir, "zmy" })
    else
        try arena.dupe(u8, "/tmp/zmy");

    std.Io.Dir.cwd().createDir(io, rundir, @enumFromInt(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const session_name = init.environ_map.get("ZMY_SESSION");

    const shell = init.environ_map.get("SHELL") orelse "/bin/sh";

    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse return help(io);

    if (std.mem.eql(u8, cmd, "daemon")) {
        const session_name_ = args.next() orelse session_name orelse return help(io);
        return runDaemon(
            gpa,
            io,
            rundir,
            try arena.dupeZ(u8, session_name_),
            try arena.dupeZ(u8, shell),
        );
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        const session_name_ = args.next() orelse session_name orelse return help(io);
        try closeStderrIfTty();
        return runAttach(gpa, io, rundir, try arena.dupeZ(u8, session_name_));
    }

    return help(io);
}

fn help(io: std.Io) !void {
    const help_text =
        \\zmy - session persistence for terminal processes
        \\
        \\Usage: zmy <command> [args...]
        \\
        \\Commands:
        \\  attach <name>               Attach to session, creating if needed
        \\  daemon <name>               Runs the daemon process
        \\  help                        Show this help
        \\
    ;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    stdout_writer.writeAll(help_text) catch |err| switch (err) {
        error.WriteFailed => return stdout_file_writer.err.?,
    };
    stdout_writer.flush() catch |err| switch (err) {
        error.WriteFailed => return stdout_file_writer.err.?,
    };
}

fn runDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    rundir: []const u8,
    session_name: [:0]const u8,
    shell: [:0]const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ rundir, session_name });
    defer gpa.free(path);

    const address: std.Io.net.UnixAddress = try .init(path);

    var daemon = try Daemon.init(io, address, shell);
    defer daemon.deinit();

    try daemon.loop();
}

fn runAttach(
    gpa: std.mem.Allocator,
    io: std.Io,
    rundir: []const u8,
    session_name: [:0]const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ rundir, session_name });
    defer gpa.free(path);

    const address: std.Io.net.UnixAddress = try .init(path);

    var client = client: {
        var retries: u32 = 0;
        while (true) {
            if (Client.init(io, address)) |client| {
                break :client client;
            } else |err| switch (err) {
                error.FileNotFound,
                error.Unexpected, // errno=111 ECONNREFUSED
                => if (retries == 2) return err,
                else => return err,
            }
            if (retries == 0) {
                try spawnDaemon(rundir, session_name);
            }
            try io.sleep(.fromMilliseconds(50), .real);
            retries += 1;
        }
    };
    defer client.deinit();

    try client.loop();
}

fn spawnDaemon(rundir: []const u8, session_name: [:0]const u8) !void {
    // by forking, we allow the parent to continue, and we also guarantee that the
    // new process is not a process group leader. otherwise, `setsid()` would fail.
    const pid = std.c.fork();
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {}", .{err});
            return error.ForkError;
        },
    }
    if (pid > 0) return;
    defer comptime unreachable;

    // become a session leader. we now have no controlling terminal.
    switch (std.c.errno(std.c.setsid())) {
        .SUCCESS => {},
        else => |err| {
            log.err("setsid() failed: {}", .{err});
            std.process.exit(1);
        },
    }

    // some daemon implementations would fork again here (the so-called
    // "double fork technique"), but one can argue that that's a bit paranoid.
    // we control the daemon process and we know that it won't open a
    // terminal device file, so we'll never acquire a controlling terminal.

    // open /dev/null as stdin and stdout
    {
        const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        switch (std.c.errno(dev_null)) {
            .SUCCESS => {},
            else => |err| {
                log.err("open(/dev/null, O_RDWR) failed: {}", .{err});
                std.process.exit(1);
            },
        }
        inline for (.{ std.c.STDIN_FILENO, std.c.STDOUT_FILENO }) |fd| {
            switch (std.c.errno(std.c.dup2(dev_null, fd))) {
                .SUCCESS => {},
                else => |err| {
                    log.err("dup2({}, {}) failed: {}", .{ dev_null, fd, err });
                    std.process.exit(1);
                },
            }
        }
        switch (std.c.errno(std.c.close(dev_null))) {
            .SUCCESS => {},
            else => |err| {
                log.err("close({}) failed: {}", .{ dev_null, err });
                std.process.exit(1);
            },
        }
    }

    // open log file as stderr
    {
        var buffer: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();

        const filename = std.fmt.allocPrint(alloc, "{s}.log", .{session_name}) catch |err| switch (err) {
            error.OutOfMemory => {
                log.err("log filename too long", .{});
                std.process.exit(1);
            },
        };
        const path = std.fs.path.joinZ(alloc, &.{ rundir, filename }) catch |err| switch (err) {
            error.OutOfMemory => {
                log.err("log filepath too long", .{});
                std.process.exit(1);
            },
        };

        const log_file = std.c.open(
            path,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            @as(std.c.mode_t, 0o644),
        );
        switch (std.c.errno(log_file)) {
            .SUCCESS => {},
            else => |err| {
                log.err("open({s}, O_RDWR | O_CREAT) failed: {}", .{ path, err });
                std.process.exit(1);
            },
        }
        switch (std.c.errno(std.c.dup2(log_file, std.c.STDERR_FILENO))) {
            .SUCCESS => {},
            else => |err| {
                log.err("dup2({}, {}) failed: {}", .{ log_file, std.c.STDERR_FILENO, err });
                std.process.exit(1);
            },
        }
        switch (std.c.errno(std.c.close(log_file))) {
            .SUCCESS => {},
            else => |err| {
                log.err("close({}) failed: {}", .{ log_file, err });
                std.process.exit(1);
            },
        }
    }

    // execve to restart into the daemon command
    switch (std.c.errno(std.c.execve(
        "/proc/self/exe",
        &.{ "zmy", "daemon", session_name },
        std.c.environ,
    ))) {
        .SUCCESS => unreachable,
        else => std.process.exit(1),
    }
}

fn closeStderrIfTty() !void {
    if (std.c.isatty(std.c.STDERR_FILENO) == 0) {
        return;
    }

    const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    switch (std.c.errno(dev_null)) {
        .SUCCESS => {},
        else => return error.OpenError,
    }

    switch (std.c.errno(std.c.dup2(dev_null, std.c.STDERR_FILENO))) {
        .SUCCESS => {},
        else => return error.Dup2Error,
    }

    switch (std.c.errno(std.c.close(dev_null))) {
        .SUCCESS => {},
        else => return error.CloseError,
    }
}

const std = @import("std");

const client = @import("client/client.zig");
const daemon = @import("daemon/daemon.zig");
const proxy = @import("proxy/proxy.zig");

pub const std_options: std.Options = .{
    // TODO(thiago): FIXME: submit patch to zig (errno=111 below)
    .unexpected_error_tracing = false,
};
const log = std.log.scoped(.zmy);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    const rundir =
        environ_map.get("ZMY_DIR") orelse
        if (environ_map.get("XDG_RUNTIME_DIR")) |xdg_rundir|
            try std.fs.path.join(arena, &.{ xdg_rundir, "zmy" })
        else
            "/tmp/zmy";

    std.Io.Dir.cwd().createDir(io, rundir, @enumFromInt(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const session = environ_map.get("ZMY_SESSION");

    const shell =
        if (environ_map.get("SHELL")) |s|
            try arena.dupeZ(u8, s)
        else
            "/bin/sh";

    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse return help(io);

    if (std.mem.eql(u8, cmd, "daemon")) {
        const session_name = args.next() orelse return help(io);

        return runDaemon(
            gpa,
            io,
            rundir,
            session_name,
            shell,
        );
    }

    if (std.mem.eql(u8, cmd, "proxy")) {
        const address = args.next() orelse return help(io);
        const port = args.next() orelse return help(io);

        return runProxy(
            gpa,
            io,
            address,
            port,
            rundir,
        );
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        const session_name = args.next() orelse return help(io);

        if (session) |s| {
            if (std.mem.eql(u8, session_name, s)) {
                return error.RecursiveAttach;
            }
        }

        return runAttach(
            gpa,
            io,
            rundir,
            session_name,
        );
    }

    if (std.mem.eql(u8, cmd, "connect")) {
        const destination = args.next() orelse return help(io);
        const port = args.next() orelse return help(io);
        const session_name = args.next() orelse return help(io);

        return runConnect(
            gpa,
            io,
            destination,
            port,
            session_name,
        );
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
        \\  attach <session-name>                           Attach to session, creating if needed
        \\  connect <destination> <port> <session-name>     Attach to remote session
        \\  daemon <session-name>                           Runs the daemon process
        \\  proxy <address> <port>                          Runs the proxy process
        \\  help                                            Show this help
        \\
    ;

    var stdout_file_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout_writer = &stdout_file_writer.interface;

    stdout_writer.writeAll(help_text) catch |err| switch (err) {
        error.WriteFailed => return stdout_file_writer.err.?,
    };
}

fn runDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    rundir: []const u8,
    session_name: []const u8,
    shell: [:0]const u8,
) !void {
    const path = try std.fs.path.join(gpa, &.{ rundir, session_name });
    defer gpa.free(path);

    const address: std.Io.net.UnixAddress = try .init(path);
    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            try std.Io.Dir.deleteFileAbsolute(io, address.path);
            break :blk try address.listen(io, .{});
        },
        else => |e| return e,
    };
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, address.path) catch {};
    }

    try daemon.run(gpa, io, &server, session_name, shell);
}

fn runProxy(
    gpa: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    port: []const u8,
    rundir: []const u8,
) !void {
    const port_ = try std.fmt.parseInt(u16, port, 10);
    const address_: std.Io.net.IpAddress = try .parse(address, port_);
    var server = try address_.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try proxy.run(gpa, io, &server, rundir);
}

fn runAttach(
    gpa: std.mem.Allocator,
    io: std.Io,
    rundir: []const u8,
    session_name: [:0]const u8,
) !void {
    const stream = try connectToSocket(gpa, io, rundir, session_name);
    defer stream.close(io);

    try client.run(gpa, io, stream);
}

fn runConnect(
    gpa: std.mem.Allocator,
    io: std.Io,
    destination: []const u8,
    port: []const u8,
    session_name: []const u8,
) !void {
    const port_ = try std.fmt.parseInt(u16, port, 10);
    const address = std.Io.net.IpAddress.parse(destination, port_) catch {
        // TODO(thiago): support for hostnames
        return;
    };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // for now we do the most basic session negotiation possible:
    // we say which session we want and hope for the best
    {
        var buffer: [256]u8 = undefined;
        var stream_writer = stream.writer(io, &buffer);
        const writer = &stream_writer.interface;

        writer.writeInt(usize, session_name.len, .little) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
        };
        writer.writeAll(session_name) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
        };

        try writer.flush();
    }

    try client.run(gpa, io, stream);
}

pub fn connectToSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    rundir: []const u8,
    session_name: [:0]const u8,
) !std.Io.net.Stream {
    const path = try std.fs.path.join(gpa, &.{ rundir, session_name });
    defer gpa.free(path);

    const address: std.Io.net.UnixAddress = try .init(path);

    var retries: u32 = 0;
    while (true) {
        const stream = address.connect(io) catch |err| switch (err) {
            error.FileNotFound,
            error.Unexpected, // errno=111 ECONNREFUSED
            => |e| {
                if (retries == 2) return e;
                if (retries == 0) try spawnDaemon(rundir, session_name);
                try io.sleep(.fromMilliseconds(50), .real);
                retries += 1;
                continue;
            },
            else => |e| return e,
        };
        return stream;
    }
}

fn spawnDaemon(rundir: []const u8, session_name: [:0]const u8) !void {
    // by forking, we allow the parent to continue, and we also guarantee that the
    // new process is not a process group leader. otherwise, `setsid()` would fail.
    const pid = std.c.fork();
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {t}", .{err});
            return error.Fork;
        },
    }
    if (pid > 0) return;
    defer comptime unreachable;

    // become a session leader. we now have no controlling terminal.
    switch (std.c.errno(std.c.setsid())) {
        .SUCCESS => {},
        else => |err| {
            log.err("setsid() failed: {t}", .{err});
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
                log.err("open(/dev/null, O_RDWR) failed: {t}", .{err});
                std.process.exit(1);
            },
        }
        inline for (.{ std.c.STDIN_FILENO, std.c.STDOUT_FILENO }) |fd| {
            switch (std.c.errno(std.c.dup2(dev_null, fd))) {
                .SUCCESS => {},
                else => |err| {
                    log.err("dup2({}, {}) failed: {t}", .{ dev_null, fd, err });
                    std.process.exit(1);
                },
            }
        }
        switch (std.c.errno(std.c.close(dev_null))) {
            .SUCCESS => {},
            else => |err| {
                log.err("close({}) failed: {t}", .{ dev_null, err });
                std.process.exit(1);
            },
        }
    }

    // open log file as stderr
    {
        const filename = std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}.log",
            .{session_name},
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                log.err("out of memory", .{});
                std.process.exit(1);
            },
        };
        const path = std.fs.path.joinZ(
            std.heap.page_allocator,
            &.{ rundir, filename },
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                log.err("out of memory", .{});
                std.process.exit(1);
            },
        };

        const log_file = std.c.open(
            path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o644),
        );
        switch (std.c.errno(log_file)) {
            .SUCCESS => {},
            else => |err| {
                log.err("open({s}, O_WRONLY | O_CREAT | O_TRUNC, 0o644) failed: {t}", .{ path, err });
                std.process.exit(1);
            },
        }
        switch (std.c.errno(std.c.dup2(log_file, std.c.STDERR_FILENO))) {
            .SUCCESS => {},
            else => |err| {
                log.err("dup2({}, {}) failed: {t}", .{ log_file, std.c.STDERR_FILENO, err });
                std.process.exit(1);
            },
        }
        switch (std.c.errno(std.c.close(log_file))) {
            .SUCCESS => {},
            else => |err| {
                log.err("close({}) failed: {t}", .{ log_file, err });
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
        else => |err| {
            log.err("execve() failed: {t}", .{err});
            std.process.exit(1);
        },
    }
}

const std = @import("std");
const c = @import("c");
const async = @import("async.zig");

const DaemonEvent = @import("Daemon/daemon.zig").Event;
const mainLoop = @import("Daemon/daemon.zig").mainLoop;
const PtyEvent = @import("Daemon/pty.zig").Event;
const handlePty = @import("Daemon/pty.zig").handlePty;

const log = std.log.scoped(.zmy_daemon);

const Daemon = @This();

pty: std.Io.File,
server: std.Io.net.Server,
socket_path: []const u8,

/// keeps a reference to `address` until `deinit` is called
pub fn init(io: std.Io, shell: [:0]const u8, address: std.Io.net.UnixAddress) !Daemon {
    const pty = try spawnShell(shell);
    errdefer pty.close(io);

    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            try std.Io.Dir.deleteFileAbsolute(io, address.path);
            break :blk try address.listen(io, .{});
        },
        else => |e| return e,
    };
    errdefer server.deinit(io);

    return .{
        .pty = pty,
        .server = server,
        .socket_path = address.path,
    };
}

pub fn deinit(self: *Daemon, io: std.Io) void {
    self.pty.close(io);
    self.server.deinit(io);
    std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
    self.* = undefined;
}

pub fn loop(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) !void {
    var event_queue_buffer: [16]DaemonEvent = undefined;
    var event_queue: std.Io.Queue(DaemonEvent) = .init(&event_queue_buffer);
    defer {
        event_queue.close(io);
        while (true) {
            var event = event_queue.getOne(io) catch break;
            event.deinit(gpa, io);
        }
    }

    var pty_queue_buffer: [8]PtyEvent = undefined;
    var pty_queue: std.Io.Queue(PtyEvent) = .init(&pty_queue_buffer);
    defer {
        pty_queue.close(io);
        while (true) {
            var event = pty_queue.getOne(io) catch break;
            event.deinit(gpa);
        }
    }

    try try async.race(io, .{
        .{ acceptLoop, .{ io, &self.server, &event_queue } },
        .{ mainLoop, .{ gpa, io, &event_queue, &pty_queue } },
        .{ handlePty, .{ gpa, io, self.pty, &pty_queue, &event_queue } },
    });
}

fn acceptLoop(
    io: std.Io,
    server: *std.Io.net.Server,
    queue: *std.Io.Queue(DaemonEvent),
) !void {
    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        try queue.putOne(io, .{ .new_client = stream });
    }
}

fn spawnShell(shell: [:0]const u8) !std.Io.File {
    var pty_fd: std.c.fd_t = undefined;
    const pid = c.forkpty(&pty_fd, null, null, null);
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {t}", .{err});
            return error.ForkError;
        },
    }
    if (pid > 0) return .{
        .handle = pty_fd,
        .flags = .{ .nonblocking = false },
    };
    defer comptime unreachable;

    switch (std.c.errno(std.c.execve(
        shell,
        &.{shell},
        std.c.environ,
    ))) {
        .SUCCESS => unreachable,
        else => |err| {
            log.err("execve() failed: {t}", .{err});
            std.process.exit(1);
        },
    }
}

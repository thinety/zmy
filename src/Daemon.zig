const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.zmy);

const Daemon = @This();

io: std.Io,
socket_path: []const u8,
server: std.Io.net.Server,

/// keeps a reference to `address` until `deinit` is called
pub fn init(io: std.Io, address: std.Io.net.UnixAddress, shell: [:0]const u8) !Daemon {
    try spawnShell(shell);

    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            try std.Io.Dir.deleteFileAbsolute(io, address.path);
            break :blk try address.listen(io, .{});
        },
        else => return err,
    };
    errdefer server.deinit(io);

    return .{ .io = io, .socket_path = address.path, .server = server };
}

pub fn deinit(self: *Daemon) void {
    std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
    self.server.deinit(self.io);
    self.* = undefined;
}

pub fn loop(self: *Daemon) !void {
    try self.io.sleep(.fromSeconds(100), .real);
}

fn spawnShell(shell: [:0]const u8) !void {
    var pty_fd: std.c.fd_t = undefined;
    const pid = c.forkpty(&pty_fd, null, null, null);
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {}", .{err});
            return error.ForkError;
        },
    }
    if (pid > 0) return;
    defer comptime unreachable;

    switch (std.c.errno(std.c.execve(
        shell,
        &.{shell},
        std.c.environ,
    ))) {
        .SUCCESS => unreachable,
        else => std.process.exit(1),
    }
}

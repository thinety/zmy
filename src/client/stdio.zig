const std = @import("std");
const client = @import("client.zig");

pub fn readStdin(
    gpa: std.mem.Allocator,
    io: std.Io,
    event_queue: *std.Io.Queue(client.Event),
) !void {
    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const reader = &stdin_reader.interface;

    while (true) {
        var buffer: [4096]u8 = undefined;
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => return stdin_reader.err.?,
                else => |e| return e,
            };
        }

        const data = try gpa.dupe(u8, buffer[0..n]);
        errdefer gpa.free(data);

        const event: client.Event = .{ .stdin = data };
        try event_queue.putOne(io, event);
    }
}

pub fn writeStdout(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout_queue: *std.Io.Queue([]u8),
) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout_writer.interface;

    while (true) {
        const data = try stdout_queue.getOne(io);
        defer gpa.free(data);

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return stdout_writer.err.?,
            else => |e| return e,
        };
    }
}

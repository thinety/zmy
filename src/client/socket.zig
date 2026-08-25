const std = @import("std");
const ipc = @import("../ipc.zig");
const client = @import("client.zig");

pub fn readSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(client.Event),
) !void {
    var buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &buffer);
    const reader = &stream_reader.interface;

    while (true) {
        var message = ipc.DaemonMessage.deserialize(gpa, reader) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };
        errdefer message.deinit(gpa);

        const event: client.Event = .{ .daemon_message = message };
        try event_queue.putOne(io, event);
    }
}

pub fn writeSocket(
    io: std.Io,
    message_queue: *std.Io.Queue(ipc.ClientMessage),
    stream: std.Io.net.Stream,
) !void {
    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        var message = try message_queue.getOne(io);
        defer message.deinit();

        message.serialize(writer) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
            else => |e| return e,
        };
    }
}

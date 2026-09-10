const std = @import("std");
const ipc = @import("../ipc.zig");
const client = @import("client.zig");

pub fn readSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(client.Event),
) !void {
    var stream_reader_buffer: [256]u8 = undefined;
    var stream_reader = stream.reader(io, &stream_reader_buffer);

    while (true) {
        var message = ipc.DaemonMessage.deserialize(gpa, &stream_reader.interface) catch |err|
            switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return stream_reader.err.?,
                else => |e| return e,
            };
        errdefer message.deinit(gpa);

        const event: client.Event = .{ .daemon_message = message };
        try event_queue.putOne(io, event);
    }
}

pub fn writeSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    message_queue: *std.Io.Queue(ipc.ClientMessage),
    stream: std.Io.net.Stream,
) !void {
    var stream_writer_buffer: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &stream_writer_buffer);

    while (true) {
        var message = try message_queue.getOne(io);
        defer message.deinit(gpa);

        message.serialize(&stream_writer.interface) catch |err|
            switch (err) {
                error.WriteFailed => return stream_writer.err.?,
            };
        stream_writer.interface.flush() catch |err|
            switch (err) {
                error.WriteFailed => return stream_writer.err.?,
            };
    }
}

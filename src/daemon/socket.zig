const std = @import("std");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.zmy_daemon);

pub fn handleClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    client: *anyopaque,
    initial_message: ipc.DaemonInitialMessage,
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    event_queue: *std.Io.Queue(daemon.Event),
) void {
    handleClient_(
        gpa,
        io,
        stream,
        client,
        initial_message,
        message_queue,
        event_queue,
    ) catch |err| switch (err) {
        error.Canceled => {},
        else => |e| {
            log.err("handleClient error: {t}", .{e});
        },
    };
}

pub fn handleClient_(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    client: *anyopaque,
    initial_message: ipc.DaemonInitialMessage,
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    defer {
        message_queue.close(io);

        const event: daemon.Event = .{ .client_disconnected = .{
            .client = client,
        } };
        event_queue.putOneUncancelable(io, event) catch |err| switch (err) {
            error.Closed => unreachable,
        };
    }

    try try async.race(io, .{
        .{ readSocket, .{ gpa, io, stream, event_queue, client } },
        .{ writeSocket, .{ gpa, io, message_queue, stream, initial_message } },
    });
}

fn readSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(daemon.Event),
    client: *anyopaque,
) !void {
    var buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &buffer);
    const reader = &stream_reader.interface;

    {
        const message = ipc.ClientInitialMessage.deserialize(reader) catch |err| switch (err) {
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };

        const event: daemon.Event = .{ .client_initial_message = .{
            .client = client,
            .message = message,
        } };
        try event_queue.putOne(io, event);
    }

    while (true) {
        var message = ipc.ClientMessage.deserialize(gpa, reader) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };
        errdefer message.deinit(gpa);

        const event: daemon.Event = .{ .client_message = .{
            .client = client,
            .message = message,
        } };
        try event_queue.putOne(io, event);
    }
}

fn writeSocket(
    gpa: std.mem.Allocator,
    io: std.Io,
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    stream: std.Io.net.Stream,
    initial_message: ipc.DaemonInitialMessage,
) !void {
    var buffer: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &buffer);
    const writer = &stream_writer.interface;

    initial_message.serialize(writer) catch |err| switch (err) {
        error.WriteFailed => return stream_writer.err.?,
        else => |e| return e,
    };
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return stream_writer.err.?,
        else => |e| return e,
    };

    while (true) {
        var message = try message_queue.getOne(io);
        defer message.deinit(gpa);

        message.serialize(writer) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
            else => |e| return e,
        };
        writer.flush() catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
            else => |e| return e,
        };
    }
}

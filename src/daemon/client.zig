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
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    event_queue: *std.Io.Queue(daemon.Event),
) void {
    handleClient_(
        gpa,
        io,
        stream,
        client,
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
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    try try async.race(io, .{
        .{ readSocket, .{ gpa, io, stream, event_queue, client } },
        .{ writeSocket, .{ gpa, io, message_queue, stream } },
    });

    message_queue.close(io);

    const event: daemon.Event = .{ .client_disconnected = client };
    event_queue.putOneUncancelable(io, event) catch |err| switch (err) {
        error.Closed => unreachable,
    };
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
) !void {
    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        var message = try message_queue.getOne(io);
        defer message.deinit(gpa);

        message.serialize(writer) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
            else => |e| return e,
        };
    }
}

const std = @import("std");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.zmy_daemon_client);

pub fn handleClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    client: *anyopaque,
    message_queue: *std.Io.Queue(ipc.DaemonMessage),
    event_queue: *std.Io.Queue(daemon.Event),
) void {
    async.race(io, .{
        .{ readSocket, .{ io, stream, event_queue, client } },
        .{ writeSocket, .{ gpa, io, message_queue, stream } },
    }) catch |err| switch (err) {
        error.Canceled => {},
        else => |e| {
            log.err("race error: {t}", .{e});
        },
    } catch |err| {
        log.err("readSocket/writeSocket error: {t}", .{err});
    };

    const event: daemon.Event = .{ .client_disconnected = client };
    event_queue.putOne(io, event) catch |err| switch (err) {
        error.Closed => unreachable,
        error.Canceled => {},
    };

    message_queue.close(io);
}

fn readSocket(
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(daemon.Event),
    client: *anyopaque,
) !void {
    var buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &buffer);
    const reader = &stream_reader.interface;

    while (true) {
        var message = ipc.ClientMessage.deserialize(reader) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };
        errdefer message.deinit();

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

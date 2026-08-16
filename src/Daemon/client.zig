const std = @import("std");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.zmy_daemon_client);

pub const Event = union(enum) {
    data: []u8,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .data => |data| {
                gpa.free(data);
            },
        }
    }
};

pub fn handleClient(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(daemon.Event),
    client_queue: *std.Io.Queue(Event),
) void {
    // this is how we communicate the client is dead
    defer client_queue.close(io);

    async.race(io, .{
        .{ readStream, .{ gpa, io, stream, event_queue } },
        .{ writeStream, .{ gpa, io, stream, client_queue } },
    }) catch |err| switch (err) {
        error.Canceled => {},
        else => |e| {
            log.err("race error: {t}", .{e});
        },
    } catch |err| {
        log.err("readStream/writeStream error: {t}", .{err});
    };
}

fn readStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    var buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &buffer);
    const reader = &stream_reader.interface;

    readStream_(gpa, io, reader, event_queue) catch |err| switch (err) {
        error.ReadFailed => return stream_reader.err.?,
        else => |e| return e,
    };
}

fn readStream_(
    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    while (true) {
        const message = ipc.ClientMessage.deserialize(reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        switch (message) {
            .resize => |payload| {
                log.info(
                    "ClientMessage.resize: width={} height={} x_pixel={} y_pixel={}",
                    .{ payload.width, payload.height, payload.x_pixel, payload.y_pixel },
                );

                // TODO
            },
            .data => |payload| {
                const data = try gpa.alloc(u8, payload.length);
                errdefer gpa.free(data);

                try reader.readSliceAll(data);

                log.info("ClientMessage.data: data={x}", .{data});

                try event_queue.putOne(io, .{ .pty_input = data });
            },
        }
    }
}

fn writeStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    client_queue: *std.Io.Queue(Event),
) !void {
    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    writeStream_(gpa, io, client_queue, writer) catch |err| switch (err) {
        error.WriteFailed => return stream_writer.err.?,
        else => |e| return e,
    };
}

fn writeStream_(
    gpa: std.mem.Allocator,
    io: std.Io,
    client_queue: *std.Io.Queue(Event),
    writer: *std.Io.Writer,
) !void {
    while (true) {
        var event = try client_queue.getOne(io);
        errdefer event.deinit(gpa);

        switch (event) {
            .data => |data| {
                log.info("Event.data: data={x}", .{data});

                const message: ipc.DaemonMessage = .{ .data = .{ .length = data.len } };

                try message.serialize(writer);
                try writer.writeAll(data);

                gpa.free(data);
            },
        }
    }
}

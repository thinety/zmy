const std = @import("std");
const async = @import("async.zig");
const ipc = @import("ipc.zig");

const log = std.log.scoped(.zmy_client);

const Client = @This();

stream: std.Io.net.Stream,

pub fn init(io: std.Io, address: std.Io.net.UnixAddress) !Client {
    var stream = try address.connect(io);
    errdefer stream.close(io);

    return .{
        .stream = stream,
    };
}

pub fn deinit(self: *Client, io: std.Io) void {
    self.stream.close(io);
    self.* = undefined;
}

pub fn loop(self: *Client, gpa: std.mem.Allocator, io: std.Io) !void {
    try try async.race(io, .{
        .{ readStream, .{ gpa, io, self.stream } },
        .{ writeStream, .{ io, self.stream } },
    });
}

fn readStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    var buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &buffer);
    const reader = &stream_reader.interface;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout_writer.interface;

    readStream_(gpa, reader, writer) catch |err| switch (err) {
        error.ReadFailed => return stream_reader.err.?,
        error.WriteFailed => return stdout_writer.err.?,
        else => |e| return e,
    };
}

fn readStream_(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    while (true) {
        const message = ipc.DaemonMessage.deserialize(reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        switch (message) {
            .data => |payload| {
                const data = try gpa.alloc(u8, payload.length);
                defer gpa.free(data);

                try reader.readSliceAll(data);

                log.info("DaemonMessage.data: data={b64}", .{data});

                try writer.writeAll(data);
            },
        }
    }
}

fn writeStream(
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const reader = &stdin_reader.interface;

    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    writeStream_(reader, writer) catch |err| switch (err) {
        error.ReadFailed => return stdin_reader.err.?,
        error.WriteFailed => return stream_writer.err.?,
        else => |e| return e,
    };
}

fn writeStream_(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = try reader.readVec(&buffers);
        }

        const data = buffer[0..n];
        const message: ipc.ClientMessage = .{ .data = .{ .length = data.len } };

        try message.serialize(writer);
        try writer.writeAll(data);
    }
}

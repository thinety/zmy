const std = @import("std");
const async = @import("async.zig");

const log = std.log.scoped(.zmy);

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

pub fn loop(self: *Client, io: std.Io) !void {
    _ = try try async.tryJoin(io, .{
        .{ readStream, .{ io, self.stream } },
        .{ writeStream, .{ io, self.stream } },
    });
}

fn readStream(
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    var buffer: [4096]u8 = undefined;

    var stream_reader = stream.reader(io, &.{});
    const reader = &stream_reader.interface;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout_writer.interface;

    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => return stream_reader.err.?,
                else => |e| return e,
            };
        }

        const data = buffer[0..n];

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return stdout_writer.err.?,
        };
    }
}

fn writeStream(
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    var buffer: [4096]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const reader = &stdin_reader.interface;

    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => return stdin_reader.err.?,
                else => |e| return e,
            };
        }

        const data = buffer[0..n];

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
        };
    }
}

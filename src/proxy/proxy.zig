const std = @import("std");
const async = @import("../async.zig");
const main = @import("../main.zig");

const log = std.log.scoped(.zmy_proxy);

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    rundir: []const u8,
) !void {
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        try connections.concurrent(
            io,
            handleConnection,
            .{ gpa, io, stream, rundir },
        );
    }
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    rundir: []const u8,
) void {
    log.info("handling connection: stream={}", .{stream.socket.handle});

    handleConnection_(
        gpa,
        io,
        stream,
        rundir,
    ) catch |err| switch (err) {
        error.Canceled => {},
        else => |e| {
            log.err("handleConnection error: {t}", .{e});
        },
    };

    log.info("closing connection: stream={}", .{stream.socket.handle});
}

fn handleConnection_(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    rundir: []const u8,
) !void {
    defer stream.close(io);

    const len = len: {
        // we have to be very careful with the size of our buffers, in order
        // not to read into the first messages and lose data
        var buffer: usize = undefined;
        var stream_reader = stream.reader(io, std.mem.asBytes(&buffer));
        const reader = &stream_reader.interface;

        break :len reader.takeInt(usize, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };
    };

    const session_name = try gpa.alloc(u8, len + 1);
    defer gpa.free(session_name);

    {
        var stream_reader = stream.reader(io, &.{});
        const reader = &stream_reader.interface;

        reader.readSliceAll(session_name[0..len]) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return stream_reader.err.?,
            else => |e| return e,
        };
        session_name[len] = 0;
    }

    const local_stream = try main.connectToSocket(gpa, io, rundir, session_name[0..len :0]);
    defer local_stream.close(io);

    try try async.race(io, .{
        .{ remoteToLocal, .{ io, stream, local_stream } },
        .{ localToRemote, .{ io, stream, local_stream } },
    });
}

fn remoteToLocal(
    io: std.Io,
    remote_stream: std.Io.net.Stream,
    local_stream: std.Io.net.Stream,
) !void {
    var stream_reader = remote_stream.reader(io, &.{});
    const reader = &stream_reader.interface;

    var stream_writer = local_stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        var buffer: [4096]u8 = undefined;
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return stream_reader.err.?,
                else => |e| return e,
            };

            const data = buffer[0..n];
            log.info("remote -> local: data.len={} data={b64}{s}", .{
                data.len,
                data[0..@min(data.len, 48)],
                if (data.len > 48) "..." else "",
            });

            writer.writeAll(data) catch |err| switch (err) {
                error.WriteFailed => return stream_writer.err.?,
            };
        }
    }
}

fn localToRemote(
    io: std.Io,
    remote_stream: std.Io.net.Stream,
    local_stream: std.Io.net.Stream,
) !void {
    var stream_reader = local_stream.reader(io, &.{});
    const reader = &stream_reader.interface;

    var stream_writer = remote_stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        var buffer: [4096]u8 = undefined;
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return stream_reader.err.?,
                else => |e| return e,
            };

            const data = buffer[0..n];
            log.info("local -> remote: data.len={} data={b64}{s}", .{
                data.len,
                data[0..@min(data.len, 48)],
                if (data.len > 48) "..." else "",
            });

            writer.writeAll(data) catch |err| switch (err) {
                error.WriteFailed => return stream_writer.err.?,
                else => |e| return e,
            };
        }
    }
}

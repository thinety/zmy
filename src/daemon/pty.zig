const std = @import("std");
const daemon = @import("daemon.zig");

pub fn readPty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    // instead of using a buffer and
    // - reader.fillMore()
    // - reader.buffered()
    // - reader.tossBuffered()
    // we just call reader.readVec() directly on our buffer.
    var file_reader = pty.reader(io, &.{});
    const reader = &file_reader.interface;

    while (true) {
        var buffer: [4096]u8 = undefined;
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => switch (file_reader.err.?) {
                    error.InputOutput => return, // this is the error when the shell exits
                    else => |e| return e,
                },
                else => |e| return e,
            };
        }

        const data = try gpa.dupe(u8, buffer[0..n]);
        errdefer gpa.free(data);

        const event: daemon.Event = .{ .ptyout = data };
        try event_queue.putOne(io, event);
    }
}

pub fn writePty(
    gpa: std.mem.Allocator,
    io: std.Io,
    ptyin_queue: *std.Io.Queue([]u8),
    pty: std.Io.File,
) !void {
    // no buffer, all data is written immediately
    var file_writer = pty.writer(io, &.{});
    const writer = &file_writer.interface;

    while (true) {
        const data = try ptyin_queue.getOne(io);
        defer gpa.free(data);

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return file_writer.err.?,
            else => |e| return e,
        };
    }
}

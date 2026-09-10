const std = @import("std");
const daemon = @import("daemon.zig");

pub fn readPty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    var file_reader_buffer: [4096]u8 = undefined;
    var file_reader = pty.reader(io, &file_reader_buffer);

    while (true) {
        file_reader.interface.fillMore() catch |err|
            switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => switch (file_reader.err.?) {
                    error.InputOutput => return, // this is the error when the shell exits
                    else => |e| return e,
                },
            };

        const buffered = file_reader.interface.buffered();
        file_reader.interface.tossBuffered();

        const data = try gpa.dupe(u8, buffered);
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
    var file_writer = pty.writer(io, &.{});

    while (true) {
        const data = try ptyin_queue.getOne(io);
        defer gpa.free(data);

        file_writer.interface.writeAll(data) catch |err|
            switch (err) {
                error.WriteFailed => return file_writer.err.?,
            };
    }
}

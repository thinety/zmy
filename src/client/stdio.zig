const std = @import("std");
const client = @import("client.zig");

pub fn readStdin(
    gpa: std.mem.Allocator,
    io: std.Io,
    event_queue: *std.Io.Queue(client.Event),
) !void {
    var stdin_reader_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_reader_buffer);

    while (true) {
        stdin_reader.interface.fillMore() catch |err|
            switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return stdin_reader.err.?,
            };

        const buffered = stdin_reader.interface.buffered();
        stdin_reader.interface.tossBuffered();

        const data = try gpa.dupe(u8, buffered);
        errdefer gpa.free(data);

        const event: client.Event = .{ .stdin = data };
        try event_queue.putOne(io, event);
    }
}

pub fn writeStdout(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout_queue: *std.Io.Queue([]u8),
) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});

    while (true) {
        const data = try stdout_queue.getOne(io);
        defer gpa.free(data);

        stdout_writer.interface.writeAll(data) catch |err|
            switch (err) {
                error.WriteFailed => return stdout_writer.err.?,
            };
    }
}

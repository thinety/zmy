const std = @import("std");
const async = @import("../async.zig");
const daemon = @import("daemon.zig");

const log = std.log.scoped(.zmy_daemon_pty);

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

pub fn handlePty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    pty_queue: *std.Io.Queue(Event),
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    try try async.race(io, .{
        .{ readPty, .{ gpa, io, pty, event_queue } },
        .{ writePty, .{ gpa, io, pty, pty_queue } },
    });
}

fn readPty(
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

    readPty_(gpa, io, reader, event_queue) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.InputOutput => {}, // this is the error when the shell exits
            else => |e| return e,
        },
        else => |e| return e,
    };
}

fn readPty_(
    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    event_queue: *std.Io.Queue(daemon.Event),
) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = try reader.readVec(&buffers);
        }

        const data = try gpa.alloc(u8, n);
        errdefer gpa.free(data);

        @memcpy(data, buffer[0..n]);

        try event_queue.putOne(io, .{ .pty_output = data });
    }
}

fn writePty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    pty_queue: *std.Io.Queue(Event),
) !void {
    // no buffer, all data is written immediately
    var file_writer = pty.writer(io, &.{});
    const writer = &file_writer.interface;

    writePty_(gpa, io, pty_queue, writer) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
        else => |e| return e,
    };
}

fn writePty_(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty_queue: *std.Io.Queue(Event),
    writer: *std.Io.Writer,
) !void {
    while (true) {
        var event = try pty_queue.getOne(io);
        errdefer event.deinit(gpa);

        switch (event) {
            .data => |data| {
                log.info("Event.data: data={x}", .{data});

                try writer.writeAll(data);

                gpa.free(data);
            },
        }
    }
}

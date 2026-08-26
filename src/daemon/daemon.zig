const std = @import("std");
const ghostty = @import("ghostty-vt");
const c = @import("c");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const client_mod = @import("client.zig");
const pty_mod = @import("pty.zig");
const stream_mod = @import("ghostty/stream.zig");
const formatter_mod = @import("ghostty/formatter.zig");

const log = std.log.scoped(.zmy_daemon);

pub const Event = union(enum) {
    client_connected: std.Io.net.Stream,
    client_message: struct {
        client: *anyopaque,
        message: ipc.ClientMessage,
    },
    client_disconnected: *anyopaque,
    ptyout: []u8,

    fn deinit(self: *Event, gpa: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .client_connected => |stream| {
                stream.close(io);
            },
            .client_message => |*client_message| {
                client_message.message.deinit(gpa);
            },
            .client_disconnected => |client_ptr| {
                _ = client_ptr;
            },
            .ptyout => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, shell: [:0]const u8, address: std.Io.net.UnixAddress) !void {
    const pty = try spawnShell(shell);
    defer pty.close(io);

    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            try std.Io.Dir.deleteFileAbsolute(io, address.path);
            break :blk try address.listen(io, .{});
        },
        else => |e| return e,
    };
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, address.path) catch {};
    }

    var event_queue_buffer: [16]Event = undefined;
    var event_queue: std.Io.Queue(Event) = .init(&event_queue_buffer);
    defer {
        event_queue.close(io);
        while (true) {
            var event = event_queue.getOne(io) catch break;
            event.deinit(gpa, io);
        }
    }

    var ptyin_queue_buffer: [8][]u8 = undefined;
    var ptyin_queue: std.Io.Queue([]u8) = .init(&ptyin_queue_buffer);
    defer {
        ptyin_queue.close(io);
        while (true) {
            const data = ptyin_queue.getOne(io) catch break;
            gpa.free(data);
        }
    }

    try try async.race(io, .{
        .{ pty_mod.readPty, .{ gpa, io, pty, &event_queue } },
        .{ pty_mod.writePty, .{ gpa, io, &ptyin_queue, pty } },
        .{ acceptLoop, .{ io, &server, &event_queue } },
        .{ mainLoop, .{ gpa, io, pty, &event_queue, &ptyin_queue } },
    });
}

fn acceptLoop(
    io: std.Io,
    server: *std.Io.net.Server,
    event_queue: *std.Io.Queue(Event),
) !void {
    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        const event: Event = .{ .client_connected = stream };
        try event_queue.putOne(io, event);
    }
}

const Client = struct {
    node: std.DoublyLinkedList.Node = .{},
    stream: std.Io.net.Stream,
    winsize: ?ipc.Winsize,
    message_queue_buffer: [8]ipc.DaemonMessage = undefined,
    message_queue: std.Io.Queue(ipc.DaemonMessage),
    task: std.Io.Future(void),

    fn deinit(self: *Client, gpa: std.mem.Allocator, io: std.Io) void {
        self.task.cancel(io);
        self.message_queue.close(io);
        while (true) {
            var message = self.message_queue.getOne(io) catch break;
            message.deinit(gpa);
        }
        self.stream.close(io);
        self.* = undefined;
    }
};

fn mainLoop(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    event_queue: *std.Io.Queue(Event),
    ptyin_queue: *std.Io.Queue([]u8),
) !void {
    var clients: std.DoublyLinkedList = .{};
    defer {
        var it = clients.first;
        while (it) |node| {
            const client: *Client = @fieldParentPtr("node", node);
            it = node.next;

            client.deinit(gpa, io);
            gpa.destroy(client);
        }
    }

    var pty_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer pty_buffer.deinit();

    var vt_stream_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer vt_stream_buffer.deinit();

    var term = try ghostty.Terminal.init(io, gpa, .{
        .cols = default_winsize.col,
        .rows = default_winsize.row,
    });
    defer term.deinit(gpa);

    var vt_stream_handler: stream_mod.Handler = .init(
        gpa,
        io,
        &pty_buffer.writer,
        &vt_stream_buffer.writer,
        &term,
    );
    var vt_stream = ghostty.Stream(stream_mod.Handler).init(.{
        .allocator = gpa,
        .handler = vt_stream_handler,
    });
    defer vt_stream.deinit();

    while (true) {
        const event = try event_queue.getOne(io);
        switch (event) {
            .client_connected => |stream| {
                errdefer stream.close(io);
                log.info("Event.client_connected: stream={}", .{stream.socket.handle});

                const client = try gpa.create(Client);
                errdefer gpa.destroy(client);

                var message_queue: std.Io.Queue(ipc.DaemonMessage) = .init(&client.message_queue_buffer);
                errdefer {
                    message_queue.close(io);
                    while (true) {
                        var message = message_queue.getOne(io) catch break;
                        message.deinit(gpa);
                    }
                }

                const task = try io.concurrent(
                    client_mod.handleClient,
                    .{ gpa, io, stream, client, &client.message_queue, event_queue },
                );
                errdefer task.cancel(io);

                client.* = .{
                    .stream = stream,
                    .winsize = null,
                    .message_queue = message_queue,
                    .task = task,
                };
                clients.append(&client.node);
            },
            .client_message => |client_message| {
                switch (client_message.message) {
                    .resize => |winsize| {
                        log.info(
                            "ClientMessage.resize: col={} row={} xpixel={} ypixel={}",
                            .{ winsize.col, winsize.row, winsize.xpixel, winsize.ypixel },
                        );

                        const client: *Client = @ptrCast(@alignCast(client_message.client));
                        const first_winsize = client.winsize == null;
                        client.winsize = winsize;

                        try doResize(clients, &vt_stream_handler, pty);
                        if (pty_buffer.written().len > 0) {
                            defer pty_buffer.clearRetainingCapacity();

                            const ptyin_data = try gpa.dupe(u8, pty_buffer.written());
                            errdefer gpa.free(ptyin_data);

                            try ptyin_queue.putOne(io, ptyin_data);
                        }

                        if (first_winsize) {
                            var allocating: std.Io.Writer.Allocating = .init(gpa);
                            defer allocating.deinit();

                            try formatter_mod.formatTerminal(&term, &allocating.writer);

                            if (allocating.writer.buffered().len > 0) {
                                const data = try allocating.toOwnedSlice();
                                errdefer gpa.free(data);

                                const message: ipc.DaemonMessage = .{ .data = data };
                                try client.message_queue.putOne(io, message);
                            }
                        }
                    },
                    .data => |data| {
                        errdefer gpa.free(data);
                        log.info("ClientMessage.data: data.len={} data={b64}{s}", .{
                            data.len,
                            data[0..@min(data.len, 48)],
                            if (data.len > 48) "..." else "",
                        });

                        try ptyin_queue.putOne(io, data);
                    },
                }
            },
            .client_disconnected => |client_ptr| {
                const client: *Client = @ptrCast(@alignCast(client_ptr));
                log.info("Event.client_disconnected: stream={}", .{client.stream.socket.handle});

                clients.remove(&client.node);
                client.deinit(gpa, io);
                gpa.destroy(client);

                try doResize(clients, &vt_stream_handler, pty);
                if (pty_buffer.written().len > 0) {
                    defer pty_buffer.clearRetainingCapacity();

                    const ptyin_data = try gpa.dupe(u8, pty_buffer.written());
                    errdefer gpa.free(ptyin_data);

                    try ptyin_queue.putOne(io, ptyin_data);
                }
            },
            .ptyout => |data| {
                defer gpa.free(data);
                log.info("Event.ptyout: data.len={} data={b64}{s}", .{
                    data.len,
                    data[0..@min(data.len, 48)],
                    if (data.len > 48) "..." else "",
                });

                vt_stream.nextSlice(data);

                if (pty_buffer.written().len > 0) {
                    defer pty_buffer.clearRetainingCapacity();

                    const ptyin_data = try gpa.dupe(u8, pty_buffer.written());
                    errdefer gpa.free(ptyin_data);

                    try ptyin_queue.putOne(io, ptyin_data);
                }

                if (vt_stream_buffer.written().len > 0) {
                    defer vt_stream_buffer.clearRetainingCapacity();

                    var it = clients.first;
                    while (it) |node| : (it = node.next) {
                        const client: *Client = @fieldParentPtr("node", node);

                        // client hasn't properly connected yet
                        if (client.winsize == null) continue;

                        // TODO(thiago): use reference counting instead of copying data
                        const client_data = try gpa.dupe(u8, vt_stream_buffer.written());
                        const message: ipc.DaemonMessage = .{ .data = client_data };
                        client.message_queue.putOne(io, message) catch |err| {
                            gpa.free(client_data);
                            switch (err) {
                                error.Closed => {},
                                error.Canceled => |e| return e,
                            }
                        };
                    }
                }
            },
        }
    }
}

const default_winsize: ipc.Winsize = .{
    .col = 80,
    .row = 24,
    .xpixel = 0,
    .ypixel = 0,
};

fn doResize(
    clients: std.DoublyLinkedList,
    vt_stream_handler: *stream_mod.Handler,
    pty: std.Io.File,
) !void {
    var optional_final_winsize: ?ipc.Winsize = null;

    var it = clients.first;
    while (it) |node| : (it = node.next) {
        const client: *Client = @fieldParentPtr("node", node);

        const winsize = client.winsize orelse continue;

        if (optional_final_winsize) |*final_winsize| {
            final_winsize.col = @min(final_winsize.col, winsize.col);
            final_winsize.row = @min(final_winsize.row, winsize.row);
            final_winsize.xpixel = @min(final_winsize.xpixel, winsize.xpixel);
            final_winsize.ypixel = @min(final_winsize.ypixel, winsize.ypixel);
        } else {
            optional_final_winsize = winsize;
        }
    }

    const final_winsize = optional_final_winsize orelse default_winsize;

    try vt_stream_handler.resize(.{
        .cols = final_winsize.col,
        .rows = final_winsize.row,
        .cell_size_px = .{
            .width = final_winsize.xpixel / final_winsize.col,
            .height = final_winsize.ypixel / final_winsize.row,
        },
    });

    // twice to force redraw
    switch (std.c.errno(std.c.ioctl(pty.handle, std.c.T.IOCSWINSZ, &std.c.winsize{
        .col = final_winsize.col,
        .row = final_winsize.row,
        .xpixel = 0,
        .ypixel = 0,
    }))) {
        .SUCCESS => {},
        else => |err| {
            log.err("ioctl({}, T.IOCSWINSZ) failed: {t}", .{ pty.handle, err });
            return error.Ioctl;
        },
    }
    switch (std.c.errno(std.c.ioctl(pty.handle, std.c.T.IOCSWINSZ, &std.c.winsize{
        .col = final_winsize.col,
        .row = final_winsize.row,
        .xpixel = final_winsize.xpixel,
        .ypixel = final_winsize.ypixel,
    }))) {
        .SUCCESS => {},
        else => |err| {
            log.err("ioctl({}, T.IOCSWINSZ) failed: {t}", .{ pty.handle, err });
            return error.Ioctl;
        },
    }
}

fn spawnShell(shell: [:0]const u8) !std.Io.File {
    var pty_fd: c_int = undefined;
    const winsize: c.struct_winsize = .{
        .ws_col = default_winsize.col,
        .ws_row = default_winsize.row,
        .ws_xpixel = default_winsize.xpixel,
        .ws_ypixel = default_winsize.ypixel,
    };
    const pid = c.forkpty(&pty_fd, null, null, &winsize);
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {t}", .{err});
            return error.Fork;
        },
    }
    if (pid > 0) return .{
        .handle = pty_fd,
        .flags = .{ .nonblocking = false },
    };
    defer comptime unreachable;

    switch (std.c.errno(std.c.execve(
        shell,
        &.{shell},
        std.c.environ,
    ))) {
        .SUCCESS => unreachable,
        else => |err| {
            log.err("execve() failed: {t}", .{err});
            std.process.exit(1);
        },
    }
}

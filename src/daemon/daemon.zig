const std = @import("std");
const ghostty = @import("ghostty-vt");
const c = @import("c");
const constants = @import("constants");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const socket_mod = @import("socket.zig");
const pty_mod = @import("pty.zig");
const stream_mod = @import("ghostty/stream.zig");
const formatter_mod = @import("ghostty/formatter.zig");

const log = std.log.scoped(.zmy_daemon);

pub const Event = union(enum) {
    client_connected: std.Io.net.Stream,
    client_initial_message: struct {
        client: *anyopaque,
        message: ipc.ClientInitialMessage,
    },
    client_message: struct {
        client: *anyopaque,
        message: ipc.ClientMessage,
    },
    client_disconnected: struct {
        client: *anyopaque,
    },
    ptyout: []u8,

    fn deinit(self: *Event, gpa: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .client_connected => |stream| {
                stream.close(io);
            },
            .client_initial_message => |*payload| {
                _ = payload;
            },
            .client_message => |*payload| {
                payload.message.deinit(gpa);
            },
            .client_disconnected => |*payload| {
                _ = payload;
            },
            .ptyout => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    session_name: []const u8,
    shell: [:0]const u8,
) !void {
    var winsize: ipc.Winsize = .{
        .col = 80,
        .row = 24,
        .xpixel = 0,
        .ypixel = 0,
    };
    const pty = try spawnShell(winsize, shell, session_name);
    defer pty.close(io);

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
        .{ acceptLoop, .{ io, server, &event_queue } },
        .{ mainLoop, .{ gpa, io, pty, &winsize, &event_queue, &ptyin_queue } },
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
    id: ipc.ClientId,
    winsize: ?ipc.Winsize,
    stream: std.Io.net.Stream,
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
    last_winsize: *ipc.Winsize,
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
        .cols = last_winsize.col,
        .rows = last_winsize.row,
    });
    defer term.deinit(gpa);

    var vt_stream_handler: stream_mod.Handler = .init(
        gpa,
        io,
        &pty_buffer.writer,
        &vt_stream_buffer.writer,
        &term,
    );
    var vt_stream = ghostty.Stream(*stream_mod.Handler).init(.{
        .allocator = gpa,
        .handler = &vt_stream_handler,
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

                io.random(&client.id);
                client.winsize = null;
                client.stream = stream;

                client.message_queue = .init(&client.message_queue_buffer);
                errdefer {
                    client.message_queue.close(io);
                    while (true) {
                        var message = client.message_queue.getOne(io) catch break;
                        message.deinit(gpa);
                    }
                }

                const initial_message: ipc.DaemonInitialMessage = .{
                    .client_id = client.id,
                };
                client.task = try io.concurrent(
                    socket_mod.handleClient,
                    .{
                        gpa,
                        io,
                        stream,
                        client,
                        initial_message,
                        &client.message_queue,
                        event_queue,
                    },
                );
                errdefer client.task.cancel(io);

                clients.append(&client.node);
            },
            .client_initial_message => |payload| {
                const client: *Client = @ptrCast(@alignCast(payload.client));
                log.info("Event.client_initial_message: stream={}", .{client.stream.socket.handle});

                std.debug.assert(client.winsize == null);
                client.winsize = payload.message.winsize;

                var allocating: std.Io.Writer.Allocating = .init(gpa);
                defer allocating.deinit();

                try formatter_mod.formatTerminal(&term, &allocating.writer);

                if (allocating.writer.buffered().len > 0) {
                    const data = try allocating.toOwnedSlice();
                    const message: ipc.DaemonMessage = .{ .data = data };
                    client.message_queue.putOne(io, message) catch |err| {
                        gpa.free(data);
                        switch (err) {
                            error.Closed => {},
                            else => |e| return e,
                        }
                    };
                }
            },
            .client_message => |payload| {
                switch (payload.message) {
                    .resize => |winsize| {
                        log.info(
                            "ClientMessage.resize: col={} row={} xpixel={} ypixel={}",
                            .{ winsize.col, winsize.row, winsize.xpixel, winsize.ypixel },
                        );

                        const client: *Client = @ptrCast(@alignCast(payload.client));
                        client.winsize = winsize;

                        try doResize(clients, &vt_stream_handler, pty, last_winsize);
                        if (pty_buffer.written().len > 0) {
                            defer pty_buffer.clearRetainingCapacity();

                            const ptyin_data = try gpa.dupe(u8, pty_buffer.written());
                            errdefer gpa.free(ptyin_data);

                            try ptyin_queue.putOne(io, ptyin_data);
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
            .client_disconnected => |payload| {
                const client: *Client = @ptrCast(@alignCast(payload.client));
                log.info("Event.client_disconnected: stream={}", .{client.stream.socket.handle});

                // TODO(thiago): we should actually have some proper shutdown messages
                // instead of just closing the stream (which is done on `client.deinit`
                // below).
                //
                // most of the times the client receives "FIN", the TCP
                // connection is shutdown gracefully, and it breaks out of the
                // read loop because of an `error.EndOfStream`. but sometimes
                // we actually send a TCP "RST" because there's still data in
                // that socket's read buffer, and this is surfaced on the client
                // by means of an `error.ConnectionResetByPeer`.
                //
                // in summary, the client cannot tell why they're shutting down
                // only based on the reason they break out of the read loop,
                // because both `EndOfStream` and `ConnectionResetByPeer` can be
                // raised on both graceful exit (inner pty closed because shell exited)
                // and error conditions (client attached recursively or they're too slow).

                clients.remove(&client.node);
                client.deinit(gpa, io);
                gpa.destroy(client);

                try doResize(clients, &vt_stream_handler, pty, last_winsize);
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

                for (vt_stream_handler.detach_requests.items) |*client_id| {
                    var it = clients.first;
                    while (it) |node| : (it = node.next) {
                        const client: *Client = @fieldParentPtr("node", node);

                        if (std.mem.eql(u8, client_id, &client.id)) {
                            client.message_queue.close(io);
                        }
                    }
                }
                vt_stream_handler.detach_requests.clearRetainingCapacity();

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

                        // client hasn't initialized yet
                        if (client.winsize == null) continue;

                        // ideally we should use some kind of reference counting here
                        // instead of copying the same data to every client
                        const client_data = try gpa.dupe(u8, vt_stream_buffer.written());
                        const message: ipc.DaemonMessage = .{ .data = client_data };
                        async.timeout(io, .fromMilliseconds(200), .real, .{
                            @TypeOf(client.message_queue).putOne,
                            .{ &client.message_queue, io, message },
                        }) catch |err| {
                            gpa.free(client_data);
                            switch (err) {
                                error.Closed => {},
                                error.Timeout => {
                                    log.warn("client was too slow, dropping: stream={}", .{client.stream.socket.handle});
                                    client.message_queue.close(io);
                                },
                                else => |e| return e,
                            }
                        };
                    }
                }
            },
        }
    }
}

fn doResize(
    clients: std.DoublyLinkedList,
    vt_stream_handler: *stream_mod.Handler,
    pty: std.Io.File,
    last_winsize: *ipc.Winsize,
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

    var final_winsize = optional_final_winsize orelse return;

    if (final_winsize.col == last_winsize.col and
        final_winsize.row == last_winsize.row and
        final_winsize.xpixel == last_winsize.xpixel and
        final_winsize.ypixel == last_winsize.ypixel)
    {
        // make sure to be different from the last winsize, in order to guarantee
        // that a SIGWINCH is delivered to the child process
        final_winsize.xpixel ^= 1;
    }
    last_winsize.* = final_winsize;

    try vt_stream_handler.resize(.{
        .cols = final_winsize.col,
        .rows = final_winsize.row,
        .cell_size_px = .{
            .width = @divFloor(final_winsize.xpixel, final_winsize.col),
            .height = @divFloor(final_winsize.ypixel, final_winsize.row),
        },
    });

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

fn spawnShell(
    initial_winsize: ipc.Winsize,
    shell: [:0]const u8,
    session_name: []const u8,
) !std.Io.File {
    var pty_fd: c_int = undefined;
    const winsize: c.struct_winsize = .{
        .ws_col = initial_winsize.col,
        .ws_row = initial_winsize.row,
        .ws_xpixel = initial_winsize.xpixel,
        .ws_ypixel = initial_winsize.ypixel,
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

    const shellEnviron = createShellEnviron(
        std.heap.page_allocator,
        session_name,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("out of memory", .{});
            std.process.exit(1);
        },
    };

    switch (std.c.errno(std.c.execve(
        shell,
        &.{shell},
        shellEnviron,
    ))) {
        .SUCCESS => unreachable,
        else => |err| {
            log.err("execve() failed: {t}", .{err});
            std.process.exit(1);
        },
    }
}

fn createShellEnviron(
    arena: std.mem.Allocator,
    session_name: []const u8,
) ![*:null]?[*:0]const u8 {
    var environ: std.ArrayList(?[*:0]const u8) = .empty;

    var i: usize = 0;
    while (std.c.environ[i]) |env| : (i += 1) {
        const e = std.mem.span(env);
        if (std.mem.startsWith(u8, e, "TERM=")) continue;
        if (std.mem.startsWith(u8, e, "TERM_PROGRAM=")) continue;
        if (std.mem.startsWith(u8, e, "TERM_PROGRAM_VERSION=")) continue;
        if (std.mem.startsWith(u8, e, "COLORTERM=")) continue;
        if (std.mem.startsWith(u8, e, "ZMY_SESSION=")) continue;

        try environ.append(arena, env);
    }

    for ([_]?[*:0]const u8{
        "TERM=" ++ constants.TERM,
        "TERM_PROGRAM=" ++ constants.PROGRAM_NAME,
        "TERM_PROGRAM_VERSION=" ++ constants.PROGRAM_VERSION,
        "COLORTERM=truecolor",
        try std.fmt.allocPrintSentinel(
            arena,
            "ZMY_SESSION={s}",
            .{session_name},
            0,
        ),
        null,
    }) |e| {
        try environ.append(arena, e);
    }

    return environ.items[0 .. environ.items.len - 1 :null].ptr;
}

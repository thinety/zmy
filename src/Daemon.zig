const std = @import("std");
const c = @import("c");
const async = @import("async.zig");

const log = std.log.scoped(.zmy);

const Daemon = @This();

pty: std.Io.File,
server: std.Io.net.Server,
socket_path: []const u8,

/// keeps a reference to `address` until `deinit` is called
pub fn init(io: std.Io, shell: [:0]const u8, address: std.Io.net.UnixAddress) !Daemon {
    const pty = try spawnShell(shell);
    errdefer pty.close(io);

    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            try std.Io.Dir.deleteFileAbsolute(io, address.path);
            break :blk try address.listen(io, .{});
        },
        else => return err,
    };
    errdefer server.deinit(io);

    return .{
        .pty = pty,
        .server = server,
        .socket_path = address.path,
    };
}

pub fn deinit(self: *Daemon, io: std.Io) void {
    self.pty.close(io);
    self.server.deinit(io);
    std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
    self.* = undefined;
}

fn spawnShell(shell: [:0]const u8) !std.Io.File {
    var pty_fd: std.c.fd_t = undefined;
    const pid = c.forkpty(&pty_fd, null, null, null);
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork() failed: {t}", .{err});
            return error.ForkError;
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
        else => std.process.exit(1),
    }
}

const Event = union(enum) {
    new_client: std.Io.net.Stream,
    pty_input: []u8,
    pty_output: []u8,

    fn deinit(self: *Event, gpa: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .new_client => |stream| {
                stream.close(io);
            },
            .pty_input => |data| {
                gpa.free(data);
            },
            .pty_output => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }
};

pub fn loop(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) !void {
    var event_queue_buffer: [16]Event = undefined;
    var event_queue: std.Io.Queue(Event) = .init(&event_queue_buffer);
    defer {
        event_queue.close(io);
        while (true) {
            var event = event_queue.getOne(io) catch break;
            event.deinit(gpa, io);
        }
    }

    var pty_input_queue_buffer: [8][]u8 = undefined;
    var pty_input_queue: std.Io.Queue([]u8) = .init(&pty_input_queue_buffer);
    defer {
        pty_input_queue.close(io);
        while (true) {
            const data = pty_input_queue.getOne(io) catch break;
            gpa.free(data);
        }
    }

    _ = try try async.tryJoin(io, .{
        .{ readPty, .{ gpa, io, self.pty, &event_queue } },
        .{ writePty, .{ gpa, io, self.pty, &pty_input_queue } },
        .{ acceptLoop, .{ io, &self.server, &event_queue } },
        .{ mainLoop, .{ gpa, io, &event_queue, &pty_input_queue } },
    });
}

fn readPty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    queue: *std.Io.Queue(Event),
) !void {
    var buffer: [4096]u8 = undefined;

    // instead of using a buffer and
    // - reader.fillMore()
    // - reader.buffered()
    // - reader.tossBuffered()
    // we just call reader.readVec() directly on our buffer.
    var file_reader = pty.reader(io, &.{});
    const reader = &file_reader.interface;

    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => return file_reader.err.?,
                else => |e| return e,
            };
        }

        const data = try gpa.alloc(u8, n);
        errdefer gpa.free(data);

        @memcpy(data, buffer[0..n]);

        try queue.putOne(io, .{ .pty_output = data });
    }
}

fn writePty(
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: std.Io.File,
    queue: *std.Io.Queue([]u8),
) !void {
    // no buffer, all data is written immediately
    var file_writer = pty.writer(io, &.{});
    const writer = &file_writer.interface;

    while (true) {
        const data = try queue.getOne(io);
        defer gpa.free(data);
        log.info("pty_queue: data={x}", .{data});

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return file_writer.err.?,
        };
    }
}

fn acceptLoop(
    io: std.Io,
    server: *std.Io.net.Server,
    queue: *std.Io.Queue(Event),
) !void {
    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        try queue.putOne(io, .{ .new_client = stream });
    }
}

const Client = struct {
    node: std.DoublyLinkedList.Node = .{},
    queue_buffer: [8][]u8 = undefined,
    queue: std.Io.Queue([]u8),
    task: std.Io.Future(void),

    fn deinit(self: *Client, gpa: std.mem.Allocator, io: std.Io) void {
        self.task.cancel(io);
        self.queue.close(io);
        while (true) {
            const data = self.queue.getOne(io) catch break;
            gpa.free(data);
        }
        self.* = undefined;
    }
};

fn mainLoop(
    gpa: std.mem.Allocator,
    io: std.Io,
    event_queue: *std.Io.Queue(Event),
    pty_input_queue: *std.Io.Queue([]u8),
) !void {
    var clients: std.DoublyLinkedList = .{};
    defer {
        while (clients.pop()) |node| {
            const client: *Client = @fieldParentPtr("node", node);
            client.deinit(gpa, io);
            gpa.destroy(client);
        }
    }

    while (true) {
        var event = try event_queue.getOne(io);
        errdefer event.deinit(gpa, io);
        switch (event) {
            .new_client => |stream| {
                log.info("new_client event: stream={}", .{stream.socket.handle});

                const client = try gpa.create(Client);
                errdefer gpa.destroy(client);

                client.* = .{
                    .queue = .init(&client.queue_buffer),
                    .task = try io.concurrent(
                        serveConnection,
                        .{ gpa, io, stream, event_queue, &client.queue },
                    ),
                };
                clients.append(&client.node);
            },
            .pty_input => |data| {
                log.info("pty_input event: data={x}", .{data});
                try pty_input_queue.putOne(io, data);
            },
            .pty_output => |data| {
                log.info("pty_output event: data={x}", .{data});
                var it = clients.first;
                while (it) |node| {
                    const client: *Client = @fieldParentPtr("node", node);
                    it = node.next;

                    // TODO: use reference counting instead of copying data
                    const client_data = try gpa.dupe(u8, data);
                    errdefer gpa.free(client_data);

                    client.queue.putOne(io, client_data) catch |err| switch (err) {
                        error.Closed => {
                            // client disconnected
                            clients.remove(&client.node);
                            client.deinit(gpa, io);
                            gpa.destroy(client);
                            gpa.free(client_data);
                        },
                        error.Canceled => |e| return e,
                    };
                }
                gpa.free(data);
            },
        }
    }
}

fn serveConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    event_queue: *std.Io.Queue(Event),
    client_output_queue: *std.Io.Queue([]u8),
) void {
    defer stream.close(io);
    // this is how we communicate the client is dead
    defer client_output_queue.close(io);

    _ = async.tryJoin(io, .{
        .{ readStream, .{ gpa, io, stream, event_queue } },
        .{ writeStream, .{ gpa, io, stream, client_output_queue } },
    }) catch |err| {
        log.err("tryJoin error: {t}", .{err});
        return;
    } catch |err| {
        log.err("readStream/writeStream error: {t}", .{err});
        return;
    };
}

fn readStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    queue: *std.Io.Queue(Event),
) !void {
    var buffer: [4096]u8 = undefined;

    // no buffer, read comment on `readPty` function
    var stream_reader = stream.reader(io, &.{});
    const reader = &stream_reader.interface;

    while (true) {
        var n: usize = 0;
        while (n == 0) {
            var buffers = [_][]u8{&buffer};
            n = reader.readVec(&buffers) catch |err| switch (err) {
                error.ReadFailed => return stream_reader.err.?,
                else => |e| return e,
            };
        }

        const data = try gpa.alloc(u8, n);
        errdefer gpa.free(data);

        @memcpy(data, buffer[0..n]);

        try queue.putOne(io, .{ .pty_input = data });
    }
}

fn writeStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    queue: *std.Io.Queue([]u8),
) !void {
    // no buffer, all data is written immediately
    var stream_writer = stream.writer(io, &.{});
    const writer = &stream_writer.interface;

    while (true) {
        const data = try queue.getOne(io);
        defer gpa.free(data);
        log.info("client_queue: data={x}", .{data});

        writer.writeAll(data) catch |err| switch (err) {
            error.WriteFailed => return stream_writer.err.?,
        };
    }
}

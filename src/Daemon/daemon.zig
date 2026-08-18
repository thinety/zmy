const std = @import("std");
const ghostty = @import("ghostty-vt");

const PtyEvent = @import("pty.zig").Event;
const ClientEvent = @import("client.zig").Event;
const handleClient = @import("client.zig").handleClient;
const StreamHandler = @import("ghostty/stream.zig").Handler;
const formatTerminal = @import("ghostty/formatter.zig").formatTerminal;

const log = std.log.scoped(.zmy_daemon_daemon);

pub const Event = union(enum) {
    new_client: std.Io.net.Stream,
    pty_input: []u8,
    pty_output: []u8,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator, io: std.Io) void {
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

const Client = struct {
    node: std.DoublyLinkedList.Node = .{},
    stream: std.Io.net.Stream,
    queue_buffer: [8]ClientEvent = undefined,
    queue: std.Io.Queue(ClientEvent),
    task: std.Io.Future(void),

    fn deinit(self: *Client, gpa: std.mem.Allocator, io: std.Io) void {
        self.task.cancel(io);
        self.queue.close(io);
        while (true) {
            var event = self.queue.getOne(io) catch break;
            event.deinit(gpa);
        }
        self.stream.close(io);
        self.* = undefined;
    }
};

pub fn mainLoop(
    gpa: std.mem.Allocator,
    io: std.Io,
    event_queue: *std.Io.Queue(Event),
    pty_input_queue: *std.Io.Queue(PtyEvent),
) !void {
    var clients: std.DoublyLinkedList = .{};
    defer {
        while (clients.pop()) |node| {
            const client: *Client = @fieldParentPtr("node", node);
            client.deinit(gpa, io);
            gpa.destroy(client);
        }
    }

    var pty_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer pty_buffer.deinit();

    var vt_stream_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer vt_stream_buffer.deinit();

    var term = try ghostty.Terminal.init(io, gpa, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(gpa);
    var vt_stream = ghostty.Stream(StreamHandler).init(.{
        .handler = .init(gpa, io, &pty_buffer.writer, &vt_stream_buffer.writer, &term),
        .allocator = gpa,
    });
    defer vt_stream.deinit();

    while (true) {
        var event = try event_queue.getOne(io);
        errdefer event.deinit(gpa, io);
        switch (event) {
            .new_client => |stream| {
                log.info("Event.new_client: stream={}", .{stream.socket.handle});

                const client = try gpa.create(Client);
                {
                    errdefer gpa.destroy(client);

                    client.* = .{
                        .stream = stream,
                        .queue = .init(&client.queue_buffer),
                        .task = try io.concurrent(
                            handleClient,
                            .{ gpa, io, stream, event_queue, &client.queue },
                        ),
                    };
                    clients.append(&client.node);
                }

                var allocating: std.Io.Writer.Allocating = .init(gpa);
                defer allocating.deinit();

                try formatTerminal(&term, &allocating.writer);

                const output = allocating.writer.buffered();
                if (output.len > 0) {
                    const client_data = try gpa.dupe(u8, output);
                    errdefer gpa.free(client_data);

                    try client.queue.putOne(
                        io,
                        .{ .data = client_data },
                    );
                }
            },
            .pty_input => |data| {
                log.info("Event.pty_input: data={b64}", .{data});
                try pty_input_queue.putOne(io, .{ .data = data });
            },
            .pty_output => |data| {
                log.info("Event.pty_output: data={b64}", .{data});

                vt_stream.nextSlice(data);
                gpa.free(data);

                if (pty_buffer.written().len > 0) {
                    defer pty_buffer.clearRetainingCapacity();

                    const pty_data = try gpa.dupe(u8, pty_buffer.written());
                    errdefer gpa.free(pty_data);

                    try pty_input_queue.putOne(io, .{ .data = pty_data });
                }

                if (vt_stream_buffer.written().len > 0) {
                    defer vt_stream_buffer.clearRetainingCapacity();

                    var it = clients.first;
                    while (it) |node| {
                        const client: *Client = @fieldParentPtr("node", node);
                        it = node.next;

                        // TODO: use reference counting instead of copying data
                        const client_data = try gpa.dupe(u8, vt_stream_buffer.written());
                        errdefer gpa.free(client_data);

                        client.queue.putOne(io, .{ .data = client_data }) catch |err| switch (err) {
                            error.Closed => {
                                log.info("client disconnected: stream={}", .{client.stream.socket.handle});

                                clients.remove(&client.node);
                                client.deinit(gpa, io);
                                gpa.destroy(client);
                                gpa.free(client_data);
                            },
                            error.Canceled => |e| return e,
                        };
                    }
                }
            },
        }
    }
}

const std = @import("std");
const async = @import("../async.zig");
const ipc = @import("../ipc.zig");
const socket = @import("socket.zig");
const stdio = @import("stdio.zig");

const log = std.log.scoped(.zmy_client);

pub const Event = union(enum) {
    resize: ipc.Winsize,
    daemon_message: ipc.DaemonMessage,
    stdin: []u8,

    fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .resize => |winsize| {
                _ = winsize;
            },
            .daemon_message => |*message| {
                message.deinit(gpa);
            },
            .stdin => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
) !void {
    var sigset = std.os.linux.sigemptyset();
    std.os.linux.sigaddset(&sigset, std.os.linux.SIG.WINCH);

    // we must do this here so that spawned threads inherit the blocked mask
    switch (std.os.linux.errno(std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &sigset, null))) {
        .SUCCESS => {},
        else => |err| {
            log.err("sigprocmask(SIG.BLOCK) failed: {t}", .{err});
            return error.Sigprocmask;
        },
    }

    const fd = std.os.linux.signalfd(-1, &sigset, 0);
    switch (std.os.linux.errno(fd)) {
        .SUCCESS => {},
        else => |err| {
            log.err("signalfd(-1) failed: {t}", .{err});
            return error.Signalfd;
        },
    }
    const signals: std.Io.File = .{
        .handle = @intCast(fd),
        .flags = .{ .nonblocking = false },
    };
    defer signals.close(io);

    // reset terminal
    {
        const stdout = std.Io.File.stdout();
        var stdout_writer = stdout.writer(io, &.{});
        try stdout_writer.interface.writeAll("\x1bc");
    }
    defer {
        const stdout = std.Io.File.stdout();
        var stdout_writer = stdout.writer(io, &.{});
        stdout_writer.interface.writeAll("\x1bc") catch |err| switch (err) {
            error.WriteFailed => {
                log.err("failed to reset terminal on shutdown: {t}", .{stdout_writer.err.?});
            },
        };
    }

    // get initial terminal configuration
    const termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);

    // set raw mode
    {
        var raw_termios = termios;

        raw_termios.iflag.IGNBRK = false;
        raw_termios.iflag.BRKINT = false;
        raw_termios.iflag.PARMRK = false;
        raw_termios.iflag.ISTRIP = false;
        raw_termios.iflag.INLCR = false;
        raw_termios.iflag.IGNCR = false;
        raw_termios.iflag.ICRNL = false;
        raw_termios.iflag.IXON = false;

        raw_termios.oflag.OPOST = false;

        raw_termios.lflag.ECHO = false;
        raw_termios.lflag.ECHONL = false;
        raw_termios.lflag.ICANON = false;
        raw_termios.lflag.ISIG = false;
        raw_termios.lflag.IEXTEN = false;

        raw_termios.cflag.CSIZE = .CS8;
        raw_termios.cflag.PARENB = false;

        raw_termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw_termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw_termios);
    }

    // restore previous terminal mode
    defer {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios) catch |err| {
            log.err("tcsetattr({}, .FLUSH) failed: {t}", .{ std.posix.STDIN_FILENO, err });
        };
    }

    var event_queue_buffer: [16]Event = undefined;
    var event_queue: std.Io.Queue(Event) = .init(&event_queue_buffer);
    defer {
        event_queue.close(io);
        while (true) {
            var event = event_queue.getOne(io) catch break;
            event.deinit(gpa);
        }
    }

    var stdout_queue_buffer: [8][]u8 = undefined;
    var stdout_queue: std.Io.Queue([]u8) = .init(&stdout_queue_buffer);
    defer {
        stdout_queue.close(io);
        while (true) {
            const data = stdout_queue.getOne(io) catch break;
            gpa.free(data);
        }
    }

    var message_queue_buffer: [8]ipc.ClientMessage = undefined;
    var message_queue: std.Io.Queue(ipc.ClientMessage) = .init(&message_queue_buffer);
    defer {
        message_queue.close(io);
        while (true) {
            var message = message_queue.getOne(io) catch break;
            message.deinit(gpa);
        }
    }

    try try async.race(io, .{
        .{ stdio.readStdin, .{ gpa, io, &event_queue } },
        .{ stdio.writeStdout, .{ gpa, io, &stdout_queue } },
        .{ socket.readSocket, .{ gpa, io, stream, &event_queue } },
        .{ socket.writeSocket, .{ gpa, io, &message_queue, stream } },
        .{ readSignals, .{ io, signals, &event_queue } },
        .{ mainLoop, .{ gpa, io, &event_queue, &stdout_queue, &message_queue } },
    });
}

fn readSignals(
    io: std.Io,
    signals: std.Io.File,
    event_queue: *std.Io.Queue(Event),
) !void {
    // the first resize message is for "initialization" of the client
    {
        const winsize = try getWinsize();
        const event: Event = .{ .resize = winsize };
        try event_queue.putOne(io, event);
    }

    var file_reader = signals.reader(io, &.{});
    const reader = &file_reader.interface;

    while (true) {
        var siginfo: std.os.linux.signalfd_siginfo = undefined;
        reader.readSliceAll(std.mem.asBytes(&siginfo)) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            else => |e| return e,
        };

        switch (@as(std.os.linux.SIG, @enumFromInt(siginfo.signo))) {
            std.os.linux.SIG.WINCH => {
                const winsize = try getWinsize();
                const event: Event = .{ .resize = winsize };
                try event_queue.putOne(io, event);
            },
            else => |signal| {
                std.log.warn("unexpected signal: {t}", .{signal});
            },
        }
    }
}

fn mainLoop(
    gpa: std.mem.Allocator,
    io: std.Io,
    event_queue: *std.Io.Queue(Event),
    stdout_queue: *std.Io.Queue([]u8),
    message_queue: *std.Io.Queue(ipc.ClientMessage),
) !void {
    while (true) {
        const event = try event_queue.getOne(io);
        switch (event) {
            .resize => |winsize| {
                log.info(
                    "Event.resize: col={} row={} xpixel={} ypixel={}",
                    .{ winsize.col, winsize.row, winsize.xpixel, winsize.ypixel },
                );

                const message: ipc.ClientMessage = .{ .resize = winsize };
                try message_queue.putOne(io, message);
            },
            .daemon_message => |message| {
                switch (message) {
                    .data => |data| {
                        errdefer gpa.free(data);
                        log.info("DaemonMessage.data: data.len={} data={b64}{s}", .{
                            data.len,
                            data[0..@min(data.len, 48)],
                            if (data.len > 48) "..." else "",
                        });

                        try stdout_queue.putOne(io, data);
                    },
                }
            },
            .stdin => |data| {
                errdefer gpa.free(data);
                log.info("Event.stdin: data.len={} data={b64}{s}", .{
                    data.len,
                    data[0..@min(data.len, 48)],
                    if (data.len > 48) "..." else "",
                });

                const message: ipc.ClientMessage = .{ .data = data };
                try message_queue.putOne(io, message);
            },
        }
    }
}

fn getWinsize() !ipc.Winsize {
    var winsize: std.c.winsize = undefined;
    switch (std.c.errno(std.c.ioctl(std.c.STDIN_FILENO, std.c.T.IOCGWINSZ, &winsize))) {
        .SUCCESS => {},
        else => |err| {
            log.err("ioctl({}, T.IOCGWINSZ) failed: {t}", .{ std.c.STDIN_FILENO, err });
            return error.Ioctl;
        },
    }

    return .{
        .col = winsize.col,
        .row = winsize.row,
        .xpixel = winsize.xpixel,
        .ypixel = winsize.ypixel,
    };
}

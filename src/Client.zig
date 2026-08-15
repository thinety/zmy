const std = @import("std");

const Client = @This();

io: std.Io,
stream: std.Io.net.Stream,

pub fn init(io: std.Io, address: std.Io.net.UnixAddress) !Client {
    var stream = try address.connect(io);
    errdefer stream.close(io);

    return .{ .io = io, .stream = stream };
}

pub fn deinit(self: *Client) void {
    self.stream.close(self.io);
    self.* = undefined;
}

pub fn loop(self: *Client) !void {
    try self.io.sleep(.fromSeconds(100), .real);
}

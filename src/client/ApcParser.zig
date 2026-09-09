const std = @import("std");
const client = @import("client.zig");

const Self = @This();

vt_stream: *std.Io.Writer,
session_name: []const u8,
client_id: client.ClientId,
received_detach: bool,
apc_content_buffer: [4096]u8,
apc_content_len: usize,
state: State,

const State = enum {
    ground,
    escape,
    apc,
    escape_end,
};

pub fn init(
    vt_stream: *std.Io.Writer,
    session_name: []const u8,
    client_id: client.ClientId,
) Self {
    return .{
        .vt_stream = vt_stream,
        .session_name = session_name,
        .client_id = client_id,
        .received_detach = false,
        .apc_content_buffer = undefined,
        .apc_content_len = 0,
        .state = .ground,
    };
}

pub fn nextSlice(self: *Self, input: []const u8) !void {
    var data = input;
    while (data.len > 0) {
        switch (self.state) {
            .ground => {
                if (data[0] == '\x1b') {
                    self.state = .escape;
                    data = data[1..];
                } else {
                    const i = std.mem.indexOf(u8, data, "\x1b") orelse data.len;
                    try self.vt_stream.writeAll(data[0..i]);
                    data = data[i..];
                }
            },
            .escape => {
                if (data[0] == '_') {
                    self.state = .apc;
                    data = data[1..];
                } else {
                    try self.vt_stream.writeByte('\x1b');
                    self.state = .ground;
                }
            },
            .apc => {
                if (data[0] == '\x1b') {
                    self.state = .escape_end;
                    data = data[1..];
                } else {
                    const i = std.mem.indexOf(u8, data, "\x1b") orelse data.len;
                    if (self.apc_content_len + i <= self.apc_content_buffer.len) {
                        @memcpy(self.apc_content_buffer[self.apc_content_len..][0..i], data[0..i]);
                        self.apc_content_len += i;
                        data = data[i..];
                    } else {
                        try self.vt_stream.writeAll(self.apc_content_buffer[0..self.apc_content_len]);
                        self.apc_content_len = 0;
                        self.state = .ground;
                    }
                }
            },
            .escape_end => {
                if (data[0] == '\\') {
                    self.state = .ground;
                    data = data[1..];

                    try self.handleApc(self.apc_content_buffer[0..self.apc_content_len]);
                    self.apc_content_len = 0;
                } else {
                    if (self.apc_content_len < self.apc_content_buffer.len) {
                        self.apc_content_buffer[self.apc_content_len] = '\x1b';
                        self.apc_content_len += 1;
                        self.state = .apc;
                    } else {
                        try self.vt_stream.writeAll(self.apc_content_buffer[0..self.apc_content_len]);
                        self.apc_content_len = 0;
                        self.state = .ground;
                    }
                }
            },
        }
    }
}

fn handleApc(self: *Self, content: []const u8) !void {
    const zmy_prefix = "zmy;";
    if (std.mem.startsWith(u8, content, zmy_prefix)) {
        const payload = content[zmy_prefix.len..];
        self.handleZmyApc(payload) catch |err| {
            std.log.warn("error handling ZMY apc sequence err={}", .{err});
        };
    } else {
        try self.vt_stream.writeAll("\x1b_");
        try self.vt_stream.writeAll(content);
        try self.vt_stream.writeAll("\x1b\\");
    }
}

fn handleZmyApc(self: *Self, payload: []const u8) !void {
    const detach_prefix = "detach;";
    if (std.mem.startsWith(u8, payload, detach_prefix)) {
        const encoded_client_id = payload[detach_prefix.len..];

        var client_id: client.ClientId = undefined;
        const result = try std.fmt.hexToBytes(&client_id, encoded_client_id);
        if (result.len != client_id.len) return error.InvalidClientId;

        if (std.mem.eql(u8, &client_id, &self.client_id)) {
            self.received_detach = true;
        } else {
            try self.vt_stream.writeAll("\x1b_zmy;detach;");
            try self.vt_stream.writeAll(encoded_client_id);
            try self.vt_stream.writeAll("\x1b\\");
        }

        return;
    }

    const trace_prefix = "trace;";
    if (std.mem.startsWith(u8, payload, trace_prefix)) {
        const data = payload[trace_prefix.len..];

        const new_data = try std.fmt.bufPrint(
            self.apc_content_buffer[self.apc_content_len..],
            "{s}: {x}\n",
            .{ self.session_name, self.client_id },
        );

        const i = self.apc_content_len - data.len;
        const j = self.apc_content_len + new_data.len;
        const all_data = self.apc_content_buffer[i..j];

        try self.vt_stream.writeAll("\x1b]52;c;");
        try std.base64.standard.Encoder.encodeWriter(self.vt_stream, all_data);
        try self.vt_stream.writeAll("\x1b\\");

        try self.vt_stream.writeAll("\x1b_zmy;trace;");
        try self.vt_stream.writeAll(all_data);
        try self.vt_stream.writeAll("\x1b\\");

        return;
    }

    return error.InvalidApcSequence;
}

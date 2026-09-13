const std = @import("std");
const client = @import("client.zig");

const Self = @This();

vt_stream: *std.Io.Writer,
session_name: []const u8,
client_id: client.ClientId,
/// Set when a detach APC is seen.
seen_detach: bool,
/// Set when a trace APC is seen; the next OSC 52 carries trace data and
/// gets our identity appended to it.
seen_trace: bool,
apc_buffer: [4096]u8,
apc_len: usize,
osc_buffer: [4096]u8,
osc_len: usize,
state: State,

const State = enum {
    ground,
    escape,
    apc,
    apc_escape,
    osc,
    osc_escape,
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
        .seen_detach = false,
        .seen_trace = false,
        .apc_buffer = undefined,
        .apc_len = 0,
        .osc_buffer = undefined,
        .osc_len = 0,
        .state = .ground,
    };
}

pub fn nextSlice(self: *Self, input: []const u8) !void {
    var data = input;
    while (data.len > 0) {
        switch (self.state) {
            .ground => {
                if (data[0] == 0x1b) {
                    data = data[1..];
                    self.state = .escape;
                } else {
                    const i = std.mem.findScalar(u8, data, 0x1b) orelse data.len;
                    try self.vt_stream.writeAll(data[0..i]);
                    data = data[i..];
                }
            },
            .escape => {
                if (data[0] == '_') {
                    data = data[1..];
                    self.state = .apc;
                } else if (data[0] == ']') {
                    data = data[1..];
                    self.state = .osc;
                } else {
                    try self.vt_stream.writeByte(0x1b);
                    self.state = .ground;
                }
            },
            .apc => {
                const b = data[0];
                if (b == 0x1b) {
                    data = data[1..];
                    self.state = .apc_escape;
                } else if (b >= 0x20 and b <= 0xff and self.apc_len < self.apc_buffer.len) {
                    self.apc_buffer[self.apc_len] = b;
                    self.apc_len += 1;
                    data = data[1..];
                } else {
                    try self.vt_stream.writeAll("\x1b_");
                    try self.vt_stream.writeAll(self.apc_buffer[0..self.apc_len]);
                    self.apc_len = 0;
                    self.state = .ground;
                }
            },
            .apc_escape => {
                if (data[0] == '\\') {
                    try self.handleApc(self.apc_buffer[0..self.apc_len]);
                    self.apc_len = 0;
                    data = data[1..];
                    self.state = .ground;
                } else {
                    try self.vt_stream.writeAll("\x1b_");
                    try self.vt_stream.writeAll(self.apc_buffer[0..self.apc_len]);
                    try self.vt_stream.writeByte(0x1b);
                    self.apc_len = 0;
                    self.state = .ground;
                }
            },
            .osc => {
                const b = data[0];
                if (b == 0x1b) {
                    data = data[1..];
                    self.state = .osc_escape;
                } else if (b >= 0x20 and b <= 0xff and self.osc_len < self.osc_buffer.len) {
                    self.osc_buffer[self.osc_len] = b;
                    self.osc_len += 1;
                    data = data[1..];
                } else {
                    try self.vt_stream.writeAll("\x1b]");
                    try self.vt_stream.writeAll(self.osc_buffer[0..self.osc_len]);
                    self.osc_len = 0;
                    self.state = .ground;
                }
            },
            .osc_escape => {
                if (data[0] == '\\') {
                    try self.handleOsc(self.osc_buffer[0..self.osc_len]);
                    self.osc_len = 0;
                    data = data[1..];
                    self.state = .ground;
                } else {
                    try self.vt_stream.writeAll("\x1b]");
                    try self.vt_stream.writeAll(self.osc_buffer[0..self.osc_len]);
                    try self.vt_stream.writeByte(0x1b);
                    self.osc_len = 0;
                    self.state = .ground;
                }
            },
        }
    }
}

fn handleApc(self: *Self, content: []const u8) !void {
    const zmy_prefix = "zmy;";
    if (std.mem.startsWith(u8, content, zmy_prefix)) {
        const payload = content[zmy_prefix.len..];

        const detach_prefix = "detach;";
        if (std.mem.startsWith(u8, payload, detach_prefix)) {
            const encoded_client_id = payload[detach_prefix.len..];

            var client_id: client.ClientId = undefined;
            const result = std.fmt.hexToBytes(&client_id, encoded_client_id) catch return;
            if (result.len != client_id.len) return;

            if (!std.mem.eql(u8, &client_id, &self.client_id)) {
                try self.vt_stream.writeAll("\x1b_zmy;detach;");
                try self.vt_stream.writeAll(encoded_client_id);
                try self.vt_stream.writeAll("\x1b\\");
                return;
            }

            self.seen_detach = true;
            return;
        }

        if (std.mem.eql(u8, payload, "trace")) {
            try self.vt_stream.writeAll("\x1b_zmy;trace\x1b\\");
            self.seen_trace = true;
            return;
        }

        return;
    }

    // forward every other APC sequence cleanly
    try self.vt_stream.writeAll("\x1b_");
    try self.vt_stream.writeAll(content);
    try self.vt_stream.writeAll("\x1b\\");
}

fn handleOsc(self: *Self, content: []const u8) !void {
    // OSC 52 (clipboard)
    if (self.seen_trace and std.mem.startsWith(u8, content, "52;")) {
        self.seen_trace = false;

        const data_start = (std.mem.findScalarLast(u8, content, ';') orelse return) + 1;
        const data = content[data_start..];

        if (std.mem.eql(u8, data, "?")) return;

        var buffer: [4096]u8 = undefined;

        const first_line = std.fmt.bufPrint(
            &buffer,
            "{s}: {x}\n",
            .{ self.session_name, self.client_id },
        ) catch return;

        const data_size = std.base64.standard.Decoder.calcSizeForSlice(data) catch return;
        std.base64.standard.Decoder.decode(buffer[first_line.len..][0..data_size], data) catch return;

        try self.vt_stream.writeAll("\x1b]");
        try self.vt_stream.writeAll(content[0..data_start]);
        try std.base64.standard.Encoder.encodeWriter(self.vt_stream, buffer[0 .. first_line.len + data_size]);
        try self.vt_stream.writeAll("\x1b\\");

        return;
    }

    // forward every other OSC sequence cleanly
    try self.vt_stream.writeAll("\x1b]");
    try self.vt_stream.writeAll(content);
    try self.vt_stream.writeAll("\x1b\\");
}

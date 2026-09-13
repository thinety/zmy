const std = @import("std");

const Self = @This();

/// Bytes that are not a <Ctrl-\> press are written here.
passthrough: *std.Io.Writer,
/// Set by `nextSlice` when a <Ctrl-\> press is observed.
received_ctrl_backslash: bool,
csi_buffer: [64]u8,
csi_len: usize,
state: State,

const State = enum {
    ground,
    escape,
    csi,
};

pub fn init(passthrough: *std.Io.Writer) Self {
    return .{
        .passthrough = passthrough,
        .received_ctrl_backslash = false,
        .csi_buffer = undefined,
        .csi_len = 0,
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
                } else if (data[0] == 0x1c) {
                    self.received_ctrl_backslash = true;
                    data = data[1..];
                } else {
                    const esc = std.mem.indexOf(u8, data, "\x1b") orelse data.len;
                    const i = std.mem.indexOf(u8, data[0..esc], "\x1c") orelse esc;
                    try self.passthrough.writeAll(data[0..i]);
                    data = data[i..];
                }
            },
            .escape => {
                if (data[0] == '[') {
                    data = data[1..];
                    self.state = .csi;
                } else {
                    try self.passthrough.writeByte('\x1b');
                    self.state = .ground;
                }
            },
            .csi => {
                const b = data[0];
                if (b >= 0x20 and b <= 0x7e and self.csi_len < self.csi_buffer.len) {
                    self.csi_buffer[self.csi_len] = b;
                    self.csi_len += 1;
                    data = data[1..];
                    if (b >= 0x40) {
                        // final byte: the sequence is complete
                        try self.handleCsi(self.csi_buffer[0..self.csi_len]);
                        self.csi_len = 0;
                        self.state = .ground;
                    }
                } else {
                    try self.passthrough.writeAll("\x1b[");
                    try self.passthrough.writeAll(self.csi_buffer[0..self.csi_len]);
                    self.csi_len = 0;
                    self.state = .ground;
                }
            },
        }
    }
}

fn handleCsi(self: *Self, seq: []const u8) !void {
    if (isCtrlBackslash(seq)) {
        self.received_ctrl_backslash = true;
        return;
    }

    try self.passthrough.writeAll("\x1b[");
    try self.passthrough.writeAll(seq);
}

// `seq` is the CSI parameter field plus the final byte, e.g. "92:124;6u"
// or "27;5;92u". We match any CSI ... u keyboard sequence where the `\`
// key is held together with ctrl, regardless of any other modifiers
// (shift, alt, super, capslock, numlock, ...).
fn isCtrlBackslash(seq: []const u8) bool {
    if (seq.len == 0 or seq[seq.len - 1] != 'u') return false;
    const params = seq[0 .. seq.len - 1];

    var it = std.mem.splitScalar(u8, params, ';');
    const first = it.next() orelse return false;

    const modifiers = it.next() orelse return false;
    if (!ctrlHeld(modifiers)) return false;

    const codepoint =
        if (std.mem.eql(u8, first, "27"))
            // xterm modifyOtherKeys: 27 ; modifiers ; codepoint
            it.next() orelse return false
        else
            // kitty keyboard protocol: keycode [: alt-keycode] ; modifiers [; ...]
            first;
    if (!isBackslash(codepoint)) return false;

    return true;
}

// The modifiers parameter is 1 + flags, and the ctrl flag is value 4 in both
// the kitty and xterm conventions, so bit 0x4 set means ctrl is held.
//
// In the kitty protocol this field may carry an event suffix "mods:event"
// where the event is 1 (press), 2 (repeat), or 3 (release); we only act on
// presses. An absent event means a press.
fn ctrlHeld(modifiers: []const u8) bool {
    const colon = std.mem.findScalar(u8, modifiers, ':');

    if (colon) |i| {
        const event = std.fmt.parseInt(usize, modifiers[i + 1 ..], 10) catch return false;
        if (event != 1) return false;
    }

    const i = colon orelse modifiers.len;
    const mods = std.fmt.parseInt(usize, modifiers[0..i], 10) catch return false;
    const flags = mods - 1;
    if (flags & 0x4 == 0) return false;

    return true;
}

// The kitty keycode for `\` is 92. When shift is folded into the keycode
// (instead of being reported as a modifier) some terminals send its shifted
// form `|`, which is 124. The keycode may also carry a ":alt" suffix.
fn isBackslash(codepoint: []const u8) bool {
    const i = std.mem.findScalar(u8, codepoint, ':') orelse codepoint.len;
    const code = std.fmt.parseInt(usize, codepoint[0..i], 10) catch return false;
    return code == 92 or code == 124;
}

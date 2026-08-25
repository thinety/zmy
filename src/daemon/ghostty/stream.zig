const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const terminfo = @import("terminfo.zig");

const Terminal = ghostty_vt.Terminal;
const Screen = ghostty_vt.Screen;
const Action = ghostty_vt.StreamAction;
const apc = ghostty_vt.apc;
const dcs = ghostty_vt.dcs;
const osc = ghostty_vt.osc;
const size_report = ghostty_vt.size_report;
const kitty = ghostty_vt.kitty;
const modes = ghostty_vt.modes;
const device_status = ghostty_vt.device_status;
const device_attributes = struct {
    const Req = Action.Value(.device_attributes);
    const Attributes = @typeInfo(
        @typeInfo(
            @typeInfo(
                @FieldType(
                    ghostty_vt.TerminalStream.Handler.Effects,
                    "device_attributes",
                ),
            ).optional.child,
        ).pointer.child,
    ).@"fn".return_type.?;
};
const csi = struct {
    const SizeReportStyle = ghostty_vt.SizeReportStyle;
};

pub const Handler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    pty: *std.Io.Writer,
    vt_stream: *std.Io.Writer,
    terminal: *Terminal,
    apc_handler: apc.Handler,
    dcs_handler: dcs.Handler,

    const default_cursor_style: Screen.CursorStyle = .block;
    const default_cursor_blink: bool = false;

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        pty: *std.Io.Writer,
        vt_stream: *std.Io.Writer,
        terminal: *Terminal,
    ) Handler {
        return .{
            .gpa = gpa,
            .io = io,
            .pty = pty,
            .vt_stream = vt_stream,
            .terminal = terminal,
            .apc_handler = .{},
            .dcs_handler = .{},
        };
    }

    pub fn deinit(self: *Handler) void {
        self.apc_handler.deinit();
    }

    pub fn resize(self: *Handler, value: Terminal.Resize) !void {
        try self.terminal.resize(self.gpa, value);

        // Mode 2048 reports require complete, current cell pixel geometry.
        const cell_size = value.cell_size_px orelse return;

        // If we have no in-band size reports enabled then do nothing.
        if (!self.terminal.modes.get(.in_band_size_reports)) return;

        try size_report.encode(self.pty, .mode_2048, .{
            .rows = value.rows,
            .columns = value.cols,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
        });
    }

    pub fn vt(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            std.log.err("error handling VT action action={} err={}", .{ action, err });
        };
    }

    inline fn vtFallible(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) !void {
        switch (action) {
            .print => {
                try self.terminal.print(value.cp);

                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(@intCast(value.cp), &buf);
                try self.vt_stream.writeAll(buf[0..n]);
            },
            .print_slice => {
                try self.terminal.printSlice(value.cps);

                for (value.cps) |cp| {
                    var buf: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(@intCast(cp), &buf);
                    try self.vt_stream.writeAll(buf[0..n]);
                }
            },
            .print_repeat => {
                try self.terminal.printRepeat(value);

                try self.vt_stream.print("\x1b[{d}b", .{value});
            },
            .backspace => {
                self.terminal.backspace();

                try self.vt_stream.writeByte(0x08);
            },
            .carriage_return => {
                self.terminal.carriageReturn();

                try self.vt_stream.writeByte(0x0D);
            },
            .linefeed => {
                try self.terminal.linefeed();

                try self.vt_stream.writeByte(0x0A);
            },
            .index => {
                try self.terminal.index();

                try self.vt_stream.writeAll("\x1bD");
            },
            .next_line => {
                try self.terminal.index();
                self.terminal.carriageReturn();

                try self.vt_stream.writeAll("\x1bE");
            },
            .reverse_index => {
                self.terminal.reverseIndex();

                try self.vt_stream.writeAll("\x1bM");
            },
            .cursor_up => {
                self.terminal.cursorUp(value.value);

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 1) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('A');
            },
            .cursor_down => {
                self.terminal.cursorDown(value.value);

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 1) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('B');
            },
            .cursor_left => {
                self.terminal.cursorLeft(value.value);

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 1) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('D');
            },
            .cursor_right => {
                self.terminal.cursorRight(value.value);

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 1) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('C');
            },
            .cursor_pos => {
                self.terminal.setCursorPos(value.row, value.col);

                try self.vt_stream.writeAll("\x1b[");
                if (value.col != 1) {
                    try self.vt_stream.print("{d};{d}", .{ value.row, value.col });
                } else if (value.row != 1) {
                    try self.vt_stream.print("{d}", .{value.row});
                }
                try self.vt_stream.writeByte('H');
            },
            .cursor_col => {
                self.terminal.setCursorPos(self.terminal.screens.active.cursor.y + 1, value.value);

                try self.vt_stream.print("\x1b[{d}G", .{value.value});
            },
            .cursor_row => {
                self.terminal.setCursorPos(value.value, self.terminal.screens.active.cursor.x + 1);

                try self.vt_stream.print("\x1b[{d}d", .{value.value});
            },
            .cursor_col_relative => {
                self.terminal.setCursorPos(
                    self.terminal.screens.active.cursor.y + 1,
                    self.terminal.screens.active.cursor.x + 1 +| value.value,
                );

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 0) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('a');
            },
            .cursor_row_relative => {
                self.terminal.setCursorPos(
                    self.terminal.screens.active.cursor.y + 1 +| value.value,
                    self.terminal.screens.active.cursor.x + 1,
                );

                try self.vt_stream.writeAll("\x1b[");
                if (value.value != 0) try self.vt_stream.print("{d}", .{value.value});
                try self.vt_stream.writeByte('e');
            },
            .cursor_style => {
                self.terminal.setCursorStyle(value);

                try self.vt_stream.print("\x1b[{d} q", .{@intFromEnum(value)});
            },
            .erase_display_below => {
                self.terminal.eraseDisplay(.below, value);

                try self.vt_stream.writeAll("\x1b[J");
            },
            .erase_display_above => {
                self.terminal.eraseDisplay(.above, value);

                try self.vt_stream.writeAll("\x1b[1J");
            },
            .erase_display_complete => {
                self.terminal.eraseDisplay(.complete, value);

                try self.vt_stream.writeAll("\x1b[2J");
            },
            .erase_display_scrollback => {
                self.terminal.eraseDisplay(.scrollback, value);

                try self.vt_stream.writeAll("\x1b[3J");
            },
            .erase_display_scroll_complete => {
                self.terminal.eraseDisplay(.scroll_complete, value);

                try self.vt_stream.writeAll("\x1b[2J\x1b[3J");
            },
            .erase_line_right => {
                self.terminal.eraseLine(.right, value);

                try self.vt_stream.writeAll("\x1b[K");
            },
            .erase_line_left => {
                self.terminal.eraseLine(.left, value);

                try self.vt_stream.writeAll("\x1b[1K");
            },
            .erase_line_complete => {
                self.terminal.eraseLine(.complete, value);

                try self.vt_stream.writeAll("\x1b[2K");
            },
            .erase_line_right_unless_pending_wrap => {
                self.terminal.eraseLine(.right_unless_pending_wrap, value);

                try self.vt_stream.writeAll("\x1b[K");
            },
            .delete_chars => {
                self.terminal.deleteChars(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('P');
            },
            .erase_chars => {
                self.terminal.eraseChars(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('X');
            },
            .insert_lines => {
                self.terminal.insertLines(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('L');
            },
            .insert_blanks => {
                self.terminal.insertBlanks(value);

                try self.vt_stream.writeAll("\x1b[");
                if (@max(1, value) != 1) try self.vt_stream.print("{d}", .{@max(1, value)});
                try self.vt_stream.writeByte('@');
            },
            .delete_lines => {
                self.terminal.deleteLines(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('M');
            },
            .scroll_up => {
                try self.terminal.scrollUp(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('S');
            },
            .scroll_down => {
                self.terminal.scrollDown(value);

                try self.vt_stream.writeAll("\x1b[");
                if (value != 1) try self.vt_stream.print("{d}", .{value});
                try self.vt_stream.writeByte('T');
            },
            .horizontal_tab => {
                for (0..value) |_| {
                    const x = self.terminal.screens.active.cursor.x;
                    self.terminal.horizontalTab();
                    if (x == self.terminal.screens.active.cursor.x) break;
                }

                for (0..value) |_| {
                    try self.vt_stream.writeByte(0x09);
                }
            },
            .horizontal_tab_back => {
                for (0..value) |_| {
                    const x = self.terminal.screens.active.cursor.x;
                    self.terminal.horizontalTabBack();
                    if (x == self.terminal.screens.active.cursor.x) break;
                }

                try self.vt_stream.writeAll("\x1b[Z");
            },
            .tab_clear_current => {
                self.terminal.tabClear(.current);

                try self.vt_stream.writeAll("\x1b[0g");
            },
            .tab_clear_all => {
                self.terminal.tabClear(.all);

                try self.vt_stream.writeAll("\x1b[3g");
            },
            .tab_set => {
                self.terminal.tabSet();

                try self.vt_stream.writeAll("\x1bH");
            },
            .tab_reset => {
                self.terminal.tabReset();

                try self.vt_stream.writeAll("\x1b[?5W");
            },
            .set_mode => {
                try self.setMode(value.mode, true);
            },
            .reset_mode => {
                try self.setMode(value.mode, false);
            },
            .save_mode => {
                self.terminal.modes.save(value.mode);
            },
            .restore_mode => {
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .top_and_bottom_margin => {
                self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right);

                try self.vt_stream.print("\x1b[{d};{d}r", .{ value.top_left, value.bottom_right });
            },
            .left_and_right_margin => {
                self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right);

                try self.vt_stream.print("\x1b[{d};{d}s", .{ value.top_left, value.bottom_right });
            },
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }

                try self.vt_stream.writeAll("\x1b[s");
            },
            .save_cursor => {
                self.terminal.saveCursor();

                try self.vt_stream.writeAll("\x1b7");
            },
            .restore_cursor => {
                self.terminal.restoreCursor();

                try self.vt_stream.writeAll("\x1b8");
            },
            .invoke_charset => {
                self.terminal.invokeCharset(value.bank, value.charset, value.locking);

                const slot_char: u8 = switch (value.bank) {
                    .GL => '(',
                    .GR => ')',
                };
                const charset_char: u8 = switch (value.charset) {
                    .G0 => 'B',
                    .G1 => '0',
                    .G2 => 'B',
                    .G3 => 'B',
                };
                try self.vt_stream.writeAll("\x1b");
                try self.vt_stream.writeByte(slot_char);
                try self.vt_stream.writeByte(charset_char);
            },
            .configure_charset => {
                self.terminal.configureCharset(value.slot, value.charset);

                const slot_char: u8 = switch (value.slot) {
                    .G0 => '(',
                    .G1 => ')',
                    .G2 => '*',
                    .G3 => '+',
                };
                const charset_char: u8 = switch (value.charset) {
                    .ascii => 'B',
                    .british => 'A',
                    .dec_special => '0',
                    .utf8 => 'B',
                };
                try self.vt_stream.writeAll("\x1b");
                try self.vt_stream.writeByte(slot_char);
                try self.vt_stream.writeByte(charset_char);
            },
            .set_attribute => {
                try self.terminal.setAttribute(value);

                try self.vt_stream.writeAll("\x1b[");
                switch (value) {
                    .unset => {}, // try self.vt_stream.writeByte('0'),
                    .bold => try self.vt_stream.writeByte('1'),
                    .faint => try self.vt_stream.writeByte('2'),
                    .italic => try self.vt_stream.writeByte('3'),
                    .underline => |u| switch (u) {
                        .none => try self.vt_stream.writeAll("24"),
                        .single => try self.vt_stream.writeByte('4'),
                        .double => try self.vt_stream.writeAll("4:2"),
                        .curly => try self.vt_stream.writeAll("4:3"),
                        .dotted => try self.vt_stream.writeAll("4:4"),
                        .dashed => try self.vt_stream.writeAll("4:5"),
                    },
                    .blink => try self.vt_stream.writeByte('5'),
                    .inverse => try self.vt_stream.writeByte('7'),
                    .invisible => try self.vt_stream.writeByte('8'),
                    .strikethrough => try self.vt_stream.writeByte('9'),
                    .reset_bold => try self.vt_stream.writeAll("22"),
                    .reset_italic => try self.vt_stream.writeAll("23"),
                    .reset_blink => try self.vt_stream.writeAll("25"),
                    .reset_inverse => try self.vt_stream.writeAll("27"),
                    .reset_invisible => try self.vt_stream.writeAll("28"),
                    .reset_strikethrough => try self.vt_stream.writeAll("29"),
                    .@"8_fg" => |c| try self.vt_stream.print("{d}", .{@intFromEnum(c) + 30}),
                    .direct_color_fg => |c| try self.vt_stream.print("38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
                    .@"256_fg" => |idx| try self.vt_stream.print("38;5;{d}", .{idx}),
                    .reset_fg => try self.vt_stream.writeAll("39"),
                    .@"8_bg" => |c| try self.vt_stream.print("{d}", .{@intFromEnum(c) + 40}),
                    .direct_color_bg => |c| try self.vt_stream.print("48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
                    .@"256_bg" => |idx| try self.vt_stream.print("48;5;{d}", .{idx}),
                    .reset_bg => try self.vt_stream.writeAll("49"),
                    .overline => try self.vt_stream.writeAll("53"),
                    .reset_overline => try self.vt_stream.writeAll("55"),
                    .underline_color => |c| try self.vt_stream.print("58;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
                    .@"256_underline_color" => |idx| try self.vt_stream.print("58;5;{d}", .{idx}),
                    .reset_underline_color => try self.vt_stream.writeAll("59"),
                    .@"8_bright_fg" => |c| try self.vt_stream.print("{d}", .{@intFromEnum(c) + 82}),
                    .@"8_bright_bg" => |c| try self.vt_stream.print("{d}", .{@intFromEnum(c) + 92}),
                    // The "unknown" variant re-emits the raw parameters verbatim since
                    // we can't map it to a known SGR code.
                    .unknown => {
                        for (value.unknown.full, 0..) |p, i| {
                            if (i > 0) try self.vt_stream.writeByte(';');
                            try self.vt_stream.print("{d}", .{p});
                        }
                    },
                }
                try self.vt_stream.writeByte('m');
            },
            .protected_mode_off => {
                self.terminal.setProtectedMode(.off);

                try self.vt_stream.writeAll("\x1b[" ++ "0\"q");
            },
            .protected_mode_iso => {
                self.terminal.setProtectedMode(.iso);

                try self.vt_stream.writeAll("\x1b[" ++ "1\"q");
            },
            .protected_mode_dec => {
                self.terminal.setProtectedMode(.dec);

                try self.vt_stream.writeAll("\x1b[" ++ "1\"q");
            },
            .mouse_shift_capture => {
                self.terminal.flags.mouse_shift_capture = if (value) .true else .false;

                try self.vt_stream.print("\x1b[>{d}s", .{@as(u8, if (value) 1 else 0)});
            },
            .kitty_keyboard_push => {
                self.terminal.screens.active.kitty_keyboard.push(value.flags);

                const flags_int = value.flags.int();
                try self.vt_stream.print("\x1b[>{d}u", .{flags_int});
            },
            .kitty_keyboard_pop => {
                self.terminal.screens.active.kitty_keyboard.pop(@intCast(value));

                try self.vt_stream.print("\x1b[<{d}u", .{value});
            },
            .kitty_keyboard_set => {
                self.terminal.screens.active.kitty_keyboard.set(.set, value.flags);

                const flags_int = value.flags.int();
                try self.vt_stream.print("\x1b[={d}u", .{flags_int});
                // try self.vt_stream.print("\x1b[={d};1u", .{flags_int});
            },
            .kitty_keyboard_set_or => {
                self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags);

                const flags_int = value.flags.int();
                try self.vt_stream.print("\x1b[={d};2u", .{flags_int});
            },
            .kitty_keyboard_set_not => {
                self.terminal.screens.active.kitty_keyboard.set(.not, value.flags);

                const flags_int = value.flags.int();
                try self.vt_stream.print("\x1b[={d};3u", .{flags_int});
            },
            .modify_key_format => {
                self.terminal.flags.modify_other_keys_2 = switch (value) {
                    .legacy,
                    .cursor_keys,
                    .function_keys,
                    .other_keys_none,
                    .other_keys_numeric_except,
                    => false,
                    .other_keys_numeric => true,
                };

                const format_val: u8 = switch (value) {
                    .legacy => 0,
                    .cursor_keys => 1,
                    .function_keys => 2,
                    .other_keys_none => 4,
                    .other_keys_numeric_except => 4,
                    .other_keys_numeric => 4,
                };
                try self.vt_stream.print("\x1b[>{d}m", .{format_val});
            },
            .active_status_display => {
                self.terminal.status_display = value;

                const display_val: u8 = switch (value) {
                    .main => 0,
                    .status_line => 1,
                };
                try self.vt_stream.print("\x1b[{d}$}}~", .{display_val});
            },
            .decaln => {
                try self.terminal.decaln();

                try self.vt_stream.writeAll("\x1b#8");
            },
            .full_reset => {
                self.terminal.fullReset();

                try self.vt_stream.writeAll("\x1bc");
            },
            .start_hyperlink => {
                try self.terminal.screens.active.startHyperlink(value.uri, value.id);

                if (value.id) |id| {
                    try self.vt_stream.print("\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ value.uri, id });
                } else {
                    try self.vt_stream.print("\x1b]8;;{s}\x1b\\", .{value.uri});
                }
            },
            .end_hyperlink => {
                self.terminal.screens.active.endHyperlink();

                try self.vt_stream.writeAll("\x1b]8;;\x1b\\");
            },
            .semantic_prompt => {
                try self.terminal.semanticPrompt(value);

                // Re-emit the OSC 133 semantic prompt sequence using the
                // single-character action code from the spec.
                const action_char: u8 = switch (value.action) {
                    .fresh_line => 'L',
                    .fresh_line_new_prompt => 'A',
                    .new_command => 'N',
                    .prompt_start => 'P',
                    .end_prompt_start_input => 'B',
                    .end_prompt_start_input_terminate_eol => 'I',
                    .end_input_start_output => 'C',
                    .end_command => 'D',
                };
                if (value.options_unvalidated.len == 0) {
                    try self.vt_stream.print("\x1b]133;{c}\x1b\\", .{action_char});
                } else {
                    try self.vt_stream.print("\x1b]133;{c};{s}\x1b\\", .{ action_char, value.options_unvalidated });
                }
            },
            .mouse_shape => {
                self.terminal.mouse_shape = value;
            },
            .color_operation => {
                if (value.requests.count() == 0) return;
                var it = value.requests.constIterator(0);
                while (it.next()) |req| {
                    switch (req.*) {
                        .set => |set| {
                            switch (set.target) {
                                .palette => |i| {
                                    self.terminal.flags.dirty.palette = true;
                                    self.terminal.colors.palette.set(i, set.color);
                                },
                                .dynamic => |dynamic| switch (dynamic) {
                                    .foreground => self.terminal.colors.foreground.set(set.color),
                                    .background => self.terminal.colors.background.set(set.color),
                                    .cursor => self.terminal.colors.cursor.set(set.color),
                                    .pointer_foreground,
                                    .pointer_background,
                                    .tektronix_foreground,
                                    .tektronix_background,
                                    .highlight_background,
                                    .tektronix_cursor,
                                    .highlight_foreground,
                                    => {},
                                },
                                .special => {},
                            }
                        },

                        .reset => |target| switch (target) {
                            .palette => |i| {
                                self.terminal.flags.dirty.palette = true;
                                self.terminal.colors.palette.reset(i);
                            },
                            .dynamic => |dynamic| switch (dynamic) {
                                .foreground => self.terminal.colors.foreground.reset(),
                                .background => self.terminal.colors.background.reset(),
                                .cursor => self.terminal.colors.cursor.reset(),
                                .pointer_foreground,
                                .pointer_background,
                                .tektronix_foreground,
                                .tektronix_background,
                                .highlight_background,
                                .tektronix_cursor,
                                .highlight_foreground,
                                => {},
                            },
                            .special => {},
                        },

                        .reset_palette => {
                            const mask = &self.terminal.colors.palette.mask;
                            var mask_it = mask.iterator(.{});
                            while (mask_it.next()) |i| {
                                self.terminal.flags.dirty.palette = true;
                                self.terminal.colors.palette.reset(@intCast(i));
                            }
                            mask.* = .initEmpty();
                        },

                        .query => |target| {
                            const c = self.terminal.colorForXterm(target) orelse continue;
                            switch (target) {
                                .palette => |i| {
                                    try self.pty.print("\x1b]4;{d};", .{i});
                                    try c.encodeRgb16(self.pty);
                                    try self.pty.writeAll(value.terminator.string());
                                },
                                .dynamic => |dynamic| switch (dynamic) {
                                    .foreground,
                                    .background,
                                    .cursor,
                                    => {
                                        try self.pty.print("\x1b]{d};", .{@intFromEnum(dynamic)});
                                        try c.encodeRgb16(self.pty);
                                        try self.pty.writeAll(value.terminator.string());
                                    },
                                    .pointer_foreground,
                                    .pointer_background,
                                    .tektronix_foreground,
                                    .tektronix_background,
                                    .highlight_background,
                                    .tektronix_cursor,
                                    .highlight_foreground,
                                    => {},
                                },
                                .special => {},
                            }
                        },

                        .reset_special => {},
                    }
                }
            },
            .kitty_color_report => {
                var response_is_empty: bool = true;

                for (value.list.items) |item| {
                    switch (item) {
                        .set => |v| switch (v.key) {
                            .palette => |palette| {
                                self.terminal.flags.dirty.palette = true;
                                self.terminal.colors.palette.set(palette, v.color);
                            },
                            .special => |special| switch (special) {
                                .foreground => self.terminal.colors.foreground.set(v.color),
                                .background => self.terminal.colors.background.set(v.color),
                                .cursor => self.terminal.colors.cursor.set(v.color),
                                .selection_foreground,
                                .selection_background,
                                .cursor_text,
                                .visual_bell,
                                .second_transparent_background,
                                => {},
                            },
                        },
                        .reset => |key| switch (key) {
                            .palette => |palette| {
                                self.terminal.flags.dirty.palette = true;
                                self.terminal.colors.palette.reset(palette);
                            },
                            .special => |special| switch (special) {
                                .foreground => self.terminal.colors.foreground.reset(),
                                .background => self.terminal.colors.background.reset(),
                                .cursor => self.terminal.colors.cursor.reset(),
                                .selection_foreground,
                                .selection_background,
                                .cursor_text,
                                .visual_bell,
                                .second_transparent_background,
                                => {},
                            },
                        },
                        .query => |key| {
                            const color = self.terminal.colorForKitty(key);
                            if (color == null and !key.hasTerminalQueryColor()) continue;

                            if (response_is_empty) {
                                try self.pty.writeAll("\x1b]21");
                                response_is_empty = false;
                            }
                            try self.pty.print(";{f}=", .{key});

                            if (color) |c| try c.encodeRgb8(self.pty);
                        },
                    }
                }

                if (!response_is_empty) {
                    try self.pty.writeAll(value.terminator.string());
                }
            },

            // APC
            .apc_start => {
                self.apc_handler.start();

                try self.vt_stream.writeAll("\x1b_");
            },
            .apc_put => {
                self.apc_handler.feed(self.gpa, value);

                try self.vt_stream.writeByte(value);
            },
            .apc_put_slice => {
                self.apc_handler.feedSlice(self.gpa, value.bytes);

                try self.vt_stream.writeAll(value.bytes);
            },
            .apc_end => {
                var result = self.apc_handler.end() orelse return;
                defer result.deinit(self.gpa);
                switch (result) {
                    .unknown => |*unknown| {
                        _ = unknown;
                    },
                    .kitty => |*kitty_cmd| if (self.terminal.kittyGraphics(
                        self.io,
                        self.gpa,
                        kitty_cmd,
                    )) |resp| {
                        try resp.encode(self.pty);
                    },

                    .glyph => |*glyph_req| {
                        if (self.terminal.glyphProtocol(self.gpa, glyph_req)) |resp| {
                            try resp.formatWire(self.pty);
                        }
                    },
                }

                try self.vt_stream.writeAll("\x1b\\");
            },

            // Effect-based handlers
            .bell => {
                try self.vt_stream.writeByte(0x07);
            },
            .show_desktop_notification => {
                try self.vt_stream.print("\x1b]9;{s};{s}\x1b\\", .{ value.title, value.body });
            },
            .device_attributes => {
                const attrs: device_attributes.Attributes = .{};
                try attrs.encode(value, self.pty);
            },
            .device_status => {
                switch (value.request) {
                    .operating_status => try self.pty.writeAll("\x1B[0n"),

                    .cursor_position => {
                        const pos: struct {
                            x: usize,
                            y: usize,
                        } = if (self.terminal.modes.get(.origin)) .{
                            .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                            .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                        } else .{
                            .x = self.terminal.screens.active.cursor.x,
                            .y = self.terminal.screens.active.cursor.y,
                        };

                        try self.pty.print("\x1B[{};{}R", .{
                            pos.y + 1,
                            pos.x + 1,
                        });
                    },

                    .color_scheme => {},

                    .visibility => {
                        try device_status.encodeVisibilityReport(
                            self.pty,
                            if (self.terminal.flags.visible) .potentially_visible else .not_visible,
                        );
                    },
                }
            },
            .enquiry => {
                // TODO(thiago): do we need this? ENQ (0x05)
            },
            .kitty_keyboard_query => {
                try self.pty.print("\x1b[?{}u", .{
                    self.terminal.screens.active.kitty_keyboard.current().int(),
                });
            },
            .request_mode => {
                const report = self.terminal.modes.getReport(.fromMode(value.mode));
                try report.encode(self.pty);
            },
            .request_mode_unknown => {
                const report = self.terminal.modes.getReport(.{
                    .value = @truncate(value.mode),
                    .ansi = value.ansi,
                });
                try report.encode(self.pty);
            },
            .size_report => {
                switch (value) {
                    .csi_21_t => {
                        const title = self.terminal.getTitle() orelse "";
                        try self.pty.print("\x1b]l{s}\x1b\\", .{title});
                    },

                    .csi_14_t, .csi_16_t, .csi_18_t => {
                        const report_style: size_report.Style = switch (value) {
                            .csi_14_t => .csi_14_t,
                            .csi_16_t => .csi_16_t,
                            .csi_18_t => .csi_18_t,
                            .csi_21_t => unreachable,
                        };
                        try size_report.encode(self.pty, report_style, .{
                            .rows = self.terminal.rows,
                            .columns = self.terminal.cols,
                            .cell_width = self.terminal.width_px / self.terminal.cols,
                            .cell_height = self.terminal.height_px / self.terminal.rows,
                        });
                    },
                }
            },
            .window_title => {
                // Prevent DoS attacks by limiting title length.
                const max_title_len = 1024;
                const title = if (value.title.len > max_title_len) title: {
                    std.log.warn("title length {d} exceeds max length {d}, truncating", .{
                        value.title.len,
                        max_title_len,
                    });
                    break :title value.title[0..max_title_len];
                } else value.title;

                try self.terminal.setTitle(title);

                try self.vt_stream.print("\x1b]0;{s}\x1b\\", .{title});
            },
            .report_pwd => {
                // Prevent DoS attacks by limiting url length. Headroom for
                // Linux PATH_MAX (4096) plus URI scheme/host and percent-encoding.
                const max_url_len = 4096;
                const url = if (value.url.len > max_url_len) url: {
                    std.log.warn("pwd url length {d} exceeds max length {d}, truncating", .{
                        value.url.len,
                        max_url_len,
                    });
                    break :url value.url[0..max_url_len];
                } else value.url;

                // We store the raw payload unparsed. Embedders read it via
                // getPwd() and are responsible for decoding any URI scheme.
                try self.terminal.setPwd(url);

                try self.vt_stream.print("\x1b]7;{s}\x1b\\", .{url});
            },
            .progress_report => {
                // Re-emit the ConEmu OSC 9;4 progress report. The state is
                // encoded as its integer value and the optional progress
                // percentage is appended when present.
                try self.vt_stream.print("\x1b]9;4;{d}", .{@intFromEnum(value.state)});
                if (value.progress) |p| {
                    try self.vt_stream.print(";{d}", .{p});
                }
                try self.vt_stream.writeAll("\x1b\\");
            },
            .xtversion => {
                const version = "zmy 0.0.1";
                try self.pty.print("\x1BP>|{s}\x1B\\", .{version});
            },
            .clipboard_contents => {
                // Read requests are deliberately not forwarded; see the effect docs.
                if (value.data.len == 1 and value.data[0] == '?') return;

                try self.vt_stream.print("\x1b]52;{c};{s}\x1b\\", .{ value.kind, value.data });
            },

            .dcs_hook => {
                var cmd = self.dcs_handler.hook(
                    self.gpa,
                    value,
                ) orelse return;
                defer cmd.deinit();
                try self.dcsCommand(&cmd);
            },
            .dcs_put => {
                var cmd = self.dcs_handler.put(value) orelse return;
                defer cmd.deinit();
                try self.dcsCommand(&cmd);
            },
            .dcs_unhook => {
                var cmd = self.dcs_handler.unhook() orelse return;
                defer cmd.deinit();
                try self.dcsCommand(&cmd);
            },

            // Have no terminal-modifying effect
            .title_push => {
                try self.vt_stream.print("\x1b[22;0;{d}t", .{value});
            },
            .title_pop => {
                try self.vt_stream.print("\x1b[23;0;{d}t", .{value});
            },
        }
    }

    fn setMode(self: *Handler, mode: modes.Mode, enabled: bool) !void {
        // Set the mode on the terminal
        self.terminal.modes.set(mode, enabled);

        // Some modes require additional processing and/or forwarding
        switch (mode) {
            .autorepeat,
            .reverse_colors,
            => {
                try self.forwardMode(mode, enabled);
            },

            .origin => {
                self.terminal.setCursorPos(1, 1);

                try self.forwardMode(mode, enabled);
            },

            .enable_left_and_right_margin => {
                if (!enabled) {
                    self.terminal.scrolling_region.left = 0;
                    self.terminal.scrolling_region.right = self.terminal.cols - 1;
                }

                try self.forwardMode(mode, enabled);
            },

            .alt_screen_legacy => {
                try self.terminal.switchScreenMode(.@"47", enabled);

                try self.forwardMode(mode, enabled);
            },
            .alt_screen => {
                try self.terminal.switchScreenMode(.@"1047", enabled);

                try self.forwardMode(mode, enabled);
            },
            .alt_screen_save_cursor_clear_enter => {
                try self.terminal.switchScreenMode(.@"1049", enabled);

                try self.forwardMode(mode, enabled);
            },

            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    self.terminal.restoreCursor();
                }

                try self.forwardMode(mode, enabled);
            },

            .enable_mode_3 => {
                try self.forwardMode(mode, enabled);
            },

            .@"132_column" => {
                try self.terminal.deccolm(
                    self.terminal.screens.active.alloc,
                    if (enabled) .@"132_cols" else .@"80_cols",
                );

                try self.forwardMode(mode, enabled);
            },

            .synchronized_output,
            .linefeed,
            .focus_event,
            => {
                try self.forwardMode(mode, enabled);
            },

            .in_band_size_reports => {
                if (enabled) {
                    try size_report.encode(self.pty, .mode_2048, .{
                        .rows = self.terminal.rows,
                        .columns = self.terminal.cols,
                        .cell_width = self.terminal.width_px / self.terminal.cols,
                        .cell_height = self.terminal.height_px / self.terminal.rows,
                    });
                }
            },

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }

                try self.forwardMode(mode, enabled);
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }

                try self.forwardMode(mode, enabled);
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }

                try self.forwardMode(mode, enabled);
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }

                try self.forwardMode(mode, enabled);
            },

            .mouse_format_utf8 => {
                self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10;

                try self.forwardMode(mode, enabled);
            },
            .mouse_format_sgr => {
                self.terminal.flags.mouse_format = if (enabled) .sgr else .x10;

                try self.forwardMode(mode, enabled);
            },
            .mouse_format_urxvt => {
                self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10;

                try self.forwardMode(mode, enabled);
            },
            .mouse_format_sgr_pixels => {
                self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10;

                try self.forwardMode(mode, enabled);
            },

            .disable_keyboard,
            .insert,
            .send_receive_mode,
            .cursor_keys,
            .slow_scroll,
            .wraparound,
            .cursor_blinking,
            .cursor_visible,
            .reverse_wrap,
            .keypad_keys,
            .backarrow_key_mode,
            .mouse_alternate_scroll,
            .ignore_keypad_with_numlock,
            .alt_esc_prefix,
            .alt_sends_escape,
            .reverse_wrap_extended,
            .bracketed_paste,
            .grapheme_cluster,
            .report_color_scheme,
            => {
                try self.forwardMode(mode, enabled);
            },
            .report_visibility => {
                if (enabled) {
                    const visibility: device_status.Visibility = if (self.terminal.flags.visible)
                        .potentially_visible
                    else
                        .not_visible;
                    try device_status.encodeVisibilityReport(self.pty, visibility);
                }

                try self.forwardMode(mode, enabled);
            },
        }
    }

    fn forwardMode(self: *Handler, mode: modes.Mode, enabled: bool) !void {
        const mode_int = @intFromEnum(mode);
        const mode_tag: modes.ModeTag = @bitCast(mode_int);
        const final_byte: u8 = if (enabled) 'h' else 'l';
        if (mode_tag.ansi) {
            try self.vt_stream.print("\x1b[{d}{c}", .{ mode_tag.value, final_byte });
        } else {
            try self.vt_stream.print("\x1b[?{d}{c}", .{ mode_tag.value, final_byte });
        }
    }

    fn dcsCommand(self: *Handler, cmd: *dcs.Command) !void {
        switch (cmd.*) {
            .decrqss => |request| {
                var response: [dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
                const encoded = try request.encode(self.terminal, &response);
                try self.pty.writeAll(encoded);
            },

            .xtgettcap => |*gettcap| {
                const map = comptime terminfo.zmy.xtgettcapMap();
                while (gettcap.next()) |key| {
                    try self.pty.writeAll(map.get(key) orelse continue);
                }
            },

            .tmux => {},
        }
    }
};

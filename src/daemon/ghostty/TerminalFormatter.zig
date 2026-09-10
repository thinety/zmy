const std = @import("std");
const ghostty = @import("ghostty-vt");

const Self = @This();

pub const Format = union(enum) {
    plain: usize,
    vt,
};

terminal: *const ghostty.Terminal,
emit: Format,

pub fn init(terminal: *const ghostty.Terminal, emit: Format) Self {
    return .{
        .terminal = terminal,
        .emit = emit,
    };
}

pub fn format(
    self: *const Self,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (self.emit == .vt) {
        // reset terminal
        try writer.writeAll("\x1bc");

        // Emit terminal modes that differ from defaults. We probably have
        // some modes we want to emit before and some after, but for now for
        // simplicity we just emit them all before. If we make this more complex
        // later we should add test cases for it.
        inline for (@typeInfo(ghostty.modes.Mode).@"enum".fields) |field| {
            const mode: ghostty.modes.Mode = @enumFromInt(field.value);
            if (mode == .in_band_size_reports) continue;
            if (mode == .report_visibility) continue;
            const current = self.terminal.modes.get(mode);
            const default_val = @field(self.terminal.modes.default, field.name);

            if (current != default_val) {
                const tag: ghostty.modes.ModeTag = @bitCast(@intFromEnum(mode));
                const prefix = if (tag.ansi) "" else "?";
                const suffix = if (current) "h" else "l";
                try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
            }
        }
    }

    try self.formatScreen(self.terminal.screens.active, writer);

    if (self.emit == .vt) {
        // Extra terminal state to emit after the screen contents so that
        // it doesn't impact the emitted contents.

        // Emit scrolling region using DECSTBM and DECSLRM
        {
            const region = &self.terminal.scrolling_region;

            // DECSTBM: top and bottom margins (1-indexed)
            // Only emit if not the full screen
            if (region.top != 0 or region.bottom != self.terminal.rows - 1) {
                try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
            }

            // DECSLRM: left and right margins (1-indexed)
            // Only emit if not the full width
            if (region.left != 0 or region.right != self.terminal.cols - 1) {
                try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
            }
        }

        // Emit keyboard modes such as ModifyOtherKeys
        // Only emit if modify_other_keys_2 is true
        if (self.terminal.flags.modify_other_keys_2) {
            try writer.print("\x1b[>4;2m", .{});
        }

        // Emit present working directory using OSC 7
        {
            const pwd = self.terminal.pwd.items;
            if (pwd.len > 0) try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
        }
    }
}

fn formatScreen(
    self: *const Self,
    screen: *const ghostty.Screen,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    {
        var tl = screen.pages.getTopLeft(.screen);
        switch (self.emit) {
            .plain => |lines| {
                const br = screen.pages.getBottomRight(.screen).?;
                var it = br.rowIterator(.left_up, null);
                for (0..lines) |_| {
                    tl = it.next() orelse break;
                }
            },
            .vt => {},
        }

        var it = tl.rowIterator(.right_down, null);
        var row_state: RowState = .{};
        while (it.next()) |pin| {
            try self.formatRow(pin, &row_state, writer);
        }
    }

    if (self.emit == .vt) {
        // Emit extra screen state after content. The state has
        // to be emitted after since some state such as cursor position and
        // style are impacted by content rendering.

        {
            const cursor = &screen.cursor;

            // Emit current SGR style state
            try writer.print("{f}", .{cursor.style.formatterVt()});

            // Emit current hyperlink state using OSC 8
            if (cursor.hyperlink) |link| {
                // Start hyperlink with uri (and explicit id if present)
                switch (link.id) {
                    .explicit => |id| try writer.print(
                        "\x1b]8;id={s};{s}\x1b\\",
                        .{ id, link.uri },
                    ),
                    .implicit => try writer.print(
                        "\x1b]8;;{s}\x1b\\",
                        .{link.uri},
                    ),
                }
            }

            // Emit character protection mode using DECSCA
            if (cursor.protected) {
                // DEC protected mode
                try writer.print("\x1b[1\"q", .{});
            }

            // Emit cursor position using CUP (CSI H)
            // CUP is 1-indexed
            try writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });

            // Emit cursor style via DECSCUSR
            const blink = self.terminal.modes.get(.cursor_blinking);
            const style: u8 = switch (cursor.cursor_style) {
                .block => if (blink) 1 else 2,
                .underline => if (blink) 3 else 4,
                .bar => if (blink) 5 else 6,

                // Below here, the cursor styles aren't represented by
                // DECSCUSR so we map it to some other style.
                .block_hollow => if (blink) 1 else 2,
            };
            try writer.print("\x1b[{d} q", .{style});
        }

        // Emit Kitty keyboard protocol state using CSI = u
        {
            const current_flags = screen.kitty_keyboard.current();
            if (current_flags.int() != ghostty.kitty.KeyFlags.disabled.int()) {
                const flags = current_flags.int();
                try writer.print("\x1b[={d};1u", .{flags});
            }
        }

        // Emit character set designations and invocations
        {
            const charset = &screen.charset;

            // Emit G0-G3 designations
            for (std.enums.values(ghostty.CharsetSlot)) |slot| {
                const cs = charset.charsets.get(slot);
                if (cs != .utf8) { // Only emit non-default charsets
                    const intermediate: u8 = switch (slot) {
                        .G0 => '(',
                        .G1 => ')',
                        .G2 => '*',
                        .G3 => '+',
                    };
                    const final: u8 = switch (cs) {
                        .ascii => 'B',
                        .british => 'A',
                        .dec_special => '0',
                        .utf8 => continue,
                    };
                    try writer.print("\x1b{c}{c}", .{ intermediate, final });
                }
            }

            // Emit GL invocation if not G0
            if (charset.gl != .G0) {
                const seq = switch (charset.gl) {
                    .G0 => unreachable,
                    .G1 => "\x0e", // SO - Shift Out
                    .G2 => "\x1bn", // LS2
                    .G3 => "\x1bo", // LS3
                };
                try writer.print("{s}", .{seq});
            }

            // Emit GR invocation if not G2
            if (charset.gr != .G2) {
                const seq = switch (charset.gr) {
                    .G0 => unreachable, // GR can't be G0
                    .G1 => "\x1b~", // LS1R
                    .G2 => unreachable,
                    .G3 => "\x1b|", // LS3R
                };
                try writer.print("{s}", .{seq});
            }
        }
    }
}

const RowState = struct {
    first_row: bool = true,
    blank_cells: usize = 0,
    style: ghostty.Style = .{},
};

fn formatRow(
    self: *const Self,
    pin: ghostty.PageList.Pin,
    state: *RowState,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const page = pin.node.page();
    const row = page.getRow(pin.y);
    const cells = page.getCells(row);

    if (!state.first_row and !row.wrap_continuation) {
        // This row doesn't continue a wrap, so we need to reset
        // our blank cell count. When it is the first row, the blank
        // cell count is also zero.
        state.blank_cells = 0;

        // Add a newline if not the first row and not continuing a wrap.

        if (self.emit == .vt) {
            // Reset style before emitting newlines to prevent background
            // colors from bleeding into the next line's leading cells.
            if (!state.style.default()) {
                state.style = .{};
                try writer.print("{f}", .{state.style.formatterVt()});
            }
        }
        switch (self.emit) {
            .plain => {
                try writer.writeAll("\n");
            },
            .vt => {
                try writer.writeAll("\r\n");
            },
        }
    }
    state.first_row = false;

    // Go through each cell and print it
    for (cells) |*cell| {
        // Skip spacers. These happen naturally when wide characters
        // are printed again on the screen (for well-behaved terminals!)
        switch (cell.wide) {
            .spacer_head, .spacer_tail => continue,
            .narrow, .wide => {},
        }

        // If we have a zero value, then we accumulate a counter. We
        // only want to turn zero values into spaces if we have a non-zero
        // char sometime later.
        // If we're emitting styled output (not plaintext) and
        // the cell has some kind of styling or is not empty
        // then this isn't blank.
        // Cells with no text are blank
        const is_blank = switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => switch (self.emit) {
                .plain => !cell.hasText(),
                .vt => !cell.hasText() and !cell.hasStyling(),
            },
            .bg_color_palette, .bg_color_rgb => switch (self.emit) {
                .plain => true,
                .vt => false,
            },
        };
        if (is_blank) {
            state.blank_cells += 1;
            continue;
        }
        if (state.blank_cells > 0) {
            try writer.splatByteAll(' ', state.blank_cells);
            state.blank_cells = 0;
        }

        if (self.emit == .vt) {
            const cell_style: ghostty.Style = switch (cell.content_tag) {
                .codepoint,
                .codepoint_grapheme,
                => if (cell.hasStyling())
                    page.styles.get(page.memory, cell.style_id).*
                else
                    .{},
                .bg_color_palette => .{
                    .bg_color = .{
                        .palette = cell.content.color_palette.data,
                    },
                },
                .bg_color_rgb => .{
                    .bg_color = .{
                        .rgb = .{
                            .r = cell.content.color_rgb.r,
                            .g = cell.content.color_rgb.g,
                            .b = cell.content.color_rgb.b,
                        },
                    },
                },
            };
            if (!cell_style.eql(state.style)) {
                state.style = cell_style;
                try writer.print("{f}", .{state.style.formatterVt()});
            }
        }

        switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => {
                if (!cell.hasText()) {
                    try writer.writeByte(' ');
                } else {
                    try writer.print("{u}", .{cell.content.codepoint.data});
                }
                if (page.lookupGrapheme(cell)) |grapheme| {
                    for (grapheme) |cp| {
                        try writer.print("{u}", .{cp});
                    }
                }
            },
            .bg_color_palette, .bg_color_rgb => {
                try writer.writeByte(' ');
            },
        }

        // TODO(thiago): cell.hyperlink

        // TODO(thiago): cell.semantic_content
    }
}

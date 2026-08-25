const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Terminal = ghostty_vt.Terminal;
const Screen = ghostty_vt.Screen;
const PageList = ghostty_vt.PageList;
const Page = ghostty_vt.Page;
const Coordinate = ghostty_vt.Coordinate;
const Style = ghostty_vt.Style;
const Row = ghostty_vt.page.Row;
const Cell = ghostty_vt.page.Cell;
const modes = ghostty_vt.modes;
const kitty = ghostty_vt.kitty;
const charsets = struct {
    const Slots = ghostty_vt.CharsetSlot;
};
const size = ghostty_vt.size;

pub fn formatTerminal(
    terminal: *const Terminal,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    // Emit terminal modes that differ from defaults. We probably have
    // some modes we want to emit before and some after, but for now for
    // simplicity we just emit them all before. If we make this more complex
    // later we should add test cases for it.
    {
        inline for (@typeInfo(modes.Mode).@"enum".fields) |field| {
            const mode: modes.Mode = @enumFromInt(field.value);
            const current = terminal.modes.get(mode);
            const default_val = @field(terminal.modes.default, field.name);

            if (current != default_val) {
                const tag: modes.ModeTag = @bitCast(@intFromEnum(mode));
                const prefix = if (tag.ansi) "" else "?";
                const suffix = if (current) "h" else "l";
                try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
            }
        }
    }

    try formatScreen(terminal, terminal.screens.active, writer);

    // Extra terminal state to emit after the screen contents so that
    // it doesn't impact the emitted contents.
    {
        // Emit scrolling region using DECSTBM and DECSLRM
        {
            const region = &terminal.scrolling_region;

            // DECSTBM: top and bottom margins (1-indexed)
            // Only emit if not the full screen
            if (region.top != 0 or region.bottom != terminal.rows - 1) {
                try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
            }

            // DECSLRM: left and right margins (1-indexed)
            // Only emit if not the full width
            if (region.left != 0 or region.right != terminal.cols - 1) {
                try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
            }
        }

        // Emit keyboard modes such as ModifyOtherKeys
        {
            // Only emit if modify_other_keys_2 is true
            if (terminal.flags.modify_other_keys_2) {
                try writer.print("\x1b[>4;2m", .{});
            }
        }

        // Emit present working directory using OSC 7
        {
            const pwd = terminal.pwd.items;
            if (pwd.len > 0) try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
        }
    }
}

fn formatScreen(
    terminal: *const Terminal,
    screen: *const Screen,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    {
        // Emit our pagelist contents according to our selection.
        try formatPageList(&screen.pages, writer);
    }

    // Emit extra screen state after content. The state has
    // to be emitted after since some state such as cursor position and
    // style are impacted by content rendering.

    // Emit current SGR style state
    {
        const cursor = &screen.cursor;
        try writer.print("{f}", .{cursor.style.formatterVt()});
    }

    // Emit current hyperlink state using OSC 8
    {
        const cursor = &screen.cursor;
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
    }

    // Emit character protection mode using DECSCA
    {
        const cursor = &screen.cursor;
        if (cursor.protected) {
            // DEC protected mode
            try writer.print("\x1b[1\"q", .{});
        }
    }

    // Emit Kitty keyboard protocol state using CSI = u
    {
        const current_flags = screen.kitty_keyboard.current();
        if (current_flags.int() != kitty.KeyFlags.disabled.int()) {
            const flags = current_flags.int();
            try writer.print("\x1b[={d};1u", .{flags});
        }
    }

    // Emit character set designations and invocations
    {
        const charset = &screen.charset;

        // Emit G0-G3 designations
        for (std.enums.values(charsets.Slots)) |slot| {
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

    // Emit cursor position using CUP (CSI H)
    {
        const cursor = &screen.cursor;
        // CUP is 1-indexed
        try writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });

        const blink = terminal.modes.get(.cursor_blinking);
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
}

fn formatPageList(
    list: *const PageList,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const tl: PageList.Pin = list.getTopLeft(.screen);
    const br: PageList.Pin = list.getBottomRight(.screen).?;

    var page_state: TrailingState = .empty;
    var iter = tl.pageIterator(.right_down, br);
    while (iter.next()) |chunk| {
        std.debug.assert(chunk.start < chunk.end);
        std.debug.assert(chunk.end > 0);

        page_state = try formatPage(
            chunk.node.page(),
            if (chunk.node == tl.node) tl.x else 0,
            chunk.start,
            if (chunk.node == br.node) br.x else null,
            chunk.end - 1,
            page_state,
            writer,
        );
    }
}

const TrailingState = struct {
    cells: usize,

    const empty: TrailingState = .{ .cells = 0 };
};

fn formatPage(
    page: *const Page,
    /// Start and end points within the page to format. If end x is not given
    /// then it will be the full width. If end y is not given then it will be
    /// the full height.
    ///
    /// The start and end are both inclusive, so equal values will still
    /// return a non-empty result (i.e. a single cell or row).
    ///
    /// The start x is considered the X in the first row and end X is
    /// X in the final row. This isn't a rectangle selection by default.
    ///
    /// If start X falls on the second column of a wide character, then
    /// the entire character will be included (as if you specified the
    /// previous column).
    start_x: size.CellCountInt,
    start_y: size.CellCountInt,
    end_x_: ?size.CellCountInt,
    end_y_: ?size.CellCountInt,
    /// Trailing state. This is used to ensure that rows wrapped across
    /// multiple pages are unwrapped properly, as well as other accounting
    /// we may do in the future.
    trailing_state: TrailingState,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!TrailingState {
    var blank_cells: usize = 0;

    // Continue our prior trailing state if we have it, but only if we're
    // starting from the beginning (start_y and start_x are both 0).
    // If a non-zero start position is specified, ignore trailing state.
    {
        if (start_y == 0 and start_x == 0) {
            blank_cells = trailing_state.cells;
        }
    }

    // Setup our starting column and perform some validation for overflows.
    // Note: start_x only applies to the first row, end_x only applies to the last row.
    if (start_x >= page.size.cols) return .{ .cells = blank_cells };
    const end_x_unclamped: size.CellCountInt = end_x_ orelse page.size.cols - 1;
    var end_x = @min(end_x_unclamped, page.size.cols - 1);

    // Setup our starting row and perform some validation for overflows.
    if (start_y >= page.size.rows) return .{ .cells = blank_cells };
    const end_y_unclamped: size.CellCountInt = end_y_ orelse page.size.rows - 1;
    if (start_y > end_y_unclamped) return .{ .cells = blank_cells };
    var end_y = @min(end_y_unclamped, page.size.rows - 1);

    // Edge case: if our end x/y falls on a spacer head AND we're unwrapping,
    // then we move the x/y to the start of the next row (if available).
    {
        const final_row = page.getRow(end_y);
        const cells = page.getCells(final_row);
        switch (cells[end_x].wide) {
            .spacer_head => {
                // Move to next row if available
                //
                // TODO: if unavailable, we should add to our trailing state
                //
                // so the pagelist formatter can be aware and maybe add
                // another page
                if (end_y < page.size.rows - 1) {
                    end_y += 1;
                    end_x = 0;
                }
            },
            .narrow, .wide, .spacer_tail => {},
        }
    }

    // If we only have a single row, validate that start_x <= end_x
    if (start_y == end_y and start_x > end_x) {
        return .{ .cells = blank_cells };
    }

    // Our style for non-plain formats
    var style: Style = .{};

    // TODO(thiago): hyperlink
    // Track hyperlink state for HTML output. We need to close </a> tags
    // when the hyperlink changes or ends.
    // var current_hyperlink_id: ?hyperlink.Id = null;

    for (start_y..end_y + 1) |y_usize| {
        const y: size.CellCountInt = @intCast(y_usize);
        const row: *Row = page.getRow(y);
        const cells: []const Cell = page.getCells(row);

        // Determine the x range for this row
        // - First row: start_x to end of row (or end_x if single row)
        // - Last row: start of row to end_x
        // - Middle rows: full width
        const cells_subset = cells_subset: {
            // The end is always straightforward
            const row_end_x: size.CellCountInt = if (y == end_y)
                end_x + 1
            else
                page.size.cols;

            // The first we have to check if our start X falls on the
            // tail of a wide character.
            const row_start_x: size.CellCountInt = if (start_x > 0 and
                (y == start_y))
            start_x: {
                break :start_x switch (cells[start_x].wide) {
                    // Include the prior cell to get the full wide char
                    .spacer_tail => start_x - 1,

                    // If we're a spacer head on our first row then we
                    // skip this whole row.
                    .spacer_head => continue,

                    .narrow, .wide => start_x,
                };
            } else 0;

            const subset = cells[row_start_x..row_end_x];
            break :cells_subset subset;
        };

        if (!row.wrap_continuation) {
            // This row doesn't continue a wrap, so we need to reset
            // our blank cell count.
            blank_cells = 0;
        }

        // Add a newline if not the first row and not continuing a wrap.
        if (y_usize > start_y and !row.wrap_continuation) {
            // Reset style before emitting newlines to prevent background
            // colors from bleeding into the next line's leading cells.
            if (!style.default()) {
                try formatStyleClose(writer);
                style = .{};
            }

            // VT uses \r\n because in a raw pty, \n alone doesn't
            // guarantee moving the cursor back to column 0. \r
            // makes it work for sure.
            try writer.writeAll("\r\n");
        }

        // Go through each cell and print it
        for (cells_subset) |*cell| {
            // Skip spacers. These happen naturally when wide characters
            // are printed again on the screen (for well-behaved terminals!)
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If we have a zero value, then we accumulate a counter. We
            // only want to turn zero values into spaces if we have a non-zero
            // char sometime later.
            // If we're emitting styled output (not plaintext) and
            // the cell has some kind of styling or is not empty
            // then this isn't blank.
            // Cells with no text are blank
            if (cell.isEmpty() and !cell.hasStyling()) {
                blank_cells += 1;
                continue;
            }

            // This cell is not blank. If we have accumulated blank cells
            // then we want to emit them now.
            if (blank_cells > 0) {
                try writer.splatByteAll(' ', blank_cells);
                blank_cells = 0;
            }

            style: {
                // Get our cell style.
                const cell_style = cellStyle(page, cell);

                // If the style hasn't changed, don't bloat output.
                if (cell_style.eql(style)) break :style;

                // If we had a previous style, we need to close it,
                // because we've confirmed we have some new style
                // (which is maybe default).
                //
                // For VT, we only close if we're switching to a default
                // style because any non-default style will emit
                // a \x1b[0m as the start of a VT coloring sequence.
                if (!style.default()) {
                    if (cell_style.default()) try formatStyleClose(writer);
                }

                // At this point, we can copy our style over
                style = cell_style;

                // If we're just the default style now, we're done.
                if (cell_style.default()) break :style;

                // New style, emit it.
                try formatStyleOpen(
                    writer,
                    &style,
                );
            }

            // TODO(thiago): hyperlink
            // // Hyperlink state
            // hyperlink: {
            //     // We currently only emit hyperlinks for HTML. In the
            //     // future we can support emitting OSC 8 hyperlinks for
            //     // VT output as well.
            //     if (self.opts.emit != .html) break :hyperlink;
            //
            //     // Get the hyperlink ID. This ID is our internal ID,
            //     // not necessarily the OSC8 ID.
            //     const link_id_: ?u16 = if (cell.hyperlink)
            //         page.lookupHyperlink(cell)
            //     else
            //         null;
            //
            //     // If our hyperlink IDs match (even null) then we have
            //     // identical hyperlink state and we do nothing.
            //     if (current_hyperlink_id == link_id_) break :hyperlink;
            //
            //     // If our prior hyperlink ID was non-null, we need to
            //     // close it because the ID has changed.
            //     if (current_hyperlink_id != null) {
            //         try formatHyperlinkClose(writer);
            //         current_hyperlink_id = null;
            //     }
            //
            //     // Set our current hyperlink ID
            //     const link_id = link_id_ orelse break :hyperlink;
            //     current_hyperlink_id = link_id;
            //
            //     // Emit the opening hyperlink tag
            //     const uri = uri: {
            //         const link = page.hyperlink_set.get(
            //             page.memory,
            //             link_id,
            //         );
            //         break :uri link.uri.offset.ptr(page.memory)[0..link.uri.len];
            //     };
            //     try formatHyperlinkOpen(
            //         writer,
            //         uri,
            //     );
            // }

            switch (cell.content_tag) {
                // We combine codepoint and graphemes because both have
                // shared style handling. We use comptime to dup it.
                inline .codepoint, .codepoint_grapheme => |tag| {
                    try writeCell(page, tag, writer, cell);
                },

                // Cells with only background color (no text). Emit a space
                // with the appropriate background color SGR sequence.
                .bg_color_palette, .bg_color_rgb => {
                    try writer.writeByte(' ');
                },
            }
        }
    }

    // If the style is non-default, we need to close our style tag.
    if (!style.default()) try formatStyleClose(writer);

    // TODO(thiago): hyperlink
    // Close any open hyperlink for HTML output
    // if (current_hyperlink_id != null) try formatHyperlinkClose(writer);

    return .{ .cells = blank_cells };
}

fn writeCell(
    page: *const Page,
    comptime tag: Cell.ContentTag,
    writer: *std.Io.Writer,
    cell: *const Cell,
) !void {
    // Blank cells get an empty space that isn't replaced by anything
    // because it isn't really a space. We do this so that formatting
    // is preserved if we're emitting styles.
    if (!cell.hasText()) {
        try writer.writeByte(' ');
        return;
    }

    try writeCodepoint(writer, cell.content.codepoint.data);
    if (comptime tag == .codepoint_grapheme) {
        for (page.lookupGrapheme(cell).?) |cp| {
            try writeCodepoint(writer, cp);
        }
    }
}

fn writeCodepoint(
    writer: *std.Io.Writer,
    codepoint: u21,
) !void {
    try writer.print("{u}", .{codepoint});
}

// Returns the style for the given cell. If there is no styling this
// will return the default style.
fn cellStyle(
    page: *const Page,
    cell: *const Cell,
) Style {
    return switch (cell.content_tag) {
        inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling())
            .{}
        else
            page.styles.get(
                page.memory,
                cell.style_id,
            ).*,

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
}

fn formatStyleOpen(
    writer: *std.Io.Writer,
    style: *const Style,
) std.Io.Writer.Error!void {
    const formatter = style.formatterVt();
    try writer.print("{f}", .{formatter});
}

fn formatStyleClose(
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll("\x1b[0m");
}

// fn formatHyperlinkOpen(
//     writer: *std.Io.Writer,
//     uri: []const u8,
// ) std.Io.Writer.Error!void {
//     unreachable;
//
//     // layout since we're primarily using it as a CSS wrapper.
//     {
//         try writer.writeAll("<a href=\"");
//         for (uri) |byte| try writeCodepoint(
//             writer,
//             byte,
//         );
//         try writer.writeAll("\">");
//     }
// }
//
// fn formatHyperlinkClose(
//     writer: *std.Io.Writer,
// ) std.Io.Writer.Error!void {
//     return;
//
//     const str: []const u8 = "</a>";
//     try writer.writeAll(str);
// }

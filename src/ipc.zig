const std = @import("std");

pub const Winsize = struct {
    col: u16,
    row: u16,
    xpixel: u16,
    ypixel: u16,
};

pub const ClientMessage = union(enum(u8)) {
    resize: Winsize,
    data: []u8,

    pub const Tag = @typeInfo(ClientMessage).@"union".tag_type.?;

    pub fn deinit(self: *ClientMessage, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .resize => |winsize| {
                _ = winsize;
            },
            .data => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }

    pub fn serialize(value: *const ClientMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(@typeInfo(Tag).@"enum".tag_type, @intFromEnum(value.*), .little);
        switch (value.*) {
            .resize => |winsize| {
                try writer.writeInt(u16, winsize.col, .little);
                try writer.writeInt(u16, winsize.row, .little);
                try writer.writeInt(u16, winsize.xpixel, .little);
                try writer.writeInt(u16, winsize.ypixel, .little);
            },
            .data => |data| {
                try writer.writeInt(usize, data.len, .little);
                try writer.writeAll(data);
            },
        }
    }

    pub fn deserialize(gpa: std.mem.Allocator, reader: *std.Io.Reader) !ClientMessage {
        const tag = try reader.takeEnum(Tag, .little);
        switch (tag) {
            .resize => {
                const col = try reader.takeInt(u16, .little);
                const row = try reader.takeInt(u16, .little);
                const xpixel = try reader.takeInt(u16, .little);
                const ypixel = try reader.takeInt(u16, .little);
                return .{ .resize = .{
                    .col = col,
                    .row = row,
                    .xpixel = xpixel,
                    .ypixel = ypixel,
                } };
            },
            .data => {
                const len = try reader.takeInt(usize, .little);

                const data = try gpa.alloc(u8, len);
                errdefer gpa.free(data);

                try reader.readSliceAll(data);

                return .{ .data = data };
            },
        }
    }
};

pub const DaemonMessage = union(enum(u0)) {
    data: []u8,

    pub const Tag = @typeInfo(DaemonMessage).@"union".tag_type.?;

    pub fn deinit(self: *DaemonMessage, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .data => |data| {
                gpa.free(data);
            },
        }
        self.* = undefined;
    }

    pub fn serialize(value: *const DaemonMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(@typeInfo(Tag).@"enum".tag_type, @intFromEnum(value.*), .little);
        switch (value.*) {
            .data => |data| {
                try writer.writeInt(usize, data.len, .little);
                try writer.writeAll(data);
            },
        }
    }

    pub fn deserialize(gpa: std.mem.Allocator, reader: *std.Io.Reader) !DaemonMessage {
        const tag = try reader.takeEnum(Tag, .little);
        switch (tag) {
            .data => {
                const len = try reader.takeInt(usize, .little);

                const data = try gpa.alloc(u8, len);
                errdefer gpa.free(data);

                try reader.readSliceAll(data);

                return .{ .data = data };
            },
        }
    }
};

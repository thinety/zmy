const std = @import("std");

pub const ClientMessage = union(enum(u8)) {
    resize: struct {
        width: u32,
        height: u32,
        x_pixel: u32,
        y_pixel: u32,
    },
    data: struct {
        length: usize,
    },

    pub const Tag = @typeInfo(ClientMessage).@"union".tag_type.?;

    pub fn serialize(value: *const ClientMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(@typeInfo(Tag).@"enum".tag_type, @intFromEnum(value.*), .little);
        switch (value.*) {
            .resize => |resize| {
                try writer.writeInt(u32, resize.width, .little);
                try writer.writeInt(u32, resize.height, .little);
                try writer.writeInt(u32, resize.x_pixel, .little);
                try writer.writeInt(u32, resize.y_pixel, .little);
            },
            .data => |data| {
                try writer.writeInt(usize, data.length, .little);
            },
        }
    }

    pub fn deserialize(reader: *std.Io.Reader) !ClientMessage {
        const tag = try reader.takeEnum(Tag, .little);
        switch (tag) {
            .resize => {
                const width = try reader.takeInt(u32, .little);
                const height = try reader.takeInt(u32, .little);
                const x_pixel = try reader.takeInt(u32, .little);
                const y_pixel = try reader.takeInt(u32, .little);
                return .{ .resize = .{
                    .width = width,
                    .height = height,
                    .x_pixel = x_pixel,
                    .y_pixel = y_pixel,
                } };
            },
            .data => {
                const length = try reader.takeInt(usize, .little);
                return .{ .data = .{
                    .length = length,
                } };
            },
        }
    }
};

pub const DaemonMessage = union(enum(u0)) {
    data: struct {
        length: usize,
    },

    pub const Tag = @typeInfo(DaemonMessage).@"union".tag_type.?;

    pub fn serialize(value: *const DaemonMessage, writer: *std.Io.Writer) !void {
        try writer.writeInt(@typeInfo(Tag).@"enum".tag_type, @intFromEnum(value.*), .little);
        switch (value.*) {
            .data => |data| {
                try writer.writeInt(usize, data.length, .little);
            },
        }
    }

    pub fn deserialize(reader: *std.Io.Reader) !DaemonMessage {
        const tag = try reader.takeEnum(Tag, .little);
        switch (tag) {
            .data => {
                const length = try reader.takeInt(usize, .little);
                return .{ .data = .{
                    .length = length,
                } };
            },
        }
    }
};

const std = @import("std");

pub fn join(io: std.Io, args: anytype) error{ ConcurrencyUnavailable, Canceled }!joinTuple(@TypeOf(args)) {
    const A = @TypeOf(args);
    const U = selectUnion(A);
    const N = comptime taskCount(A);

    var result: joinTuple(A) = undefined;
    var initialized: [N]bool = @splat(false);

    var select_buffer: [N]U = undefined;
    var select: std.Io.Select(U) = .init(io, &select_buffer);

    errdefer {
        inline for (0..N) |i| {
            if (initialized[i]) {
                if (cancelFn(args[i])) |cancel| {
                    cancel(result[i]);
                }
            }
        }
        while (select.cancel()) |v| {
            switch (v) {
                inline else => |x, tag| {
                    const i = @intFromEnum(tag);
                    if (cancelFn(args[i])) |cancel| {
                        cancel(x);
                    }
                },
            }
        }
    }

    inline for (0..N) |i| {
        try select.concurrent(@enumFromInt(i), args[i][0], args[i][1]);
    }

    for (0..N) |_| {
        switch (try select.await()) {
            inline else => |x, tag| {
                const i = @intFromEnum(tag);
                result[i] = x;
                initialized[i] = true;
            },
        }
    }

    return result;
}

pub fn tryJoin(io: std.Io, args: anytype) error{ ConcurrencyUnavailable, Canceled }!allErrors(@TypeOf(args))!payloadTuple(@TypeOf(args)) {
    const A = @TypeOf(args);
    const U = selectUnion(A);
    const N = comptime taskCount(A);

    var result: payloadTuple(A) = undefined;
    var initialized: [N]bool = @splat(false);

    var select_buffer: [N]U = undefined;
    var select: std.Io.Select(U) = .init(io, &select_buffer);

    errdefer {
        inline for (0..N) |i| {
            if (initialized[i]) {
                if (cancelFn(args[i])) |cancel| {
                    cancel(result[i]);
                }
            }
        }
        while (select.cancel()) |v| {
            switch (v) {
                inline else => |x, tag| {
                    const i = @intFromEnum(tag);
                    if (cancelFn(args[i])) |cancel| {
                        cancel(x);
                    }
                },
            }
        }
    }

    inline for (0..N) |i| {
        try select.concurrent(@enumFromInt(i), args[i][0], args[i][1]);
    }

    for (0..N) |_| {
        switch (try select.await()) {
            inline else => |r, tag| {
                const i = @intFromEnum(tag);
                if (r) |x| {
                    result[i] = x;
                    initialized[i] = true;
                } else |err| {
                    // the errdefer block still runs even though the outer
                    // error union is carrying a payload
                    return @as(allErrors(A)!payloadTuple(A), err);
                }
            },
        }
    }

    return result;
}

pub fn raceOk(io: std.Io, args: anytype) error{ ConcurrencyUnavailable, Canceled }!union(enum) {
    err: errorTuple(@TypeOf(args)),
    ok: commonPayload(@TypeOf(args)),
} {
    const A = @TypeOf(args);
    const U = selectUnion(A);
    const N = comptime taskCount(A);

    var errors: errorTuple(A) = undefined;

    var select_buffer: [N]U = undefined;
    var select: std.Io.Select(U) = .init(io, &select_buffer);

    defer {
        while (select.cancel()) |v| {
            switch (v) {
                inline else => |x, tag| {
                    const i = @intFromEnum(tag);
                    if (cancelFn(args[i])) |cancel| {
                        cancel(x);
                    }
                },
            }
        }
    }

    inline for (0..N) |i| {
        try select.concurrent(@enumFromInt(i), args[i][0], args[i][1]);
    }

    for (0..N) |_| {
        switch (try select.await()) {
            inline else => |r, tag| {
                const i = @intFromEnum(tag);
                if (r) |x| {
                    return .{ .ok = x };
                } else |err| {
                    errors[i] = err;
                }
            },
        }
    }

    return .{ .err = errors };
}

pub fn race(io: std.Io, args: anytype) error{ ConcurrencyUnavailable, Canceled }!allErrors(@TypeOf(args))!commonPayload(@TypeOf(args)) {
    const A = @TypeOf(args);
    const U = selectUnion(A);
    const N = comptime taskCount(A);

    var select_buffer: [N]U = undefined;
    var select: std.Io.Select(U) = .init(io, &select_buffer);

    defer {
        while (select.cancel()) |v| {
            switch (v) {
                inline else => |x, tag| {
                    const i = @intFromEnum(tag);
                    if (cancelFn(args[i])) |cancel| {
                        cancel(x);
                    }
                },
            }
        }
    }

    inline for (0..N) |i| {
        try select.concurrent(@enumFromInt(i), args[i][0], args[i][1]);
    }

    switch (try select.await()) {
        inline else => |x| {
            return x;
        },
    }
}

fn joinTuple(A: type) type {
    var types: [taskCount(A)]type = undefined;
    for (0..taskCount(A)) |i| {
        types[i] = taskRet(A, i);
    }
    return @Tuple(&types);
}

fn allErrors(A: type) type {
    var E: type = error{};
    for (0..taskCount(A)) |i| {
        E = E || @typeInfo(taskRet(A, i)).error_union.error_set;
    }
    return E;
}

fn payloadTuple(A: type) type {
    var types: [taskCount(A)]type = undefined;
    for (0..taskCount(A)) |i| {
        types[i] = @typeInfo(taskRet(A, i)).error_union.payload;
    }
    return @Tuple(&types);
}

fn errorTuple(A: type) type {
    var types: [taskCount(A)]type = undefined;
    for (0..taskCount(A)) |i| {
        types[i] = @typeInfo(taskRet(A, i)).error_union.error_set;
    }
    return @Tuple(&types);
}

fn commonPayload(A: type) type {
    const P0 = @typeInfo(taskRet(A, 0)).error_union.payload;
    for (1..taskCount(A)) |i| {
        const Pi = @typeInfo(taskRet(A, i)).error_union.payload;
        if (Pi != P0) {
            @compileError(std.fmt.comptimePrint(
                "race/raceOk require all tasks to return the same payload type; " ++
                    "task 0 returns '{s}' but task {d} returns '{s}'",
                .{ @typeName(P0), i, @typeName(Pi) },
            ));
        }
    }
    return P0;
}

fn selectUnion(A: type) type {
    const N = taskCount(A);

    var names: [N][]const u8 = undefined;
    var vals: [N]u32 = undefined;
    var types: [N]type = undefined;
    var attrs: [N]std.builtin.Type.UnionField.Attributes = undefined;

    for (0..N) |i| {
        names[i] = std.fmt.comptimePrint("{d}", .{i});
        vals[i] = i;
        types[i] = taskRet(A, i);
        attrs[i] = .{};
    }

    return @Union(.auto, @Enum(u32, .exhaustive, &names, &vals), &names, &types, &attrs);
}

fn taskRet(A: type, i: u32) type {
    return @typeInfo(
        @typeInfo(
            @typeInfo(A).@"struct".fields[i].type,
        ).@"struct".fields[0].type,
    ).@"fn".return_type.?;
}

fn taskCount(A: type) u32 {
    return @typeInfo(A).@"struct".fields.len;
}

inline fn cancelFn(task: anytype) ?*const fn (@typeInfo(@typeInfo(@TypeOf(task)).@"struct".fields[0].type).@"fn".return_type.?) void {
    if (task.len <= 2) return null;
    return task[2];
}

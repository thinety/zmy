const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_step = b.step("check", "Check if zmy compiles");
    const install_step = b.getInstallStep();
    const run_step = b.step("run", "Run zmy");
    const test_step = b.step("test", "Run tests");

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        // Setting simd to false will force a pure static build that
        // doesn't even require libc, but it has a significant performance
        // penalty. If your embedding app requires libc anyway, you should
        // always keep simd enabled.
        // .simd = false,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
            .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
        },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zmy",
        .root_module = exe_mod,
        // TODO(thiago): FIXME: https://codeberg.org/ziglang/zig/issues/31272
        .use_llvm = true,
        .use_lld = true,
    });
    check_step.dependOn(&exe.step);

    const exe_install = b.addInstallArtifact(exe, .{});
    install_step.dependOn(&exe_install.step);

    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
    exe_run.step.dependOn(&exe_install.step);
    run_step.dependOn(&exe_run.step);

    const exe_test = b.addTest(.{
        .root_module = exe_mod,
        // TODO(thiago): FIXME: https://codeberg.org/ziglang/zig/issues/31272
        .use_llvm = true,
        .use_lld = true,
    });

    const exe_test_run = b.addRunArtifact(exe_test);
    test_step.dependOn(&exe_test_run.step);
}

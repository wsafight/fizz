/// fizz 构建配置
///
/// 构建步骤：
///   zig build run           — 编译并运行主程序（counter 示例）
///   zig build test          — 运行所有模块的单元测试
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 导出库模块，供外部项目通过 b.dependency(...).module("fizz") 引用。
    const fizz_module = b.addModule("fizz", .{
        .root_source_file = b.path("src/fizz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── 主程序可执行文件 ──

    const root_module = b.createModule(.{
        .root_source_file = b.path("examples/counter/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fizz", .module = fizz_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "fizz",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run fizz");
    run_step.dependOn(&run_cmd.step);

    // ── 单元测试 ──

    const test_step = b.step("test", "Run unit tests");
    const all_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(all_tests).step);
}

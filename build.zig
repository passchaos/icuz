const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("icuz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run icuz Unicode tests");
    test_step.dependOn(&run_tests.step);

    const python = b.option(
        []const u8,
        "python-exe",
        "Python 3 executable used by data verification",
    ) orelse "python3";
    const verify = b.addSystemCommand(&.{
        python,
        "tools/unicode/verify_committed.py",
    });
    const verify_step = b.step(
        "unicode-verify",
        "Verify committed Unicode blobs, generated sources, and generators",
    );
    verify_step.dependOn(&verify.step);

    const bench_icuz = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "icuz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "icuz", .module = bench_icuz },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run icuz microbenchmarks");
    bench_step.dependOn(&run_bench.step);
}

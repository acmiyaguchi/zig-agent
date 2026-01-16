const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module for the executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-agent",
        .root_module = root_module,
    });

    // --- Dependencies ---

    // 1. libxev (Zig module)
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev_mod = libxev_dep.module("xev");
    exe.root_module.addImport("xev", libxev_mod);

    // 2. termbox2 (C library)
    // We add C source files and include paths to the executable
    exe.addCSourceFile(.{
        .file = b.path("src/ui/termbox_impl.c"),
        .flags = &.{
            "-std=c99",
            "-D_XOPEN_SOURCE",
            "-D_DEFAULT_SOURCE",
        },
    });
    exe.addIncludePath(b.path("vendor/termbox2"));
    exe.linkLibC();

    // --- Install ---
    b.installArtifact(exe);

    // --- Run Step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Test Step ---
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_unit_tests = b.addTest(.{
        .name = "zig-agent-tests",
        .root_module = test_module,
    });

    // Add dependencies to tests
    exe_unit_tests.root_module.addImport("xev", libxev_mod);
    exe_unit_tests.addCSourceFile(.{
        .file = b.path("src/ui/termbox_impl.c"),
        .flags = &.{ "-std=c99", "-D_XOPEN_SOURCE", "-D_DEFAULT_SOURCE" },
    });
    exe_unit_tests.addIncludePath(b.path("vendor/termbox2"));
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // --- Standalone Tests ---
    const standalone_tests = [_][]const u8{
        "test_std.zig",
    };

    for (standalone_tests) |test_file| {
        const t = b.addTest(.{
            .name = test_file,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/{s}", .{test_file})),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}

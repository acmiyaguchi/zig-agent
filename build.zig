//! Build configuration for the Zig Agent project.
//!
//! Targets:
//! - zag: Main application executable.
//! - zag-tests: Unit tests for the main application.
//! - test-*: Harness executables for manual testing of specific components.
//!
//! Dependencies:
//! - libxev: Event loop.
//! - termbox2: Terminal UI library (C dependency).

const std = @import("std");

const CoreDeps = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libxev_mod: *std.Build.Module,
    lib_mod: *std.Build.Module,
    termbox_mod: *std.Build.Module,
    api_mod: *std.Build.Module,
    tools_mod: *std.Build.Module,
    agent_mod: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Modules ---

    // 1. API - core types and client
    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Tools - tool registry and implementations
    const tools_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_mod.addImport("api", api_mod);

    // 3. Agent - agent core logic
    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("api", api_mod);
    agent_mod.addImport("tools", tools_mod);

    // 4. Termbox (UI)
    const termbox_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/termbox.zig"),
        .target = target,
        .optimize = optimize,
    });
    termbox_mod.addCSourceFile(.{
        .file = b.path("src/ui/termbox_impl.c"),
        .flags = &.{ "-std=c99", "-D_XOPEN_SOURCE", "-D_DEFAULT_SOURCE" },
    });
    termbox_mod.addIncludePath(b.path("vendor/termbox2"));

    // 5. Shared Library Module (App)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("api", api_mod);
    lib_mod.addImport("tools", tools_mod);
    lib_mod.addImport("agent", agent_mod);
    lib_mod.addImport("termbox", termbox_mod);

    // --- Dependencies ---
    // libxev (Zig module)
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev_mod = libxev_dep.module("xev");

    const deps = CoreDeps{
        .target = target,
        .optimize = optimize,
        .libxev_mod = libxev_mod,
        .termbox_mod = termbox_mod,
        .lib_mod = lib_mod,
        .api_mod = api_mod,
        .tools_mod = tools_mod,
        .agent_mod = agent_mod,
    };

    addApp(b, deps);
    addUnitTests(b, deps);
    addHarness(b, deps);
}

fn addApp(b: *std.Build, deps: CoreDeps) void {
    // Create the root module for the executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zag",
        .root_module = root_module,
    });

    exe.root_module.addImport("xev", deps.libxev_mod);
    exe.root_module.addImport("termbox", deps.termbox_mod);
    exe.root_module.addImport("api", deps.api_mod);
    exe.root_module.addImport("tools", deps.tools_mod);
    exe.root_module.addImport("agent", deps.agent_mod);
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
}

fn addUnitTests(b: *std.Build, deps: CoreDeps) void {
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    const exe_unit_tests = b.addTest(.{
        .name = "zag-tests",
        .root_module = test_module,
    });

    exe_unit_tests.root_module.addImport("xev", deps.libxev_mod);
    exe_unit_tests.root_module.addImport("termbox", deps.termbox_mod);
    exe_unit_tests.root_module.addImport("api", deps.api_mod);
    exe_unit_tests.root_module.addImport("tools", deps.tools_mod);
    exe_unit_tests.root_module.addImport("agent", deps.agent_mod);
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn addHarness(b: *std.Build, deps: CoreDeps) void {
    const harness_tests = [_][]const u8{
        "stream",
        "agent",
        "tools",
        "ui",
    };

    for (harness_tests) |test_name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/harness/{s}.zig", .{test_name})),
            .target = deps.target,
            .optimize = deps.optimize,
        });
        test_mod.addImport("app", deps.lib_mod);

        const test_exe = b.addExecutable(.{
            .name = b.fmt("test-{s}", .{test_name}),
            .root_module = test_mod,
        });
        test_exe.root_module.addImport("xev", deps.libxev_mod);
        test_exe.root_module.addImport("termbox", deps.termbox_mod);
        test_exe.linkLibC();

        b.installArtifact(test_exe);

        // Add run step
        const run_cmd = b.addRunArtifact(test_exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(
            b.fmt("run-test-{s}", .{test_name}),
            b.fmt("Run the {s} harness", .{test_name}),
        );
        run_step.dependOn(&run_cmd.step);
    }
}

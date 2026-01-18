// Subprocess execution helper
const std = @import("std");
const registry = @import("registry.zig");
const posix = std.posix;

/// Maximum output size per stream (1MB)
const MAX_OUTPUT_SIZE: usize = 1024 * 1024;

/// Default timeout in seconds
const DEFAULT_TIMEOUT_SECS: u32 = 30;

/// Debug logging (writes to file)
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/zig-agent-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[subprocess] " ++ fmt ++ "\n", args) catch return;
    file.writeAll(msg) catch return;
}

/// Execute a shell command with timeout and output capture
pub fn execute(
    allocator: std.mem.Allocator,
    command: []const u8,
    timeout_secs: ?u32,
    working_dir: ?[]const u8,
) !registry.ToolResult {
    const timeout = timeout_secs orelse DEFAULT_TIMEOUT_SECS;

    debugLog("executing: {s}", .{command});

    // Spawn via /bin/sh -c
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, allocator);

    // Set working directory if provided
    if (working_dir) |dir| {
        child.cwd = dir;
    }

    // Capture stdout and stderr
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Spawn the process
    debugLog("spawning process...", .{});
    try child.spawn();
    debugLog("process spawned, pid={d}", .{child.id});

    // Get file descriptors for polling
    const stdout_fd = if (child.stdout) |f| f.handle else -1;
    const stderr_fd = if (child.stderr) |f| f.handle else -1;
    debugLog("stdout_fd={d}, stderr_fd={d}", .{ stdout_fd, stderr_fd });

    // Collect output with timeout
    var stdout_buffer = std.ArrayList(u8){};
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8){};
    defer stderr_buffer.deinit(allocator);

    const start_time = std.time.milliTimestamp();
    const timeout_ms: i64 = @as(i64, timeout) * 1000;

    var stdout_done = stdout_fd == -1;
    var stderr_done = stderr_fd == -1;

    debugLog("entering poll loop", .{});

    // Read loop with poll-based non-blocking I/O
    var loop_count: usize = 0;
    while (!stdout_done or !stderr_done) {
        loop_count += 1;
        if (loop_count % 10 == 1) {
            debugLog("poll loop iteration {d}, stdout_done={}, stderr_done={}", .{ loop_count, stdout_done, stderr_done });
        }

        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= timeout_ms) {
            // Kill the process on timeout
            _ = child.kill() catch {};
            _ = child.wait() catch {};

            return registry.ToolResult{
                .success = false,
                .output = try std.fmt.allocPrint(allocator, "Command timed out after {d} seconds", .{timeout}),
            };
        }

        // Set up poll fds
        var poll_fds: [2]posix.pollfd = undefined;
        var poll_count: usize = 0;

        if (!stdout_done) {
            poll_fds[poll_count] = .{
                .fd = stdout_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            poll_count += 1;
        }

        if (!stderr_done) {
            poll_fds[poll_count] = .{
                .fd = stderr_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            poll_count += 1;
        }

        if (poll_count == 0) break;

        // Poll with 100ms timeout
        const poll_result = posix.poll(poll_fds[0..poll_count], 100) catch |err| blk: {
            debugLog("poll error: {any}", .{err});
            break :blk 0;
        };

        if (poll_result > 0) {
            debugLog("poll returned {d} ready fds", .{poll_result});
            // Check which fds are ready
            for (poll_fds[0..poll_count]) |pfd| {
                if (pfd.revents & posix.POLL.IN != 0) {
                    // Data available to read
                    var buf: [4096]u8 = undefined;
                    const file = std.fs.File{ .handle = pfd.fd };
                    const n = file.read(&buf) catch 0;

                    if (n == 0) {
                        // EOF
                        if (pfd.fd == stdout_fd) stdout_done = true;
                        if (pfd.fd == stderr_fd) stderr_done = true;
                    } else {
                        if (pfd.fd == stdout_fd and stdout_buffer.items.len + n <= MAX_OUTPUT_SIZE) {
                            try stdout_buffer.appendSlice(allocator, buf[0..n]);
                        }
                        if (pfd.fd == stderr_fd and stderr_buffer.items.len + n <= MAX_OUTPUT_SIZE) {
                            try stderr_buffer.appendSlice(allocator, buf[0..n]);
                        }
                    }
                }

                if (pfd.revents & posix.POLL.HUP != 0 or pfd.revents & posix.POLL.ERR != 0) {
                    // Pipe closed or error
                    if (pfd.fd == stdout_fd) stdout_done = true;
                    if (pfd.fd == stderr_fd) stderr_done = true;
                }
            }
        }
    }

    debugLog("poll loop done after {d} iterations, waiting for process...", .{loop_count});

    // Wait for process to complete
    const term = try child.wait();
    debugLog("process exited", .{});

    // Combine stdout and stderr
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    if (stdout_buffer.items.len > 0) {
        try output.appendSlice(allocator, stdout_buffer.items);
    }

    if (stderr_buffer.items.len > 0) {
        if (output.items.len > 0) {
            try output.appendSlice(allocator, "\n--- stderr ---\n");
        }
        try output.appendSlice(allocator, stderr_buffer.items);
    }

    // Determine success based on exit code
    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };

    const exit_info = switch (term) {
        .Exited => |code| if (code != 0)
            try std.fmt.allocPrint(allocator, "\n[exit code: {d}]", .{code})
        else
            null,
        .Signal => |sig| try std.fmt.allocPrint(allocator, "\n[killed by signal: {d}]", .{sig}),
        .Stopped => |sig| try std.fmt.allocPrint(allocator, "\n[stopped by signal: {d}]", .{sig}),
        .Unknown => try allocator.dupe(u8, "\n[unknown termination]"),
    };

    if (exit_info) |info| {
        try output.appendSlice(allocator, info);
        allocator.free(info);
    }

    // If no output, provide a message
    if (output.items.len == 0) {
        try output.appendSlice(allocator, "(no output)");
    }

    return registry.ToolResult{
        .success = success,
        .output = try output.toOwnedSlice(allocator),
    };
}

test "subprocess execute echo" {
    const allocator = std.testing.allocator;

    const result = try execute(allocator, "echo 'hello world'", null, null);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello world") != null);
}

test "subprocess execute failing command" {
    const allocator = std.testing.allocator;

    const result = try execute(allocator, "exit 1", null, null);
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exit code: 1") != null);
}

test "subprocess execute with working directory" {
    const allocator = std.testing.allocator;

    const result = try execute(allocator, "pwd", null, "/tmp");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/tmp") != null);
}

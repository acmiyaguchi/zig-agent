// Generic subprocess execution helper
const std = @import("std");
const posix = std.posix; // Use std.os.linux or std.posix depending on zig version, assuming recent zig
// Note: In very recent Zig, std.os is deprecated in favor of std.posix or std.os.linux for specific things.
// The previous code used `std.posix`, so we stick with that.

const logging = @import("logging.zig");

/// Maximum output size per stream (1MB)
const max_output_size: usize = 1024 * 1024;

/// Default timeout in seconds
const default_timeout_secs: u32 = 30;

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    timed_out: bool,

    pub fn deinit(self: ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Execute a shell command with timeout and output capture
pub fn execute(
    allocator: std.mem.Allocator,
    command: []const u8,
    timeout_secs: ?u32,
    working_dir: ?[]const u8,
) !ExecResult {
    const timeout = timeout_secs orelse default_timeout_secs;

    logging.debugLog("executing: {s}", .{command});

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
    logging.debugLog("spawning process...", .{});
    try child.spawn();
    logging.debugLog("process spawned, pid={d}", .{child.id});

    const stdout_fd = if (child.stdout) |f| f.handle else -1;
    const stderr_fd = if (child.stderr) |f| f.handle else -1;

    var stdout_buffer = std.ArrayList(u8){};
    errdefer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8){};
    errdefer stderr_buffer.deinit(allocator);

    const start_time = std.time.milliTimestamp();
    const timeout_ms: i64 = @as(i64, timeout) * 1000;

    var stdout_done = stdout_fd == -1;
    var stderr_done = stderr_fd == -1;

    // Read loop
    while (!stdout_done or !stderr_done) {
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= timeout_ms) {
            _ = child.kill() catch |err| {
                logging.debugLog("Failed to kill timed-out process: {any}", .{err});
            };
            _ = child.wait() catch |err| {
                logging.debugLog("Failed to wait for killed process: {any}", .{err});
            };
            return ExecResult{
                .stdout = try stdout_buffer.toOwnedSlice(allocator),
                .stderr = try stderr_buffer.toOwnedSlice(allocator),
                .exit_code = 124, // Timeout exit code convention
                .timed_out = true,
            };
        }

        var poll_fds: [2]posix.pollfd = undefined;
        var poll_count: usize = 0;

        if (!stdout_done) {
            poll_fds[poll_count] = .{ .fd = stdout_fd, .events = posix.POLL.IN, .revents = 0 };
            poll_count += 1;
        }
        if (!stderr_done) {
            poll_fds[poll_count] = .{ .fd = stderr_fd, .events = posix.POLL.IN, .revents = 0 };
            poll_count += 1;
        }

        if (poll_count == 0) break;

        const poll_result = posix.poll(poll_fds[0..poll_count], 100) catch 0;

        if (poll_result > 0) {
            for (poll_fds[0..poll_count]) |pfd| {
                if (pfd.revents & posix.POLL.IN != 0) {
                    var buf: [4096]u8 = undefined;
                    const bytes_read = try (std.fs.File{ .handle = pfd.fd }).read(&buf);
                    if (bytes_read == 0) {
                        if (pfd.fd == stdout_fd) stdout_done = true;
                        if (pfd.fd == stderr_fd) stderr_done = true;
                    } else {
                        if (pfd.fd == stdout_fd and stdout_buffer.items.len + bytes_read <= max_output_size) {
                            try stdout_buffer.appendSlice(allocator, buf[0..bytes_read]);
                        }
                        if (pfd.fd == stderr_fd and stderr_buffer.items.len + bytes_read <= max_output_size) {
                            try stderr_buffer.appendSlice(allocator, buf[0..bytes_read]);
                        }
                    }
                }
                if (pfd.revents & posix.POLL.HUP != 0 or pfd.revents & posix.POLL.ERR != 0) {
                    if (pfd.fd == stdout_fd) stdout_done = true;
                    if (pfd.fd == stderr_fd) stderr_done = true;
                }
            }
        }
    }

    const term = try child.wait();
    const exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    return ExecResult{
        .stdout = try stdout_buffer.toOwnedSlice(allocator),
        .stderr = try stderr_buffer.toOwnedSlice(allocator),
        .exit_code = exit_code,
        .timed_out = false,
    };
}

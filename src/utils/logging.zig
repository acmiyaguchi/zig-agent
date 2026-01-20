// Shared logging utility
const std = @import("std");

/// Debug logging (writes to file)
pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/zig-agent-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;

    // Build message in memory first using bufPrint
    var msg_buf: [4096]u8 = undefined;
    const timestamp_str = std.fmt.bufPrint(&msg_buf, "[{d}] " ++ fmt ++ "\n", .{std.time.milliTimestamp()} ++ args) catch return;

    // Write to file using buffered writer interface
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(&write_buf).interface;
    writer.writeAll(timestamp_str) catch return;
}

test "debugLog writes to log file" {
    const log_path = "/tmp/zig-agent-debug.log";

    // Delete existing log to start fresh
    std.fs.cwd().deleteFile(log_path) catch {};

    // Write a unique test message
    debugLog("test_marker_{d}", .{12345});

    // Verify file exists and contains our message
    const file = try std.fs.cwd().openFile(log_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    const content = buf[0..bytes_read];

    // Verify the message was written (contains our marker)
    try std.testing.expect(std.mem.indexOf(u8, content, "test_marker_12345") != null);
}

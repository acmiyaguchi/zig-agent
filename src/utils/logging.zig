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

// Shared logging utility
const std = @import("std");

/// Debug logging (writes to file)
pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/zig-agent-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    writer.print("[{d}] ", .{std.time.milliTimestamp()}) catch return;
    writer.print(fmt ++ "\n", args) catch return;

    file.writeAll(fbs.getWritten()) catch return;
}

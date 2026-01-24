// System resource utilities
const std = @import("std");

/// Get current Resident Set Size (RSS) in bytes from /proc/self/statm
pub fn getCurrentRSS() ?usize {
    const statm_path = "/proc/self/statm";
    const file = std.fs.openFileAbsolute(statm_path, .{}) catch return null;
    defer file.close();

    // Read directly into a stack buffer - /proc/self/statm is small
    var buf: [256]u8 = undefined;
    const bytes_read = file.read(&buf) catch return null;
    const content = buf[0..bytes_read];

    var fields = std.mem.splitSequence(u8, content, " ");
    _ = fields.next(); // Skip first field (vsize)

    // Get RSS field (second field)
    if (fields.next()) |rss_str| {
        const rss_pages = std.fmt.parseUnsigned(usize, std.mem.trim(u8, rss_str, " \t\n\r"), 10) catch return null;
        // Standard page size on most Linux systems
        const page_size: usize = 4096;
        return rss_pages * page_size;
    }

    return null;
}

test "getCurrentRSS returns valid page-aligned value on linux" {
    const rss = getCurrentRSS();

    // Should return non-null on Linux (where /proc/self/statm exists)
    try std.testing.expect(rss != null);

    // RSS should be at least one page and page-aligned
    try std.testing.expect(rss.? >= 4096);
    try std.testing.expectEqual(@as(usize, 0), rss.? % 4096);
}

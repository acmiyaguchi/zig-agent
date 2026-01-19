// System resource utilities
const std = @import("std");

/// Get current Resident Set Size (RSS) in bytes from /proc/self/statm
pub fn getCurrentRSS(allocator: std.mem.Allocator) ?usize {
    const statm_path = "/proc/self/statm";
    const file = std.fs.openFileAbsolute(statm_path, .{}) catch return null;
    defer file.close();

    // zlinter-disable-next-line no_deprecated - File.readToEndAlloc is valid in Zig 0.15.x
    const content = file.readToEndAlloc(allocator, 1024) catch return null;
    defer allocator.free(content);

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

// Entry point
const std = @import("std");

pub fn main() !void {
    std.debug.print("Zig Agent v1 Skeleton\n", .{});
}

test {
    _ = @import("api/client.zig");
    _ = @import("api/types.zig");
    _ = @import("agent/agent.zig");
    _ = @import("agent/types.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/read_file.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/termbox.zig");
}

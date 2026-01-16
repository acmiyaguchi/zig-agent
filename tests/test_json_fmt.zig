const std = @import("std");

test "json fmt" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    const Msg = struct { x: i32 };
    const msg = Msg{ .x = 1 };
    
    try list.writer().print("{f}", .{std.json.fmt(msg, .{})});
    
    try std.testing.expectEqualStrings("{\"x\":1}", list.items);
}
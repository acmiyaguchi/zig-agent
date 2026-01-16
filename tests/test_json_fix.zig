const std = @import("std");

test "json fix" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    const msg = .{ .x = @as(i32, 1) };
    
    try list.writer().print("{f}", .{std.json.fmt(msg, .{})});
    
    try std.testing.expectEqualStrings("{\"x\":1}", list.items);
}

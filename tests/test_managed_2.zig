const std = @import("std");

test "array list managed" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    try list.append('a');
}

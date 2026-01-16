const std = @import("std");

test "array list unmanaged" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    try list.append(allocator, 'a');
}
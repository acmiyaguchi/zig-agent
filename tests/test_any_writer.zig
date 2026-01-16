const std = @import("std");

test "any writer" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    var w = list.writer();
    var any_w = w.any();
    
    try any_w.writeAll("hello");
}

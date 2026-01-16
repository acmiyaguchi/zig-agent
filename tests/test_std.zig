const std = @import("std");

test "std.array_list.Managed (managed list)" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    try list.append('a');
}

test "std.ArrayList (unmanaged list)" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    try list.append(allocator, 'a');
}

test "AnyWriter usage" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    var w = list.writer();
    var any_w = w.any();
    
    try any_w.writeAll("hello");
}

test "json fmt (anonymous struct)" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    const msg = .{ .x = @as(i32, 1) };
    
    try list.writer().print("{f}", .{std.json.fmt(msg, .{})});
    
    try std.testing.expectEqualStrings("{\"x\":1}", list.items);
}

test "json fmt (declared struct)" {
    const allocator = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    
    const Msg = struct { x: i32 };
    const msg = Msg{ .x = 1 };
    
    try list.writer().print("{f}", .{std.json.fmt(msg, .{})});
    
    try std.testing.expectEqualStrings("{\"x\":1}", list.items);
}

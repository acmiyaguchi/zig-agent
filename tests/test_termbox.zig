const std = @import("std");
const tb = @import("termbox");

pub fn main() !void {
    // Just verify we can call the functions (even if they fail at runtime)
    // In a real CI/headless env, tb_init might fail.
    
    std.debug.print("Attempting to init termbox...\n", .{});
    tb.init() catch |err| {
        std.debug.print("Termbox init failed (expected in headless): {}\n", .{err});
        return;
    };
    defer tb.shutdown();

    try tb.clear();
    try tb.print(0, 0, tb.TB_DEFAULT, tb.TB_DEFAULT, "Hello Termbox");
    try tb.present();

    // Don't poll event as it blocks
    // var ev: tb.TbEvent = undefined;
    // try tb.pollEvent(&ev);
    
    std.debug.print("Termbox test complete\n", .{});
}

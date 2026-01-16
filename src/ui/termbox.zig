// Termbox2 bindings
const std = @import("std");
const c = @cImport({
    @cInclude("termbox2.h");
});

pub fn tb_init() !void {
    const ret = c.tb_init();
    if (ret != 0) return error.InitializationFailed;
}

pub fn tb_shutdown() void {
    c.tb_shutdown();
}

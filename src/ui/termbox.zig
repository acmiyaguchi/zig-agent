// Termbox2 bindings
const std = @import("std");

pub const TbEvent = extern struct {
    type: u8,
    mod: u8,
    key: u16,
    ch: u32,
    w: i32,
    h: i32,
    x: i32,
    y: i32,
};

pub const TB_EVENT_KEY: u8 = 1;
pub const TB_EVENT_RESIZE: u8 = 2;
pub const TB_EVENT_MOUSE: u8 = 3;

pub const TB_KEY_CTRL_C: u16 = 0x03;
pub const TB_KEY_ENTER: u16 = 0x0d;
pub const TB_KEY_ESC: u16 = 0x1b;
pub const TB_KEY_BACKSPACE: u16 = 0x08;
pub const TB_KEY_BACKSPACE2: u16 = 0x7f;
pub const TB_KEY_ARROW_UP: u16 = 0xffff - 18;
pub const TB_KEY_ARROW_DOWN: u16 = 0xffff - 19;
pub const TB_KEY_ARROW_LEFT: u16 = 0xffff - 20;
pub const TB_KEY_ARROW_RIGHT: u16 = 0xffff - 21;

pub const TB_DEFAULT: u64 = 0;

// Function declarations from C
extern "c" fn tb_init() c_int;
extern "c" fn tb_shutdown() void;
extern "c" fn tb_width() c_int;
extern "c" fn tb_height() c_int;
extern "c" fn tb_clear() c_int;
extern "c" fn tb_present() c_int;
extern "c" fn tb_poll_event(ev: *TbEvent) c_int;
extern "c" fn tb_set_cell(x: c_int, y: c_int, ch: u32, fg: u64, bg: u64) c_int;
extern "c" fn tb_get_fds(ttyfd: *c_int, resizefd: *c_int) c_int;
extern "c" fn tb_peek_event(ev: *TbEvent, timeout_ms: c_int) c_int;

pub fn init() !void {
    const ret = tb_init();
    if (ret != 0) return error.InitializationFailed;
}

pub fn shutdown() void {
    tb_shutdown();
}

pub fn width() c_int {
    return tb_width();
}

pub fn height() c_int {
    return tb_height();
}

pub fn clear() !void {
    const ret = tb_clear();
    if (ret != 0) return error.ClearFailed;
}

pub fn present() !void {
    const ret = tb_present();
    if (ret != 0) return error.PresentFailed;
}

pub fn pollEvent(ev: *TbEvent) !void {
    const ret = tb_poll_event(ev);
    if (ret < 0) return error.PollEventFailed;
}

/// Get termbox file descriptors for external event loops
/// Returns tuple of (tty_fd, resize_fd)
pub fn getFds() ![2]std.posix.fd_t {
    var ttyfd: c_int = undefined;
    var resizefd: c_int = undefined;
    const ret = tb_get_fds(&ttyfd, &resizefd);
    if (ret != 0) return error.GetFdsFailed;
    return .{ @intCast(ttyfd), @intCast(resizefd) };
}

/// Non-blocking event peek with timeout
/// Returns true if event was available, false on timeout
pub fn peekEvent(ev: *TbEvent, timeout_ms: c_int) !bool {
    const ret = tb_peek_event(ev, timeout_ms);
    if (ret < 0) return error.PeekEventFailed;
    return ret == 0; // 0 = TB_OK = event available
}

pub fn setCell(x: c_int, y: c_int, ch: u32, fg: u64, bg: u64) !void {
    const ret = tb_set_cell(x, y, ch, fg, bg);
    if (ret != 0) return error.SetCellFailed;
}

pub fn print(x: c_int, y: c_int, fg: u64, bg: u64, text: []const u8) !void {
    var cx = x;
    for (text) |char| {
        try setCell(cx, y, char, fg, bg);
        cx += 1;
    }
}

test "termbox init and basic operations" {
    // Just verify we can call the functions (even if they fail at runtime)
    // In a real CI/headless env, tb_init might fail.
    
    std.debug.print("Attempting to init termbox...\n", .{});
    init() catch |err| {
        std.debug.print("Termbox init failed (expected in headless): {}\n", .{err});
        return;
    };
    defer shutdown();

    try clear();
    try print(0, 0, TB_DEFAULT, TB_DEFAULT, "Hello Termbox");
    try present();
    
    // Don't poll event as it blocks
}

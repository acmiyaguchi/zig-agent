pub const api = @import("api");
pub const agent = @import("agent");
pub const tools = @import("tools");

// zlinter-disable-next-line declaration_naming - short namespace identifier is conventional
pub const ui = struct {
    pub const terminal = @import("ui/terminal.zig");
    pub const termbox = @import("termbox");
};

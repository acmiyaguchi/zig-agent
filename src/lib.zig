pub const api = struct {
    pub const types = @import("api/types.zig");
    pub const client = @import("api/client.zig");
};

pub const agent = struct {
    pub const types = @import("agent/types.zig");
    pub const agent = @import("agent/agent.zig");
};

pub const tools = struct {
    pub const registry = @import("tools/registry.zig");
    pub const read_file = @import("tools/read_file.zig");
    pub const list_directory = @import("tools/list_directory.zig");
    pub const search_files = @import("tools/search_files.zig");
    pub const write_file = @import("tools/write_file.zig");
    pub const edit_file = @import("tools/edit_file.zig");
    pub const run_command = @import("tools/run_command.zig");
    pub const pkg = @import("tools/pkg.zig");
};

pub const ui = struct {
    pub const terminal = @import("ui/terminal.zig");
    pub const termbox = @import("ui/termbox.zig");
};

// Terminal UI
const std = @import("std");

pub const TerminalUI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TerminalUI {
        return TerminalUI{ .allocator = allocator };
    }

    pub fn run(self: *TerminalUI) !void {
        _ = self;
    }
};

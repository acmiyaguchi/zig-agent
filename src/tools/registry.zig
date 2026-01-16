// Tool Registry
const std = @import("std");

pub const Tool = struct {
    name: []const u8,
};

pub const ToolRegistry = struct {
    tools: std.ArrayList(Tool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return ToolRegistry{
            .tools = std.ArrayList(Tool).init(allocator),
            .allocator = allocator,
        };
    }
};

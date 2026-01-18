// Tool Registry
const std = @import("std");
const types = @import("../api/types.zig");

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    execute: *const fn (allocator: std.mem.Allocator, arguments: []const u8) anyerror!ToolResult,
    requires_confirmation: bool = false,
};

pub const ToolRegistry = struct {
    tools: std.ArrayList(Tool),
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return ToolRegistry{
            .tools = std.ArrayList(Tool){},
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.arena.deinit();
        self.tools.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.append(self.allocator, tool);
    }

    pub fn find(self: *ToolRegistry, name: []const u8) ?Tool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) {
                return tool;
            }
        }
        return null;
    }

    pub fn toApiDefinitions(self: *ToolRegistry, allocator: std.mem.Allocator) ![]types.ToolDefinition {
        const defs = try allocator.alloc(types.ToolDefinition, self.tools.items.len);
        for (self.tools.items, 0..) |tool, i| {
            defs[i] = .{
                .function = .{
                    .name = tool.name,
                    .description = tool.description,
                    .parameters = tool.parameters,
                },
            };
        }
        return defs;
    }
};

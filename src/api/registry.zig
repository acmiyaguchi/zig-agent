// Tool Registry
const std = @import("std");
const types = @import("types.zig");

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

fn dummyExecute(allocator: std.mem.Allocator, arguments: []const u8) anyerror!ToolResult {
    _ = arguments;
    return ToolResult{ .success = true, .output = try allocator.dupe(u8, "dummy output") };
}

test "ToolRegistry init and deinit" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
}

test "ToolRegistry register single tool" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tool = Tool{
        .name = "test_tool",
        .description = "A test tool",
        .parameters = .null,
        .execute = dummyExecute,
    };

    try registry.register(tool);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
}

test "ToolRegistry register multiple tools" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tools = [_]Tool{
        .{
            .name = "tool1",
            .description = "First tool",
            .parameters = .null,
            .execute = dummyExecute,
        },
        .{
            .name = "tool2",
            .description = "Second tool",
            .parameters = .null,
            .execute = dummyExecute,
        },
        .{
            .name = "tool3",
            .description = "Third tool",
            .parameters = .null,
            .execute = dummyExecute,
        },
    };

    for (tools) |tool| {
        try registry.register(tool);
    }

    try std.testing.expectEqual(@as(usize, 3), registry.tools.items.len);
    try std.testing.expectEqualStrings("tool1", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("tool2", registry.tools.items[1].name);
    try std.testing.expectEqualStrings("tool3", registry.tools.items[2].name);
}

test "ToolRegistry find existing tool" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tool = Tool{
        .name = "search_tool",
        .description = "A searchable tool",
        .parameters = .null,
        .execute = dummyExecute,
    };

    try registry.register(tool);

    const found = registry.find("search_tool");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("search_tool", found.?.name);
}

test "ToolRegistry find nonexistent tool returns null" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tool = Tool{
        .name = "existing_tool",
        .description = "An existing tool",
        .parameters = .null,
        .execute = dummyExecute,
    };

    try registry.register(tool);

    const found = registry.find("nonexistent_tool");
    try std.testing.expect(found == null);
}

test "ToolRegistry find in empty registry" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const found = registry.find("any_tool");
    try std.testing.expect(found == null);
}

test "ToolRegistry toApiDefinitions empty registry" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const defs = try registry.toApiDefinitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);

    try std.testing.expectEqual(@as(usize, 0), defs.len);
}

test "ToolRegistry toApiDefinitions converts all tools" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tools = [_]Tool{
        .{
            .name = "tool1",
            .description = "First tool",
            .parameters = .null,
            .execute = dummyExecute,
        },
        .{
            .name = "tool2",
            .description = "Second tool",
            .parameters = .null,
            .execute = dummyExecute,
        },
    };

    for (tools) |tool| {
        try registry.register(tool);
    }

    const defs = try registry.toApiDefinitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);

    try std.testing.expectEqual(@as(usize, 2), defs.len);
    try std.testing.expectEqualStrings("tool1", defs[0].function.name);
    try std.testing.expectEqualStrings("tool2", defs[1].function.name);
    try std.testing.expectEqualStrings("First tool", defs[0].function.description);
    try std.testing.expectEqualStrings("Second tool", defs[1].function.description);
}

test "ToolResult deinit frees output only" {
    const allocator = std.testing.allocator;
    var result = ToolResult{
        .success = true,
        .output = try allocator.dupe(u8, "test output"),
    };

    result.deinit(allocator);
    // If we get here without a crash or leak, the test passes
}

test "ToolResult deinit frees both output and error" {
    const allocator = std.testing.allocator;
    var result = ToolResult{
        .success = false,
        .output = try allocator.dupe(u8, "output text"),
        .error_message = try allocator.dupe(u8, "error text"),
    };

    result.deinit(allocator);
    // If we get here without a crash or leak, the test passes
}

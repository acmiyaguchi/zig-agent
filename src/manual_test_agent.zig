const std = @import("std");
const api_types = @import("api/types.zig");
const agent_types = @import("agent/types.zig");
const client = @import("api/client.zig");
const registry = @import("tools/registry.zig");
const read_file = @import("tools/read_file.zig");
const agent_lib = @import("agent/agent.zig");

fn eventHandler(update: agent_types.AgentUpdate, context: *anyopaque) void {
    _ = context;
    switch (update) {
        .thought => |t| std.debug.print("Thought: {s}\n", .{t}),
        .message_chunk => |c| std.debug.print("{s}", .{c}),
        .tool_call => |tc| std.debug.print("\nTool Call: {s}({s})\n", .{tc.name, tc.arguments}),
        .tool_result => |tr| std.debug.print("Tool Result: {s}\n", .{tr.output}),
        .completion => std.debug.print("\n[Completion]\n", .{}),
        .@"error" => |e| std.debug.print("Error: {s}\n", .{e}),
        .memory_warning => {},
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const api_key = env_map.get("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OPENROUTER_API_KEY environment variable not set.\n", .{});
        return;
    };

    var api_client = try client.APIClient.init(allocator, api_key, "anthropic/claude-3.5-sonnet");
    defer api_client.deinit();

    var tool_registry = registry.ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    const rf_tool = try read_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rf_tool);

    var dummy_ctx: i32 = 0;
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, eventHandler, &dummy_ctx);
    defer agent.deinit();

    // Simple test - create a tiny test file
    const test_file = "/tmp/zig-agent-test.txt";
    {
        const f = try std.fs.cwd().createFile(test_file, .{});
        defer f.close();
        try f.writeAll("Hello from test file!");
    }

    const prompt = try std.fmt.allocPrint(allocator, "Read {s} and tell me what it says.", .{test_file});
    defer allocator.free(prompt);
    
    std.debug.print("User: {s}\n", .{prompt});
    
    try agent.executeTurn(prompt);
}

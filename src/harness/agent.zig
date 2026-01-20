//! Manual test harness for the Agent.
//!
//! This test creates a simple agent instance and runs a basic "read file" task
//! to verify the agent's core loop, tool execution, and usage tracking.

const std = @import("std");
const app = @import("app");
const agent_types = app.agent.types;
const client = app.api.client;
const registry = app.api.registry;
const read_file = app.tools.read_file;
const agent_lib = app.agent.agent;

fn eventHandler(update: agent_types.AgentUpdate, context: *anyopaque) void {
    _ = context;
    switch (update) {
        .thought => |t| std.debug.print("Thought: {s}\n", .{t}),
        .message_chunk => |c| std.debug.print("{s}", .{c}),
        .tool_call => |tc| std.debug.print("\nTool Call: {s}({s})\n", .{ tc.name, tc.arguments }),
        .tool_result => |tr| std.debug.print("Tool Result: {s}\n", .{tr.output}),
        .completion => std.debug.print("\n[Completion]\n", .{}),
        .@"error" => |e| std.debug.print("Error: {s}\n", .{e}),
        .memory_warning => {},
        .usage_update => |u| std.debug.print("[Tokens: {d} in, {d} out]\n", .{ u.total_input_tokens, u.total_output_tokens }),
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const api_key = env_map.get("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OPENROUTER_API_KEY environment variable not set.\n", .{});
        return;
    };

    var api_client = try client.APIClient.init(allocator, api_key, "anthropic/claude-haiku-4.5");
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
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf).interface;
        try writer.writeAll("Hello from test file!");
    }

    const prompt = try std.fmt.allocPrint(allocator, "Read {s} and tell me what it says.", .{test_file});
    defer allocator.free(prompt);

    std.debug.print("User: {s}\n", .{prompt});

    try agent.executeTurn(prompt);
}

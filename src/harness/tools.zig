//! Test harness for all available tools ("kitchen sink" test).
//!
//! This harness registers all known tools and attempts to execute a task that
//! involves listing files, exercising the tool registry and execution logic.

const std = @import("std");
const app = @import("app");
const agent_types = app.agent.types;
const client = app.api.client;
const registry = app.api.registry;
const tools = app.tools;
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
    // zlinter-disable-next-line no_deprecated - GPA syntax is fine in 0.15.x
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    // Register ALL tools (same as zig-agent)
    inline for (.{
        tools.read_file,
        tools.list_directory,
        tools.search_files,
        tools.write_file,
        tools.edit_file,
        tools.run_command,
    }) |tool_mod| {
        try tool_registry.register(try tool_mod.initTool(tool_registry.arena.allocator()));
    }

    var dummy_ctx: i32 = 0;
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, eventHandler, &dummy_ctx);
    defer agent.deinit();

    std.debug.print("User: List files in /tmp\n", .{});

    try agent.executeTurn("List files in /tmp");
}

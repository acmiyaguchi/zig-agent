//! Test harness for all available tools ("kitchen sink" test).
//!
//! This harness registers all known tools and attempts to execute a task that
//! involves listing files, exercising the tool registry and execution logic.

const std = @import("std");
const app = @import("app");
const api_types = app.api.types;
const agent_types = app.agent.types;
const client = app.api.client;
const registry = app.api.registry;
const read_file = app.tools.read_file;
const list_directory = app.tools.list_directory;
const search_files = app.tools.search_files;
const write_file = app.tools.write_file;
const edit_file = app.tools.edit_file;
const run_command = app.tools.run_command;
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
    const rf_tool = try read_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rf_tool);

    const ld_tool = try list_directory.initTool(tool_registry.arena.allocator());
    try tool_registry.register(ld_tool);

    const sf_tool = try search_files.initTool(tool_registry.arena.allocator());
    try tool_registry.register(sf_tool);

    const wf_tool = try write_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(wf_tool);

    const ef_tool = try edit_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(ef_tool);

    const rc_tool = try run_command.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rc_tool);

    var dummy_ctx: i32 = 0;
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, eventHandler, &dummy_ctx);
    defer agent.deinit();

    std.debug.print("User: List files in /tmp\n", .{});

    try agent.executeTurn("List files in /tmp");
}

// Test agent with all tools but no UI
const std = @import("std");
const api_types = @import("api/types.zig");
const agent_types = @import("agent/types.zig");
const client = @import("api/client.zig");
const registry = @import("tools/registry.zig");
const read_file = @import("tools/read_file.zig");
const list_directory = @import("tools/list_directory.zig");
const search_files = @import("tools/search_files.zig");
const write_file = @import("tools/write_file.zig");
const edit_file = @import("tools/edit_file.zig");
const run_command = @import("tools/run_command.zig");
const agent_lib = @import("agent/agent.zig");

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

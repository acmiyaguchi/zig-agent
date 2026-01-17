const std = @import("std");
const types = @import("api/types.zig");
const client = @import("api/client.zig");

fn streamCallback(chunk: types.StreamChunk, context: *anyopaque) void {
    _ = context;
    switch (chunk) {
        .content => |text| {
            std.debug.print("{s}", .{text});
        },
        .tool_call_start => |tc| {
            std.debug.print("\n[Tool Call Start: {s} (ID: {s})]\n", .{tc.name, tc.id});
        },
        .tool_call_delta => |tc| {
            std.debug.print("{s}", .{tc.arguments});
        },
        .finish => |reason| {
            if (reason) |r| {
                std.debug.print("\n[Finish: {s}]\n", .{r});
            } else {
                std.debug.print("\n[Finish]\n", .{});
            }
        },
        .usage => |u| {
            std.debug.print("\n[Usage: {d} prompt, {d} completion]\n", .{u.prompt_tokens, u.completion_tokens});
        },
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

    // Setup tools
    const registry = @import("tools/registry.zig");
    const read_file = @import("tools/read_file.zig");
    var tool_registry = registry.ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    const rf_tool = try read_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rf_tool);

    const api_tools = try tool_registry.toApiDefinitions(allocator);
    defer allocator.free(api_tools);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const agents_md_path = try std.fs.path.join(allocator, &.{ cwd, "AGENTS.md" });
    defer allocator.free(agents_md_path);

    const prompt = try std.fmt.allocPrint(allocator, "What are the core principles defined in the file {s}?", .{agents_md_path});
    defer allocator.free(prompt);

    const messages = [_]types.Message{
        .{ .role = .user, .content = prompt },
    };

    std.debug.print("Sending request with tools (asking about {s})...\n", .{agents_md_path});
    
    // We pass a dummy context since our callback doesn't use it
    var dummy: i32 = 0;
    try api_client.streamChatCompletion(&messages, api_tools, streamCallback, &dummy);
    
    std.debug.print("\nDone.\n", .{});
}

// Entry point - Headless REPL mode
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
        .thought => |t| std.debug.print("{s}\n", .{t}),
        .message_chunk => |c| std.debug.print("{s}", .{c}),
        .tool_call => |tc| std.debug.print("\n[Tool: {s}]\n", .{tc.name}),
        .tool_result => |tr| {
            const output = tr.output;
            if (output.len > 100) {
                std.debug.print("[Result: {s}...]\n", .{output[0..100]});
            } else {
                std.debug.print("[Result: {s}]\n", .{output});
            }
        },
        .completion => std.debug.print("\n", .{}),
        .@"error" => |e| std.debug.print("Error: {s}\n", .{e}),
        .memory_warning => std.debug.print("Warning: High memory usage\n", .{}),
    }
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get environment variables
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Read OPENROUTER_API_KEY from environment
    const api_key = env_map.get("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OPENROUTER_API_KEY environment variable not set.\n", .{});
        std.process.exit(1);
    };

    // Initialize API client
    var api_client = try client.APIClient.init(allocator, api_key, "anthropic/claude-3.5-sonnet");
    defer api_client.deinit();

    // Initialize tool registry
    var tool_registry = registry.ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    // Register read_file tool
    const rf_tool = try read_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rf_tool);

    // Initialize agent
    var dummy_ctx: i32 = 0;
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, eventHandler, &dummy_ctx);
    defer agent.deinit();

    // REPL loop
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdout_file = std.fs.File{ .handle = stdout_fd };

    var line_buffer: [4096]u8 = undefined;

    while (true) {
        // Print prompt
        try stdout_file.writeAll("> ");

        // Read line from stdin using getline alternative
        // Using std.debug.getStdIn() equivalent via posix syscall
        const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, &line_buffer);

        if (bytes_read == 0) {
            break;
        }

        // Trim whitespace (including newline)
        const line = std.mem.trim(u8, line_buffer[0..bytes_read], " \t\r\n");

        // Check for exit commands
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) {
            break;
        }

        // Skip empty lines
        if (line.len == 0) {
            continue;
        }

        // Execute agent turn
        agent.executeTurn(line) catch |err| {
            std.debug.print("Error: {any}\n", .{err});
        };
    }
}

test {
    _ = @import("api/client.zig");
    _ = @import("api/types.zig");
    _ = @import("agent/agent.zig");
    _ = @import("agent/types.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/read_file.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/termbox.zig");
}

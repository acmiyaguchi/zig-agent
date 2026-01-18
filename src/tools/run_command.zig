// run_command tool
const std = @import("std");
const registry = @import("api").registry;
const utils = @import("utils");

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "command": {
        \\      "type": "string",
        \\      "description": "The shell command to execute."
        \\    },
        \\    "timeout": {
        \\      "type": "integer",
        \\      "description": "Timeout in seconds (default: 30, max: 300)."
        \\    },
        \\    "working_dir": {
        \\      "type": "string",
        \\      "description": "The working directory for the command (must be absolute)."
        \\    }
        \\  },
        \\  "required": ["command"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});

    return registry.Tool{
        .name = "run_command",
        .description = "Execute a shell command. Use for commands that don't fit other tools.",
        .parameters = parsed.value,
        .execute = executeRunCommand,
        .requires_confirmation = true,
    };
}

fn executeRunCommand(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        command: []const u8,
        timeout: ?u32 = null,
        working_dir: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const command = parsed.value.command;
    var timeout = parsed.value.timeout orelse 30;
    const working_dir = parsed.value.working_dir;

    // Cap timeout at 5 minutes
    if (timeout > 300) {
        timeout = 300;
    }

    // Validate working_dir if provided
    if (working_dir) |dir| {
        if (!std.fs.path.isAbsolute(dir)) {
            return registry.ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "Error: working_dir must be absolute."),
            };
        }
    }

    const result = try utils.subprocess.execute(allocator, command, timeout, working_dir);
    defer result.deinit(allocator);

    // Combine stdout and stderr for the tool output
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    if (result.stdout.len > 0) {
        try output.appendSlice(allocator, result.stdout);
    }

    if (result.stderr.len > 0) {
        if (output.items.len > 0) {
            try output.appendSlice(allocator, "\n--- stderr ---\n");
        }
        try output.appendSlice(allocator, result.stderr);
    }

    if (result.timed_out) {
        try output.appendSlice(allocator, "\n[timed out]");
    } else if (result.exit_code != 0) {
        const exit_msg = try std.fmt.allocPrint(allocator, "\n[exit code: {d}]", .{result.exit_code});
        defer allocator.free(exit_msg);
        try output.appendSlice(allocator, exit_msg);
    }

    if (output.items.len == 0) {
        try output.appendSlice(allocator, "(no output)");
    }

    return registry.ToolResult{
        .success = result.exit_code == 0 and !result.timed_out,
        .output = try output.toOwnedSlice(allocator),
    };
}

test "run_command basic" {
    const allocator = std.testing.allocator;

    const result = try executeRunCommand(allocator, "{\"command\": \"echo 'test'\"}");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "test") != null);
}

test "run_command working_dir must be absolute" {
    const allocator = std.testing.allocator;

    const result = try executeRunCommand(allocator, "{\"command\": \"pwd\", \"working_dir\": \"relative/path\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: working_dir must be absolute.", result.output);
}

// list_directory tool
const std = @import("std");
const registry = @import("api").registry;
const utils = @import("utils");

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "The absolute path to the directory to list."
        \\    },
        \\    "recursive": {
        \\      "type": "boolean",
        \\      "description": "If true, list contents recursively."
        \\    }
        \\  },
        \\  "required": ["path"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});

    return registry.Tool{
        .name = "list_directory",
        .description = "List the contents of a directory. The path must be absolute.",
        .parameters = parsed.value,
        .execute = executeListDirectory,
        .requires_confirmation = false,
    };
}

fn executeListDirectory(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        path: []const u8,
        recursive: bool = false,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const path = parsed.value.path;
    const recursive = parsed.value.recursive;

    if (!std.fs.path.isAbsolute(path)) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: Path must be absolute."),
        };
    }

    // Build ls command
    const flags = if (recursive) "-laR" else "-la";
    const command = try std.fmt.allocPrint(allocator, "ls {s} {s}", .{ flags, path });
    defer allocator.free(command);

    const result = try utils.subprocess.execute(allocator, command, 30, null);
    defer result.deinit(allocator);

    if (result.timed_out) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Listing timed out."),
        };
    }

    if (result.exit_code == 0) {
        return registry.ToolResult{
            .success = true,
            .output = try allocator.dupe(u8, result.stdout),
        };
    } else {
        var msg = std.ArrayList(u8){};
        errdefer msg.deinit(allocator);
        try msg.appendSlice(allocator, "ls error: ");
        try msg.appendSlice(allocator, result.stderr);
        return registry.ToolResult{
            .success = false, // Conventionally failed if ls fails
            .output = try msg.toOwnedSlice(allocator),
        };
    }
}

test "list_directory absolute path check" {
    const allocator = std.testing.allocator;

    const result = try executeListDirectory(allocator, "{\"path\": \"relative/path\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: Path must be absolute.", result.output);
}

test "list_directory success" {
    const allocator = std.testing.allocator;

    const result = try executeListDirectory(allocator, "{\"path\": \"/tmp\"}");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // ls -la output should contain "total" line
    try std.testing.expect(std.mem.indexOf(u8, result.output, "total") != null);
}

test "list_directory recursive" {
    const allocator = std.testing.allocator;

    // Create a temp directory structure
    std.fs.makeDirAbsolute("/tmp/zig_agent_list_test") catch {};
    std.fs.makeDirAbsolute("/tmp/zig_agent_list_test/subdir") catch {};
    defer {
        std.fs.deleteTreeAbsolute("/tmp/zig_agent_list_test") catch {};
    }

    const result = try executeListDirectory(allocator, "{\"path\": \"/tmp/zig_agent_list_test\", \"recursive\": true}");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // Recursive output should mention subdir
    try std.testing.expect(std.mem.indexOf(u8, result.output, "subdir") != null);
}

test "list_directory nonexistent path fails" {
    const allocator = std.testing.allocator;

    const result = try executeListDirectory(allocator, "{\"path\": \"/nonexistent_path_that_does_not_exist_12345\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
}

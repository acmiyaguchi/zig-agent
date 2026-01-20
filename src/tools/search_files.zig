// search_files tool
const std = @import("std");
const registry = @import("api").registry;
const utils = @import("utils");

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "pattern": {
        \\      "type": "string",
        \\      "description": "The search pattern (grep regex)."
        \\    },
        \\    "path": {
        \\      "type": "string",
        \\      "description": "The absolute path to search in."
        \\    }
        \\  },
        \\  "required": ["pattern", "path"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});

    return registry.Tool{
        .name = "search_files",
        .description = "Search for a pattern in files recursively. The path must be absolute.",
        .parameters = parsed.value,
        .execute = executeSearchFiles,
        .requires_confirmation = false,
    };
}

fn executeSearchFiles(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        pattern: []const u8,
        path: []const u8,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const pattern = parsed.value.pattern;
    const path = parsed.value.path;

    if (!std.fs.path.isAbsolute(path)) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: Path must be absolute."),
        };
    }

    // Escape single quotes in pattern for shell safety
    var escaped_pattern = std.ArrayList(u8){};
    defer escaped_pattern.deinit(allocator);

    for (pattern) |c| {
        if (c == '\'') {
            try escaped_pattern.appendSlice(allocator, "'\"'\"'");
        } else {
            try escaped_pattern.append(allocator, c);
        }
    }

    // Build grep command
    const command = try std.fmt.allocPrint(allocator, "grep -rn '{s}' {s}", .{ escaped_pattern.items, path });
    defer allocator.free(command);

    const result = try utils.subprocess.execute(allocator, command, 60, null);
    defer result.deinit(allocator);

    if (result.timed_out) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Search timed out."),
        };
    }

    if (result.exit_code == 0) {
        // Match found
        return registry.ToolResult{
            .success = true,
            .output = try allocator.dupe(u8, result.stdout),
        };
    } else if (result.exit_code == 1) {
        // No match found (grep specific)
        return registry.ToolResult{
            .success = false, // Or true with empty output? Convention usually is fail if not found or empty
            .output = try allocator.dupe(u8, "No matches found."),
        };
    } else {
        // Error
        var msg = std.ArrayList(u8){};
        errdefer msg.deinit(allocator);
        try msg.appendSlice(allocator, "grep error: ");
        try msg.appendSlice(allocator, result.stderr);
        return registry.ToolResult{
            .success = false,
            .output = try msg.toOwnedSlice(allocator),
        };
    }
}

test "search_files absolute path check" {
    const allocator = std.testing.allocator;

    const result = try executeSearchFiles(allocator, "{\"pattern\": \"test\", \"path\": \"relative/path\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: Path must be absolute.", result.output);
}

test "search_files success" {
    const allocator = std.testing.allocator;

    // Create a temp file with known content
    const tmp_dir = "/tmp/zig_agent_search_test";
    const tmp_file = "/tmp/zig_agent_search_test/test.txt";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    {
        const file = try std.fs.createFileAbsolute(tmp_file, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf).interface;
        try writer.writeAll("hello world\nfoo bar\nhello again\n");
    }

    const args = try std.fmt.allocPrint(allocator, "{{\"pattern\": \"hello\", \"path\": \"{s}\"}}", .{tmp_dir});
    defer allocator.free(args);

    const result = try executeSearchFiles(allocator, args);
    defer result.deinit(allocator);

    // grep returns exit code 0 when matches found
    try std.testing.expect(result.success);
    // Output should contain the matched lines with line numbers
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

test "search_files no match" {
    const allocator = std.testing.allocator;

    // Create a temp file with known content
    const tmp_dir = "/tmp/zig_agent_search_test2";
    const tmp_file = "/tmp/zig_agent_search_test2/test.txt";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    {
        const file = try std.fs.createFileAbsolute(tmp_file, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf).interface;
        try writer.writeAll("hello world\n");
    }

    const args = try std.fmt.allocPrint(allocator, "{{\"pattern\": \"nonexistent_pattern_xyz\", \"path\": \"{s}\"}}", .{tmp_dir});
    defer allocator.free(args);

    const result = try executeSearchFiles(allocator, args);
    defer result.deinit(allocator);

    // grep returns exit code 1 when no matches found
    try std.testing.expect(!result.success);
}

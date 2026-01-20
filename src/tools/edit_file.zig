// edit_file tool
const std = @import("std");
const registry = @import("api").registry;

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "The absolute path to the file to edit."
        \\    },
        \\    "old_text": {
        \\      "type": "string",
        \\      "description": "The exact text to find and replace."
        \\    },
        \\    "new_text": {
        \\      "type": "string",
        \\      "description": "The text to replace old_text with."
        \\    }
        \\  },
        \\  "required": ["path", "old_text", "new_text"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});

    return registry.Tool{
        .name = "edit_file",
        .description = "Edit a file by replacing old_text with new_text. The path must be absolute. The old_text must exist exactly once in the file.",
        .parameters = parsed.value,
        .execute = executeEditFile,
        .requires_confirmation = true,
    };
}

fn executeEditFile(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const path = parsed.value.path;
    const old_text = parsed.value.old_text;
    const new_text = parsed.value.new_text;

    if (!std.fs.path.isAbsolute(path)) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: Path must be absolute."),
        };
    }

    // Read existing file content
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err}),
        };
    };

    const file_size = file.getEndPos() catch |err| {
        file.close();
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error getting file size: {any}", .{err}),
        };
    };

    if (file_size > 10 * 1024 * 1024) { // 10MB limit for edit
        file.close();
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: File too large (max 10MB for edit)."),
        };
    }

    const content = allocator.alloc(u8, file_size) catch |err| {
        file.close();
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error allocating buffer: {any}", .{err}),
        };
    };
    defer allocator.free(content);

    _ = file.readAll(content) catch |err| {
        file.close();
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error reading file: {any}", .{err}),
        };
    };
    file.close();

    // Count occurrences of old_text
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, content[pos..], old_text)) |idx| {
        count += 1;
        pos += idx + old_text.len;
    }

    if (count == 0) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: old_text not found in file."),
        };
    }

    if (count > 1) {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error: old_text found {d} times. Must be unique.", .{count}),
        };
    }

    // Perform replacement
    const idx = std.mem.indexOf(u8, content, old_text).?;
    const new_content = try std.mem.concat(allocator, u8, &.{
        content[0..idx],
        new_text,
        content[idx + old_text.len ..],
    });
    defer allocator.free(new_content);

    // Write back
    const out_file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error creating file for write: {any}", .{err}),
        };
    };
    defer out_file.close();

    out_file.writeAll(new_content) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error writing file: {any}", .{err}),
        };
    };

    return registry.ToolResult{
        .success = true,
        .output = try std.fmt.allocPrint(allocator, "Successfully edited {s}", .{path}),
    };
}

test "edit_file absolute path check" {
    const allocator = std.testing.allocator;

    const result = try executeEditFile(allocator, "{\"path\": \"relative/path.txt\", \"old_text\": \"a\", \"new_text\": \"b\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: Path must be absolute.", result.output);
}

test "edit_file success" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zig_agent_edit_test.txt";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Create initial file
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"world\", \"new_text\": \"zig\"}}", .{tmp_path});
    defer allocator.free(args);

    const result = try executeEditFile(allocator, args);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);

    // Verify file contents
    const file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readAll(content);
    try std.testing.expectEqualStrings("hello zig", content);
}

test "edit_file not found" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zig_agent_edit_test2.txt";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Create file with content that doesn't match
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"old_text\": \"foo\", \"new_text\": \"bar\"}}", .{tmp_path});
    defer allocator.free(args);

    const result = try executeEditFile(allocator, args);
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: old_text not found in file.", result.output);
}

// write_file tool
const std = @import("std");
const registry = @import("api").registry;

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "The absolute path to the file to write."
        \\    },
        \\    "content": {
        \\      "type": "string",
        \\      "description": "The content to write to the file."
        \\    }
        \\  },
        \\  "required": ["path", "content"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});

    return registry.Tool{
        .name = "write_file",
        .description = "Write content to a file. The path must be absolute. This will overwrite existing files.",
        .parameters = parsed.value,
        .execute = executeWriteFile,
        .requires_confirmation = true,
    };
}

fn executeWriteFile(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const path = parsed.value.path;
    const content = parsed.value.content;

    if (!std.fs.path.isAbsolute(path)) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: Path must be absolute."),
        };
    }

    // Write file using Zig's fs (more efficient than subprocess for file writes)
    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error creating file: {any}", .{err}),
        };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error writing file: {any}", .{err}),
        };
    };

    return registry.ToolResult{
        .success = true,
        .output = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, path }),
    };
}

test "write_file absolute path check" {
    const allocator = std.testing.allocator;

    const result = try executeWriteFile(allocator, "{\"path\": \"relative/path.txt\", \"content\": \"test\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: Path must be absolute.", result.output);
}

test "write_file success" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zig_agent_write_test.txt";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\", \"content\": \"hello world\"}}", .{tmp_path});
    defer allocator.free(args);

    const result = try executeWriteFile(allocator, args);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);

    // Verify file contents
    const file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

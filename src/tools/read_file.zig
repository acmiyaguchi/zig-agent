// read_file tool
const std = @import("std");
const registry = @import("api").registry;

pub const read_file_tool = registry.Tool{
    .name = "read_file",
    .description = "Read the contents of a file from the filesystem. The path must be absolute.",
    .parameters = undefined, // To be initialized
    .execute = executeReadFile,
};

pub fn initTool(allocator: std.mem.Allocator) !registry.Tool {
    var tool = read_file_tool;

    // Define parameters schema
    const parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "The absolute path to the file to read."
        \\    }
        \\  },
        \\  "required": ["path"]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{});
    // Note: We need to manage the lifecycle of this parsed value.
    // In a real app, the registry or tool would own this.
    tool.parameters = parsed.value;
    return tool;
}

pub fn executeReadFile(allocator: std.mem.Allocator, arguments_json: []const u8) anyerror!registry.ToolResult {
    const Args = struct {
        path: []const u8,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Failed to parse arguments: {any}", .{err}),
        };
    };
    defer parsed.deinit();

    const path = parsed.value.path;

    if (!std.fs.path.isAbsolute(path)) {
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: Path must be absolute."),
        };
    }

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return registry.ToolResult{
            .success = false,
            .output = try std.fmt.allocPrint(allocator, "Error opening file: {any}", .{err}),
        };
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 1024 * 1024) { // 1MB limit
        return registry.ToolResult{
            .success = false,
            .output = try allocator.dupe(u8, "Error: File too large (max 1MB)."),
        };
    }

    // zlinter-disable-next-line no_deprecated - File.readToEndAlloc is valid in Zig 0.15.x
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);

    return registry.ToolResult{
        .success = true,
        .output = content,
    };
}

test "read_file tool - absolute path check" {
    const allocator = std.testing.allocator;

    const result = try executeReadFile(allocator, "{\"path\": \"relative/path.txt\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Error: Path must be absolute.", result.output);
}

test "read_file tool - success" {
    const allocator = std.testing.allocator;

    const tmp_path = "/tmp/zig_agent_test.txt";
    const content = "Hello, Zig Agent!";
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = content });
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const args = try std.fmt.allocPrint(allocator, "{{\"path\": \"{s}\"}}", .{tmp_path});
    defer allocator.free(args);

    const result = try executeReadFile(allocator, args);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(content, result.output);
}

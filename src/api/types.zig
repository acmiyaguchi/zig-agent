const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(self: Role) []const u8 {
        return @tagName(self);
    }
};

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ToolDefinition = struct {
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
    },
};

pub const StreamOptions = struct {
    include_usage: bool = true,
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: ?[]const ToolDefinition = null,
    stream: bool = true,
    stream_options: ?StreamOptions = .{ .include_usage = true },
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const UsageInfo = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

pub const ChatCompletionChunk = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const struct {
        index: usize,
        delta: struct {
            role: ?Role = null,
            content: ?[]const u8 = null,
            tool_calls: ?[]const struct {
                index: usize,
                id: ?[]const u8 = null,
                type: ?[]const u8 = null,
                function: ?struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                } = null,
            } = null,
        },
        finish_reason: ?[]const u8 = null,
    },
    usage: ?UsageInfo = null,
};

pub const StreamChunk = union(enum) {
    content: []const u8,
    tool_call_start: struct {
        index: usize,
        id: []const u8,
        name: []const u8,
    },
    tool_call_delta: struct {
        index: usize,
        arguments: []const u8,
    },
    finish: ?[]const u8,
    usage: struct {
        prompt_tokens: u32,
        completion_tokens: u32,
    },
};

test "message serialization" {
    const allocator = std.testing.allocator;
    const msg = Message{
        .role = .user,
        .content = "Hello",
    };

    const out = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg, .{ .emit_null_optional_fields = false })});
    defer allocator.free(out);

    try std.testing.expectEqualStrings("{\"role\":\"user\",\"content\":\"Hello\"}", out);
}

test "request serialization" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = .user, .content = "Hi" },
    };
    const req = ChatCompletionRequest{
        .model = "test-model",
        .messages = &messages,
        .stream = true,
    };

    const out = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(req, .{ .emit_null_optional_fields = false })});
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stream\":true") != null);
}
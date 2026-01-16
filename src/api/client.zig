const std = @import("std");
const types = @import("types.zig");

pub const SSEEvent = union(enum) {
    json: []const u8,
    done,
};

pub const SSEParser = struct {
    buffer: std.array_list.Managed(u8),
    consumed: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .buffer = std.array_list.Managed(u8).init(allocator),
            .consumed = 0,
        };
    }

    pub fn deinit(self: *SSEParser) void {
        self.buffer.deinit();
    }

    pub fn push(self: *SSEParser, chunk: []const u8) !void {
        try self.buffer.appendSlice(chunk);
    }

    pub fn next(self: *SSEParser) !?SSEEvent {
        // Remove previously consumed data
        if (self.consumed > 0) {
            try self.buffer.replaceRange(0, self.consumed, &.{});
            self.consumed = 0;
        }

        while (true) {
            const items = self.buffer.items;
            const newline_idx = std.mem.indexOfScalar(u8, items, '\n') orelse return null;

            // Extract line excluding newline
            var line = items[0..newline_idx];
            // Handle \r\n
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            var processed_event: ?SSEEvent = null;

            if (line.len > 0) {
                if (std.mem.startsWith(u8, line, "data: ")) {
                    const data = line[6..];
                    if (std.mem.eql(u8, data, "[DONE]")) {
                        processed_event = .done;
                    } else {
                        processed_event = .{ .json = data };
                    }
                }
            }

            // Mark this line (including newline) as consumed
            self.consumed = newline_idx + 1;

            if (processed_event) |ev| {
                return ev;
            }

            // If line was ignored (comment or empty), remove it now and continue
            try self.buffer.replaceRange(0, self.consumed, &.{});
            self.consumed = 0;
        }
    }
};

pub const APIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    client: std.http.Client,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, model: ?[]const u8) !APIClient {
        if (api_key.len == 0) return error.MissingAPIKey;

        return APIClient{
            .allocator = allocator,
            .api_key = api_key,
            .client = std.http.Client{ .allocator = allocator },
            .model = model orelse "anthropic/claude-3.5-sonnet",
        };
    }

    pub fn deinit(self: *APIClient) void {
        self.client.deinit();
    }

    pub fn buildRequest(self: *APIClient, messages: []const types.Message, tools: []const types.ToolDefinition) ![]u8 {
        const req = types.ChatCompletionRequest{
            .model = self.model,
            .messages = messages,
            .tools = if (tools.len > 0) tools else null,
            .stream = true,
        };

        var json_buffer = std.array_list.Managed(u8).init(self.allocator);
        errdefer json_buffer.deinit();

        try json_buffer.writer().print("{f}", .{std.json.fmt(req, .{ .emit_null_optional_fields = false })});
        return json_buffer.toOwnedSlice();
    }

    pub fn streamChatCompletion(
        self: *APIClient,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        callback: *const fn (types.StreamChunk, *anyopaque) void,
        context: *anyopaque,
    ) !void {
        const payload = try self.buildRequest(messages, tools);
        defer self.allocator.free(payload);

        const url_str = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url_str);
        const parsed_uri = try std.Uri.parse(url_str);

        var server_header_buffer: [4096]u8 = undefined;
        var req = try self.client.open(.POST, parsed_uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);
        
        try req.headers.append("Authorization", auth_header);
        try req.headers.append("Content-Type", "application/json");
        try req.headers.append("HTTP-Referer", "https://github.com/anthony/zig-agent");
        try req.headers.append("X-Title", "Zig Agent");

        try req.send();
        try req.writeAll(payload);
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return error.APIError;
        }

        var parser = SSEParser.init(self.allocator);
        defer parser.deinit();

        var read_buf: [16384]u8 = undefined;
        var reader = req.reader();

        while (true) {
            const n = try reader.read(&read_buf);
            if (n == 0) break;

            try parser.push(read_buf[0..n]);
            while (try parser.next()) |ev| {
                switch (ev) {
                    .done => return,
                    .json => |json| {
                        const parsed = std.json.parseFromSlice(types.ChatCompletionChunk, self.allocator, json, .{
                            .ignore_unknown_fields = true,
                        }) catch |err| {
                            std.debug.print("JSON parse error: {any} for json: {s}\n", .{err, json});
                            continue;
                        };
                        defer parsed.deinit();

                        if (parsed.value.choices.len > 0) {
                            const choice = parsed.value.choices[0];
                            if (choice.delta.content) |content| {
                                callback(.{ .content = content }, context);
                            }
                            if (choice.delta.tool_calls) |tool_calls| {
                                for (tool_calls) |tc| {
                                    if (tc.id) |id| {
                                        callback(.{ .tool_call_start = .{
                                            .index = tc.index,
                                            .id = id,
                                            .name = tc.function.?.name.?,
                                        } }, context);
                                    }
                                    if (tc.function) |f| {
                                        if (f.arguments) |args| {
                                            callback(.{ .tool_call_delta = .{
                                                .index = tc.index,
                                                .arguments = args,
                                            } }, context);
                                        }
                                    }
                                }
                            }
                            if (choice.finish_reason) |reason| {
                                callback(.{ .finish = reason }, context);
                            }
                        }
                    },
                }
            }
        }
    }
};

test "sse parser" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("data: {\"foo\":\"bar\"}\n\n");

    const ev1 = (try parser.next()).?;
    try std.testing.expectEqualStrings("{\"foo\":\"bar\"}", ev1.json);

    try parser.push("data: [DONE]\n");
    const ev2 = (try parser.next()).?;
    try std.testing.expect(ev2 == .done);
}

test "build request" {
    const allocator = std.testing.allocator;
    var client = try APIClient.init(allocator, "test-key", null);
    defer client.deinit();

    const messages = [_]types.Message{
        .{ .role = .user, .content = "Hello" },
    };

    const req_json = try client.buildRequest(&messages, &.{});
    defer allocator.free(req_json);

    try std.testing.expect(std.mem.indexOf(u8, req_json, "anthropic/claude-3.5-sonnet") != null);
}

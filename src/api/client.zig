const std = @import("std");
const types = @import("types.zig");

/// Debug logging (writes to file)
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/zig-agent-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[api] " ++ fmt ++ "\n", args) catch return;
    file.writeAll(msg) catch return;
}

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

        return std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(req, .{ .emit_null_optional_fields = false })});
    }

    pub fn streamChatCompletion(
        self: *APIClient,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        callback: *const fn (types.StreamChunk, *anyopaque) void,
        context: *anyopaque,
    ) !void {
        debugLog("streamChatCompletion start", .{});

        const payload = try self.buildRequest(messages, tools);
        defer self.allocator.free(payload);
        debugLog("request payload built, len={d}", .{payload.len});

        const url_str = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url_str);
        const parsed_uri = try std.Uri.parse(url_str);
        debugLog("url: {s}", .{url_str});

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "HTTP-Referer", .value = "https://github.com/anthony/zig-agent" },
            .{ .name = "X-Title", .value = "Zig Agent" },
        };

        // Reinitialize HTTP client to avoid connection state issues
        self.client.deinit();
        self.client = std.http.Client{ .allocator = self.allocator };

        debugLog("creating HTTP request...", .{});
        var req = try self.client.request(.POST, parsed_uri, .{
            .extra_headers = &extra_headers,
        });
        defer req.deinit();
        debugLog("HTTP request created", .{});

        // Create a mutable copy of the payload (sendBodyComplete expects []u8, not []const u8)
        const mutable_payload = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(mutable_payload);
        @memcpy(mutable_payload, payload);

        req.transfer_encoding = .{ .content_length = mutable_payload.len };
        debugLog("sending body len={d}...", .{mutable_payload.len});
        try req.sendBodyComplete(mutable_payload);
        debugLog("body sent", .{});

        var redirect_buffer: [4096]u8 = undefined;
        debugLog("waiting for response head...", .{});
        var response = try req.receiveHead(&redirect_buffer);
        debugLog("received response head, status={d}", .{@intFromEnum(response.head.status)});

        if (response.head.status != .ok) {
            debugLog("API error, non-200 status", .{});
            return error.APIError;
        }

        var parser = SSEParser.init(self.allocator);
        defer parser.deinit();

        var read_buf: [16384]u8 = undefined;
        var transfer_buffer: [16384]u8 = undefined;
        const reader_ptr = response.reader(&transfer_buffer);
        debugLog("entering read loop", .{});

        while (true) {
            const n = try reader_ptr.readSliceShort(&read_buf);
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

                        // Check for usage information (sent in final chunk)
                        if (parsed.value.usage) |usage| {
                            callback(.{ .usage = .{
                                .prompt_tokens = usage.prompt_tokens,
                                .completion_tokens = usage.completion_tokens,
                            } }, context);
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

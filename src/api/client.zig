const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils");
const logging = utils.logging;

// Use logging.debugLog instead of local definition

pub const SSEEvent = union(enum) {
    json: []const u8,
    done,
};

pub const SSEParser = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    consumed: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .buffer = std.ArrayList(u8){},
            .allocator = allocator,
            .consumed = 0,
        };
    }

    pub fn deinit(self: *SSEParser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn push(self: *SSEParser, chunk: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, chunk);
    }

    pub fn next(self: *SSEParser) !?SSEEvent {
        // Remove previously consumed data
        if (self.consumed > 0) {
            try self.buffer.replaceRange(self.allocator, 0, self.consumed, &.{});
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
            try self.buffer.replaceRange(self.allocator, 0, self.consumed, &.{});
            self.consumed = 0;
        }
    }
};

pub const APIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, model: ?[]const u8) !APIClient {
        if (api_key.len == 0) return error.MissingAPIKey;

        return APIClient{
            .allocator = allocator,
            .api_key = api_key,
            .model = model orelse "anthropic/claude-haiku-4.5",
        };
    }

    pub fn deinit(self: *APIClient) void {
        _ = self;
        // No cleanup needed for curl-based client
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
        logging.debugLog("streamChatCompletion start (curl)", .{});

        const payload = try self.buildRequest(messages, tools);
        defer self.allocator.free(payload);
        logging.debugLog("request payload built, len={d}", .{payload.len});

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url);
        logging.debugLog("url: {s}", .{url});

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        // Spawn curl process
        // -s: silent (no progress)
        // -S: show errors
        // -N: no buffering (important for SSE streaming)
        // -X POST: POST method
        // -H: headers
        // -d @-: read body from stdin
        var child = std.process.Child.init(&.{
            "curl",
            "-sSN",
            "-X",
            "POST",
            "-H",
            auth_header,
            "-H",
            "Content-Type: application/json",
            "-H",
            "HTTP-Referer: https://github.com/anthropics/zig-agent",
            "-H",
            "X-Title: Zig Agent",
            "-d",
            "@-",
            url,
        }, self.allocator);

        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        logging.debugLog("spawning curl...", .{});
        try child.spawn();
        logging.debugLog("curl spawned", .{});

        // Write payload to stdin
        if (child.stdin) |stdin| {
            logging.debugLog("writing payload to curl stdin...", .{});

            var buf: [4096]u8 = undefined;
            var writer = stdin.writer(&buf).interface;
            writer.writeAll(payload) catch |err| {
                logging.debugLog("failed to write to stdin: {any}", .{err});
                return error.CurlWriteFailed;
            };
            stdin.close();
            child.stdin = null;
            logging.debugLog("payload written, stdin closed", .{});
        }

        // Read and parse SSE from stdout
        var parser = SSEParser.init(self.allocator);
        defer parser.deinit();

        if (child.stdout) |stdout| {
            var read_buf: [4096]u8 = undefined;
            logging.debugLog("entering read loop", .{});

            while (true) {
                const bytes_read = stdout.read(&read_buf) catch |err| {
                    logging.debugLog("read error: {any}", .{err});
                    break;
                };
                if (bytes_read == 0) {
                    logging.debugLog("EOF from curl", .{});
                    break;
                }

                logging.debugLog("read {d} bytes from curl", .{bytes_read});
                try parser.push(read_buf[0..bytes_read]);

                while (try parser.next()) |ev| {
                    switch (ev) {
                        .done => {
                            logging.debugLog("received [DONE]", .{});
                            _ = child.wait() catch |err| {
                                logging.debugLog("Failed to wait for curl process: {any}", .{err});
                            };
                            return;
                        },
                        .json => |json| {
                            const parsed = std.json.parseFromSlice(types.ChatCompletionChunk, self.allocator, json, .{
                                .ignore_unknown_fields = true,
                            }) catch |err| {
                                logging.debugLog("JSON parse error: {any}", .{err});
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

        // Check for errors from stderr
        if (child.stderr) |stderr| {
            var err_buf: [1024]u8 = undefined;
            const err_len = stderr.read(&err_buf) catch 0;
            if (err_len > 0) {
                logging.debugLog("curl stderr: {s}", .{err_buf[0..err_len]});
            }
        }

        // Wait for curl to finish
        const result = child.wait() catch |err| {
            logging.debugLog("wait error: {any}", .{err});
            return error.CurlFailed;
        };

        if (result.Exited != 0) {
            logging.debugLog("curl exited with code {d}", .{result.Exited});
            return error.CurlFailed;
        }

        logging.debugLog("streamChatCompletion complete", .{});
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

    try std.testing.expect(std.mem.indexOf(u8, req_json, "anthropic/claude-haiku-4.5") != null);
}

test "SSEParser handles CRLF line endings" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("data: {\"test\":\"data\"}\r\n");

    const ev = (try parser.next()).?;
    try std.testing.expectEqualStrings("{\"test\":\"data\"}", ev.json);
}

test "SSEParser handles partial chunks" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("data: {\"foo\":");
    try parser.push("\"bar\"}\n");

    const ev = (try parser.next()).?;
    try std.testing.expectEqualStrings("{\"foo\":\"bar\"}", ev.json);
}

test "SSEParser handles multiple events in single push" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("data: event1\ndata: event2\n");

    const ev1 = (try parser.next()).?;
    try std.testing.expectEqualStrings("event1", ev1.json);

    const ev2 = (try parser.next()).?;
    try std.testing.expectEqualStrings("event2", ev2.json);
}

test "SSEParser ignores empty lines" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("\n");
    try parser.push("data: valid\n");
    try parser.push("\n");

    const ev = (try parser.next()).?;
    try std.testing.expectEqualStrings("valid", ev.json);

    const no_ev = try parser.next();
    try std.testing.expect(no_ev == null);
}

test "SSEParser handles DONE signal" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    try parser.push("data: {\"content\":\"hello\"}\n");
    try parser.push("data: [DONE]\n");

    // First event is JSON
    const ev1 = (try parser.next()).?;
    try std.testing.expect(ev1 == .json);
    try std.testing.expectEqualStrings("{\"content\":\"hello\"}", ev1.json);

    // Second event is done signal
    const ev2 = (try parser.next()).?;
    try std.testing.expect(ev2 == .done);

    // No more events
    const ev3 = try parser.next();
    try std.testing.expect(ev3 == null);
}

test "APIClient init with empty key returns error" {
    const allocator = std.testing.allocator;

    const result = APIClient.init(allocator, "", null);
    try std.testing.expectError(error.MissingAPIKey, result);
}

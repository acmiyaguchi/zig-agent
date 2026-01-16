# Spec: API Client

**Capability**: `api-client`
**Change**: `implement-minimal-viable-agent`
**Status**: Draft

## Purpose

Implement HTTP client for OpenRouter API with streaming support. This spec defines the API integration that enables the agent to communicate with Claude (and other models) through OpenRouter's unified interface.

## Context

OpenRouter provides an OpenAI-compatible API for accessing 400+ AI models including Claude. The implementation follows patterns documented in `docs/concepts/openrouter-api.md` and uses Server-Sent Events (SSE) for streaming responses.

## ADDED Requirements

### Requirement: API client shall authenticate with OpenRouter using Bearer token

**Priority**: Critical
**Rationale**: Authentication is required for all API calls

The APIClient SHALL:
- Read API key from initialization parameter
- Include `Authorization: Bearer <key>` header in all requests
- Fail fast with clear error if API key is invalid
- Never log or expose the API key in debug output

#### Scenario: Initialize client with API key

```zig
const api_client = try APIClient.init(
    allocator,
    "sk-or-v1-abc123...",  // API key from environment
);
defer api_client.deinit();

// API key is stored internally
// Not exposed in any public field
try testing.expectEqual(@as(?[]const u8, null), api_client.api_key_debug);
```

#### Scenario: Handle missing API key

```zig
// User didn't set OPENROUTER_API_KEY
const result = APIClient.init(allocator, "");

// Returns error
try testing.expectError(error.MissingAPIKey, result);
```

---

### Requirement: Client shall POST requests to /chat/completions endpoint

**Priority**: Critical
**Rationale**: Core API endpoint for chat interactions

The client SHALL:
- POST to `https://openrouter.ai/api/v1/chat/completions`
- Set `Content-Type: application/json` header
- Include model name in request body
- Include messages array in OpenRouter format
- Include tool definitions if provided
- Set `stream: true` for streaming responses

#### Scenario: Build chat completion request

```zig
const messages = &[_]Message{
    .{ .role = .user, .content = "Hello!" },
};

const request_json = try api_client.buildRequest(
    messages,
    &[_]ToolDefinition{},  // No tools for this example
);
defer allocator.free(request_json);

// Verify JSON structure
const parsed = try std.json.parseFromSlice(
    RequestBody,
    allocator,
    request_json,
    .{},
);
defer parsed.deinit();

try testing.expectEqualStrings("anthropic/claude-sonnet-4.5", parsed.value.model);
try testing.expectEqual(@as(usize, 1), parsed.value.messages.len);
try testing.expect(parsed.value.stream == true);
```

---

### Requirement: Client shall parse Server-Sent Events (SSE) from streaming responses

**Priority**: Critical
**Rationale**: Streaming is essential for responsive UX

The SSE parser SHALL:
- Read line-by-line from HTTP response body
- Skip empty lines
- Skip comment lines (starting with `:`)
- Parse `data:` lines as JSON
- Detect `data: [DONE]` terminator
- Handle incremental content deltas
- Handle tool_calls in streaming format

#### Scenario: Parse SSE text streaming

```zig
const mock_sse =
    \\data: {"choices":[{"delta":{"content":"Hello"}}]}
    \\
    \\data: {"choices":[{"delta":{"content":" world"}}]}
    \\
    \\data: [DONE]
    \\
;

var chunks = std.ArrayList([]const u8).init(allocator);
defer chunks.deinit();

try parseSSEStream(mock_sse, &chunks);

try testing.expectEqual(@as(usize, 2), chunks.items.len);
try testing.expectEqualStrings("Hello", chunks.items[0]);
try testing.expectEqualStrings(" world", chunks.items[1]);
```

#### Scenario: Parse SSE with comments (keepalive)

```zig
const mock_sse =
    \\: OPENROUTER PROCESSING
    \\data: {"choices":[{"delta":{"content":"Hi"}}]}
    \\: keepalive
    \\data: [DONE]
    \\
;

var chunks = std.ArrayList([]const u8).init(allocator);
defer chunks.deinit();

try parseSSEStream(mock_sse, &chunks);

// Comments are ignored
try testing.expectEqual(@as(usize, 1), chunks.items.len);
try testing.expectEqualStrings("Hi", chunks.items[0]);
```

#### Scenario: Handle interrupted stream gracefully

```zig
// Stream terminates mid-JSON (connection dropped)
const mock_sse =
    \\data: {"choices":[{"delta":{"content":"Hello"}}]}
    \\
    \\data: {"choices":[{"delta":{"content":" wor
;
// Note: truncated mid-JSON

var chunks = std.ArrayList([]const u8).init(allocator);
defer chunks.deinit();

const result = parseSSEStream(mock_sse, &chunks);

// Should return error, not crash
try testing.expectError(error.StreamInterrupted, result);
// Should still have captured the first complete chunk
try testing.expectEqual(@as(usize, 1), chunks.items.len);
try testing.expectEqualStrings("Hello", chunks.items[0]);
```

#### Scenario: Handle malformed JSON in stream

```zig
// Server sends invalid JSON
const mock_sse =
    \\data: {"choices":[{"delta":{"content":"Hi"}}]}
    \\
    \\data: {invalid json here}
    \\
    \\data: [DONE]
    \\
;

var chunks = std.ArrayList([]const u8).init(allocator);
defer chunks.deinit();

// Should skip malformed line and continue, not crash
try parseSSEStream(mock_sse, &chunks);

// First valid chunk should still be captured
try testing.expectEqual(@as(usize, 1), chunks.items.len);
try testing.expectEqualStrings("Hi", chunks.items[0]);
```

---

### Requirement: Client shall handle tool_calls in streaming responses

**Priority**: Critical
**Rationale**: Tool use is essential for agent functionality

When API responds with tool_calls, the client SHALL:
- Parse tool call ID, function name, arguments
- Accumulate streamed argument JSON
- Provide complete ToolCall struct to callback
- Support multiple tool calls in single response

#### Scenario: Parse tool call in stream

```zig
const mock_sse =
    \\data: {"choices":[{"delta":{"tool_calls":[{"id":"call_123","type":"function","function":{"name":"read_file","arguments":""}}]}}]}
    \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"/foo/bar.txt\"}"}}]}}]}
    \\data: {"choices":[{"finish_reason":"tool_calls"}]}
    \\data: [DONE]
    \\
;

var tool_calls = std.ArrayList(ToolCall).init(allocator);
defer tool_calls.deinit();

try parseSSEStream(mock_sse, &tool_calls);

try testing.expectEqual(@as(usize, 1), tool_calls.items.len);
try testing.expectEqualStrings("call_123", tool_calls.items[0].id);
try testing.expectEqualStrings("read_file", tool_calls.items[0].function.name);
try testing.expectEqualStrings("{\"path\":\"/foo/bar.txt\"}", tool_calls.items[0].function.arguments);
```

---

### Requirement: Client shall emit streaming events via callback

**Priority**: High
**Rationale**: Enables real-time UI updates during API calls

The streamChatCompletion method SHALL:
- Accept a callback function pointer
- Call callback for each SSE chunk with parsed data
- Use tagged union for chunk types (content, tool_call, finish)
- Continue until stream terminates or error occurs

#### Scenario: Stream with callback

```zig
var received_chunks = std.ArrayList(StreamChunk).init(allocator);
defer received_chunks.deinit();

const callback = struct {
    fn handle(chunk: StreamChunk, ctx: *anyopaque) void {
        const chunks = @as(*std.ArrayList(StreamChunk), @ptrCast(@alignCast(ctx)));
        chunks.append(chunk) catch unreachable;
    }
}.handle;

try api_client.streamChatCompletion(
    messages,
    tools,
    callback,
    &received_chunks,
);

// Callback was invoked for each chunk
try testing.expect(received_chunks.items.len > 0);
```

---

### Requirement: Client shall handle HTTP errors gracefully

**Priority**: High
**Rationale**: Network errors are common, must not crash

The client SHALL handle:
- 400 Bad Request: Invalid request format
- 401 Unauthorized: Invalid API key
- 402 Payment Required: Insufficient OpenRouter credits
- 429 Too Many Requests: Rate limiting
- 500+ Server Errors: OpenRouter or provider issues
- Network timeouts
- Connection failures

Error handling SHALL:
- Return descriptive error types (not generic NetworkError)
- Include HTTP status code in error
- Not retry automatically (v1 simplification)
- Log errors to stderr

#### Scenario: Handle 401 Unauthorized

```zig
// Mock HTTP client returns 401
const result = api_client.streamChatCompletion(messages, tools, callback, ctx);

try testing.expectError(error.Unauthorized, result);
// Error is descriptive and actionable
```

#### Scenario: Handle 429 Rate Limit

```zig
const result = api_client.streamChatCompletion(messages, tools, callback, ctx);

try testing.expectError(error.RateLimited, result);
// Client does NOT automatically retry (v1)
// Caller can implement backoff if needed
```

---

### Requirement: Client shall use minimal memory for streaming

**Priority**: High
**Rationale**: Constrained device target (N900)

The implementation SHALL:
- Use 16KB line buffer for SSE parsing (tool call arguments can be large)
- Process chunks immediately, don't buffer full response
- Free chunk memory after callback returns
- Reuse allocations where possible

#### Scenario: Memory usage during streaming

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    const leaked = gpa.deinit();
    try testing.expect(leaked == .ok); // No leaks
}

const api_client = try APIClient.init(gpa.allocator(), api_key);
defer api_client.deinit();

const baseline_rss = getCurrentRSS();

try api_client.streamChatCompletion(messages, tools, callback, ctx);

const peak_rss = getCurrentRSS();

// Streaming overhead is minimal (<5MB for typical response)
try testing.expect(peak_rss - baseline_rss < 5 * 1024 * 1024);
```

---

### Requirement: Client shall serialize tool definitions to OpenRouter format

**Priority**: High
**Rationale**: OpenRouter uses OpenAI function calling format

Tool definitions MUST be serialized as:
- `type: "function"` for all tools
- `function.name`: tool name
- `function.description`: tool description
- `function.parameters`: JSON schema object

#### Scenario: Serialize read_file tool

```zig
const tool = Tool{
    .name = "read_file",
    .description = "Read contents of a file",
    .parameters = .{
        .type = "object",
        .properties = .{
            .path = .{
                .type = "string",
                .description = "Absolute path to file",
            },
        },
        .required = &[_][]const u8{"path"},
    },
};

const json = try api_client.serializeToolDefinition(allocator, tool);
defer allocator.free(json);

const expected =
    \\{"type":"function","function":{"name":"read_file","description":"Read contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to file"}},"required":["path"]}}}
;

try testing.expectEqualStrings(expected, json);
```

---

## Non-Requirements (Out of Scope)

- Retry logic with exponential backoff (v1: fail fast)
- Prompt caching (v2 optimization)
- Multiple models/fallback (v1: hardcode claude-sonnet-4.5)
- Request/response logging to file (v1: stderr only)
- HTTP/2 support (v1: HTTP/1.1 via std.http.Client)
- Request cancellation (v1: wait for completion)
- Concurrent requests (v1: one at a time)

## Dependencies

- **Requires**: `project-structure` (build system, types)
- **Provides**: API communication for `agent-core`

## Testing Strategy

**Unit Tests**:
- SSE parsing with various formats
- JSON serialization/deserialization
- Error handling for each HTTP status code
- Tool definition formatting

**Integration Tests** (manual):
- Real OpenRouter API call with valid key
- Streaming response parsing
- Tool use round-trip

**Performance Tests**:
- Memory usage during streaming
- Parsing throughput for large responses

## Related Specs

- `agent-core` - Consumes API client for model communication
- `project-structure` - Defines types and module organization

## Migration Notes

N/A (greenfield implementation)

## Open Questions

1. **HTTP client**: Use std.http.Client or third-party library?
   - **Decision**: std.http.Client for simplicity, fewer dependencies

2. **Timeout values**: What timeout for API requests?
   - **Proposal**: 60s for streaming (Claude can take time thinking)

3. **SSL/TLS**: Does std.http.Client handle HTTPS properly?
   - **Verify**: Test HTTPS in prototype

## References

- [openrouter-api.md](../../../../docs/concepts/openrouter-api.md)
- [OpenRouter API Reference](https://openrouter.ai/docs/api/reference/overview)
- [OpenRouter Streaming](https://openrouter.ai/docs/api/reference/streaming)
- [SSE Specification](https://html.spec.whatwg.org/multipage/server-sent-events.html)

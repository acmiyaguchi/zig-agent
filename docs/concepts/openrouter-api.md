# OpenRouter API Integration

## Overview

OpenRouter is a unified API gateway that provides access to 400+ AI models from multiple providers (Anthropic, OpenAI, Google, Meta, etc.) through a single, OpenAI-compatible API.

**Base URL**: `https://openrouter.ai/api/v1`

**For zig-agent**, we use OpenRouter instead of direct Anthropic API for several advantages:
1. **Model flexibility**: Easy switching between Claude models (Haiku/Sonnet/Opus) and other providers
2. **Cost optimization**: No markup over provider pricing, competitive rates
3. **Fallback options**: If Claude is down, can instantly switch to another model
4. **Unified interface**: OpenAI-compatible API simplifies client implementation
5. **Claude Code compatibility**: Direct integration with existing Claude Code infrastructure

## Why OpenRouter Over Direct Anthropic API?

| Aspect | Direct Anthropic API | OpenRouter |
|--------|---------------------|------------|
| **Models** | Claude only | 400+ models (Claude, GPT, Gemini, etc.) |
| **Pricing** | Provider rate | Same rate (no markup) |
| **Switching** | Requires code changes | Change model name in request |
| **Fallback** | Manual implementation | Built-in routing |
| **API format** | Anthropic-specific | OpenAI-compatible (simpler) |
| **Downtime risk** | Single point of failure | Multiple provider options |

**For constrained devices**: Model flexibility is valuable. If a task works fine with Haiku instead of Sonnet, switching is trivial with OpenRouter.

## Authentication

### API Key Setup

1. Create account at [openrouter.ai](https://openrouter.ai)
2. Generate API key at [openrouter.ai/keys](https://openrouter.ai/keys)
3. Set environment variable:
   ```bash
   export OPENROUTER_API_KEY="sk-or-v1-..."
   ```

### Required Headers

```http
POST /api/v1/chat/completions
Host: openrouter.ai
Authorization: Bearer sk-or-v1-...
Content-Type: application/json
HTTP-Referer: https://your-site.com  (optional, for rankings)
X-Title: Your App Name               (optional, for rankings)
```

**Security**: Never commit API keys to repositories. OpenRouter monitors GitHub for exposed keys.

## API Endpoints

### Chat Completions (Primary Endpoint)

```
POST https://openrouter.ai/api/v1/chat/completions
```

This is the only endpoint you need for zig-agent. It handles:
- Text generation
- Tool use (function calling)
- Streaming responses
- Multi-turn conversations

### Models Endpoint (Optional)

```
GET https://openrouter.ai/api/v1/models
```

Returns list of available models with pricing and capabilities.

## Request Format

### Basic Request

```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [
    {
      "role": "user",
      "content": "Hello, Claude!"
    }
  ]
}
```

### With Tool Definitions

```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [
    {
      "role": "user",
      "content": "Read the file README.md"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read contents of a file",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Absolute file path"
            }
          },
          "required": ["path"]
        }
      }
    }
  ],
  "stream": true
}
```

**Note**: Tool definitions use OpenAI function calling format, which OpenRouter translates for Anthropic models.

## Response Format

### Non-Streaming

```json
{
  "id": "gen-abc123",
  "model": "anthropic/claude-haiku-4.5",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 15,
    "total_tokens": 25
  }
}
```

### Streaming (SSE)

```
data: {"id":"gen-abc123","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"gen-abc123","choices":[{"delta":{"content":"!"}}]}

data: {"id":"gen-abc123","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":25}}

data: [DONE]
```

**SSE Comments**: OpenRouter sends periodic comments to prevent timeouts:
```
: OPENROUTER PROCESSING
```
These can be safely ignored (per SSE spec, comments start with `:`).

## Streaming Implementation

### Enabling Streaming

Set `"stream": true` in request body:

```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [...],
  "stream": true
}
```

### SSE Parsing

Each line follows Server-Sent Events format:
- Data lines: `data: {json}`
- Comments: `: message` (ignore these)
- Terminator: `data: [DONE]`

### Error Handling

**Pre-stream errors** (before tokens sent):
- Standard HTTP status codes (400, 401, 402, 429, 502, 503)
- JSON error response in body

**Mid-stream errors** (after tokens started):
- HTTP status locked at 200 OK
- Error sent as SSE event:
  ```
  data: {"error":{"message":"Rate limit exceeded"},"choices":[{"finish_reason":"error"}]}
  ```

### Stream Cancellation

Supported for Anthropic models. Use AbortController pattern:

```zig
// Pseudo-code for stream cancellation
const cancel_token = CancellationToken.init();

// In request handler
if (cancel_token.isCancelled()) {
    try http_client.abort();
}

// On Ctrl+C
cancel_token.cancel();
```

## Model Selection

### Anthropic Claude Models

| Model | ID | Input | Output | Use Case |
|-------|----|----|--------|----------|
| **Haiku 4.5** | `anthropic/claude-haiku-4.5` | $1/M | $5/M | Fast (default) |
| **Sonnet 4.5** | `anthropic/claude-sonnet-4.5` | $3/M | $15/M | Balanced |
| **Opus 4.5** | `anthropic/claude-opus-4.5` | $15/M | $75/M | Complex reasoning |

Prices are per million tokens (M). No markup from OpenRouter.

### Dynamic Model Switching

```zig
const model = if (task_complexity == .simple)
    "anthropic/claude-haiku-4.5"
else if (task_complexity == .complex)
    "anthropic/claude-opus-4.5"
else
    "anthropic/claude-haiku-4.5";
```

This is trivial with OpenRouter, would require separate API clients for direct provider APIs.

### Fallback Strategy

If Claude is unavailable, OpenRouter can route to alternatives:

```zig
const model_priority = [_][]const u8{
    "anthropic/claude-haiku-4.5",  // Primary
    "openai/gpt-4o",                // Fallback 1
    "google/gemini-pro-1.5",        // Fallback 2
};

for (model_priority) |model| {
    const result = try callAPI(model, messages);
    if (result.success) return result;
}
```

## Tool Use (Function Calling)

### Tool Definition Format

OpenRouter uses OpenAI function calling format:

```zig
const tool_definition = .{
    .type = "function",
    .function = .{
        .name = "read_file",
        .description = "Read file contents",
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
    },
};
```

**Important**: Only use models that support tool use! Claude Sonnet/Opus support tools, but some cheaper models don't.

### Tool Call Response

When model wants to call a tool:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "read_file",
          "arguments": "{\"path\":\"/home/user/README.md\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

### Sending Tool Results

After executing the tool, send result back:

```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [
    {"role": "user", "content": "Read README.md"},
    {
      "role": "assistant",
      "content": null,
      "tool_calls": [{"id": "call_abc123", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"README.md\"}"}}]
    },
    {
      "role": "tool",
      "tool_call_id": "call_abc123",
      "content": "# My Project\n\nThis is the README."
    }
  ]
}
```

Model will then generate a response incorporating the tool result.

## Implementation for Zig-Agent

### HTTP Client Configuration

```zig
const APIClient = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    api_key: []const u8,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
    default_model: []const u8 = "anthropic/claude-haiku-4.5",

    pub fn init(allocator: Allocator, api_key: []const u8) !APIClient {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .api_key = api_key,
        };
    }

    pub fn deinit(self: *APIClient) void {
        self.http_client.deinit();
    }
};
```

### Request Builder

```zig
fn buildChatRequest(
    self: *APIClient,
    arena: Allocator,
    messages: []const Message,
    tools: []const Tool,
) ![]const u8 {
    const request = .{
        .model = self.default_model,
        .messages = messages,
        .tools = if (tools.len > 0) tools else null,
        .stream = true,
        .max_tokens = 4096,
    };

    return try std.json.stringifyAlloc(arena, request, .{});
}
```

### Streaming Response Handler

```zig
fn handleStreamingResponse(
    self: *APIClient,
    response: *std.http.Client.Response,
    callback: *const fn(event: StreamEvent) void,
) !void {
    var reader = response.reader();
    var buffer: [4096]u8 = undefined;

    while (true) {
        const line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse break;

        // Skip empty lines
        if (line.len == 0) continue;

        // Skip SSE comments (start with ':')
        if (line[0] == ':') continue;

        // Parse data lines
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..]; // Skip "data: " prefix

            // Check for stream terminator
            if (std.mem.eql(u8, data, "[DONE]")) {
                callback(.stream_complete);
                break;
            }

            // Parse JSON event
            const parsed = try std.json.parseFromSlice(
                StreamChunk,
                self.allocator,
                data,
                .{},
            );
            defer parsed.deinit();

            callback(.{ .chunk = parsed.value });
        }
    }
}
```

### Error Handling

```zig
fn handleAPIError(status: std.http.Status, body: []const u8) !void {
    return switch (status) {
        .bad_request => error.InvalidRequest,
        .unauthorized => error.InvalidAPIKey,
        .payment_required => error.InsufficientCredits,
        .too_many_requests => error.RateLimited,
        .bad_gateway => error.ProviderUnavailable,
        .service_unavailable => error.ServiceUnavailable,
        else => error.UnknownAPIError,
    };
}
```

## Memory Considerations for N900

### Streaming Buffer Size

Keep streaming buffers small:
- **4KB line buffer**: Handles SSE lines (typical: <1KB)
- **Incremental parsing**: Parse JSON as it arrives, don't buffer entire response
- **Event callbacks**: Process each chunk immediately, free memory after callback

```zig
// Good: Process immediately
while (try readSSELine(reader)) |line| {
    try processChunk(line);  // Parse, emit event, free
}

// Bad: Buffer everything
var all_chunks = std.ArrayList(u8).init(allocator);
while (try readSSELine(reader)) |line| {
    try all_chunks.appendSlice(line);  // Memory grows!
}
```

### Connection Pooling

For constrained devices, single persistent connection:

```zig
const http_client = std.http.Client{
    .allocator = allocator,
    // Reuse connection for multiple requests
};
```

**Trade-off**: Slightly higher latency on first request, but saves memory by not maintaining connection pool.

## Configuration

### Environment Variables

```bash
# Required
export OPENROUTER_API_KEY="sk-or-v1-..."

# Optional
export OPENROUTER_MODEL="anthropic/claude-haiku-4.5"
export OPENROUTER_BASE_URL="https://openrouter.ai/api/v1"
export OPENROUTER_MAX_TOKENS="4096"
```

### Config File (.zigagent.json)

```json
{
  "api": {
    "provider": "openrouter",
    "base_url": "https://openrouter.ai/api/v1",
    "model": "anthropic/claude-haiku-4.5",
    "max_tokens": 4096,
    "temperature": 0.7
  },
  "fallback_models": [
    "anthropic/claude-haiku-4.5",
    "openai/gpt-4o-mini"
  ]
}
```

## Testing

### Mock OpenRouter Responses

For testing without API calls:

```zig
test "parse streaming response" {
    const mock_sse =
        \\data: {"id":"gen-123","choices":[{"delta":{"content":"Hello"}}]}
        \\
        \\data: {"id":"gen-123","choices":[{"delta":{"content":"!"}}]}
        \\
        \\data: [DONE]
    ;

    var chunks = std.ArrayList([]const u8).init(testing.allocator);
    defer chunks.deinit();

    try parseSSEStream(mock_sse, &chunks);

    try testing.expectEqual(@as(usize, 2), chunks.items.len);
    try testing.expectEqualStrings("Hello", chunks.items[0]);
    try testing.expectEqualStrings("!", chunks.items[1]);
}
```

### Local Mock Server

Run a local HTTP server that mimics OpenRouter for testing:

```bash
# Mock server returns canned responses
python3 test/mock_openrouter.py &
export OPENROUTER_BASE_URL="http://localhost:8080/api/v1"
./zig-agent
```

## Comparison: OpenRouter vs Direct Anthropic API

### Request Format Differences

**OpenRouter (OpenAI-compatible)**:
```json
{
  "model": "anthropic/claude-haiku-4.5",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": true
}
```

**Direct Anthropic**:
```json
{
  "model": "claude-sonnet-4-5-20250929",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": true,
  "max_tokens": 4096
}
```

**Key differences**:
1. Model names: OpenRouter prefixes with `anthropic/`
2. Tools format: OpenRouter uses OpenAI function calling, Anthropic uses native tools
3. Both support streaming with same `stream: true` flag

### Code Migration

To switch from direct Anthropic to OpenRouter:

```zig
// Before (Direct Anthropic)
const api_client = AnthropicClient.init(allocator, anthropic_key);
const response = try api_client.createMessage(.{
    .model = "claude-sonnet-4-5-20250929",
    .messages = messages,
});

// After (OpenRouter)
const api_client = APIClient.init(allocator, openrouter_key);
api_client.base_url = "https://openrouter.ai/api/v1";
api_client.default_model = "anthropic/claude-haiku-4.5";
const response = try api_client.createChatCompletion(.{
    .messages = messages,
});
```

**Migration effort**: ~1-2 hours to update API client, test streaming, verify tool use.

## Cost Optimization Strategies

### Dynamic Model Selection

```zig
fn selectModel(task: Task) []const u8 {
    return switch (task.complexity) {
        .simple => "anthropic/claude-haiku-4.5",  // $1/M input
        .medium => "anthropic/claude-haiku-4.5", // $3/M input
        .complex => "anthropic/claude-opus-4.5",  // $15/M input
    };
}
```

**Savings**: Using Haiku for simple tasks (file reads, grep) saves 66% vs Sonnet.

### Caching (Future)

OpenRouter supports prompt caching for Anthropic models:
- Cache system prompts (reused across requests)
- Cache conversation history (for multi-turn)
- 90% cost reduction on cached tokens

See: [OpenRouter caching docs](https://openrouter.ai/docs/api/reference/parameters#prompt-caching)

## Troubleshooting

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| 401 Unauthorized | Invalid API key | Check OPENROUTER_API_KEY |
| 402 Payment Required | Insufficient credits | Add credits at openrouter.ai/credits |
| 429 Too Many Requests | Rate limited | Implement exponential backoff |
| 502 Bad Gateway | Provider down | Use fallback model |
| Tool use not working | Model doesn't support tools | Use Claude Sonnet/Opus |

### Debug Logging

```zig
fn logRequest(request: []const u8) void {
    std.log.debug("OpenRouter request: {s}", .{request});
}

fn logResponse(status: std.http.Status, body: []const u8) void {
    std.log.debug("OpenRouter response: {d} {s}", .{@intFromEnum(status), body});
}
```

### Rate Limiting

Implement exponential backoff:

```zig
fn retryWithBackoff(
    comptime max_retries: usize,
    request: Request,
) !Response {
    var attempt: usize = 0;
    var delay_ms: u64 = 1000; // Start with 1 second

    while (attempt < max_retries) : (attempt += 1) {
        const result = sendRequest(request) catch |err| {
            if (err == error.RateLimited) {
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms *= 2; // Exponential backoff
                continue;
            }
            return err;
        };
        return result;
    }
    return error.MaxRetriesExceeded;
}
```

## External References

- [OpenRouter API Reference](https://openrouter.ai/docs/api/reference/overview)
- [OpenRouter Quickstart](https://openrouter.ai/docs/quickstart)
- [Authentication Guide](https://openrouter.ai/docs/api/reference/authentication)
- [Streaming Documentation](https://openrouter.ai/docs/api/reference/streaming)
- [Claude Code Integration](https://openrouter.ai/docs/guides/guides/claude-code-integration)
- [OpenRouter Pricing](https://openrouter.ai/pricing)
- [Available Models](https://openrouter.ai/docs/guides/overview/models)

## Related Documentation

- [api-client.md](api-client.md) - HTTP client implementation
- [streaming.md](streaming.md) - SSE parsing details
- [architecture.md](architecture.md) - Overall system design
- [performance-constraints.md](performance-constraints.md) - Memory budgets

## Summary

**OpenRouter is the recommended API provider for zig-agent** because:

1. ✅ **Flexibility**: Switch between Claude models (Haiku/Sonnet/Opus) trivially
2. ✅ **Cost**: Same pricing as direct provider, option to use cheaper models
3. ✅ **Reliability**: Fallback to other providers if Claude is down
4. ✅ **Simplicity**: OpenAI-compatible API is easier to implement than native Anthropic API
5. ✅ **Future-proof**: Easy to add new models (GPT, Gemini) without code changes

**Implementation priority for v1**:
1. Basic chat completions with streaming
2. Tool use support (essential for coding agent)
3. Error handling and retries
4. Dynamic model selection (Haiku for simple tasks)

**Future enhancements (v2+)**:
- Prompt caching for repeated requests
- Automatic fallback on provider errors
- Cost tracking and optimization
- Model performance benchmarking

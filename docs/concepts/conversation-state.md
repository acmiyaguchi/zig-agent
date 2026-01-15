# Conversation State Management

## Overview

The agent must track conversation history to maintain context across turns. Poor state management leads to excessive memory usage and CPU overhead from constant JSON serialization. This document covers efficient data structures and strategies for constrained devices.

## The Challenge

### What Must Be Tracked

1. **Conversation history**: All messages exchanged with API
2. **Current turn state**: Streaming response, pending tools
3. **Tool execution context**: Working directory, file cache
4. **Session metadata**: Token usage, timing, errors

### The Serialization Problem

**Naive approach**:
```
Receive JSON → Parse to structs → Store structs →
Convert to JSON → Send to API → Repeat
```

**Problems**:
- Parse entire API response (1-10KB) every turn
- Serialize entire conversation (growing unbounded) every turn
- Memory overhead: JSON string + parsed structs = 2x memory
- CPU overhead: Constant serialization on slow ARM CPU

## Efficient Data Structures

### Message Representation

**Wire format** (what API expects):
```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "Hello"}
  ]
}
```

**In-memory representation** (what we store):
```zig
const Message = struct {
    role: Role,
    content: Content,

    const Role = enum { user, assistant };

    const Content = union(enum) {
        text: []const u8,
        tool_use: ToolUse,
        tool_result: ToolResult,
    };

    const ToolUse = struct {
        id: []const u8,
        name: []const u8,
        input: []const u8,  // Store as JSON string, don't parse
    };

    const ToolResult = struct {
        tool_use_id: []const u8,
        content: []const u8,
    };
};
```

**Key insight**: Store strings, not deeply parsed structures. Only parse what you need, when you need it.

### Conversation History

**Option 1: ArrayList of Messages** (Simple)
```zig
const Conversation = struct {
    messages: std.ArrayList(Message),
    allocator: Allocator,
};
```

**Pros**: Simple, dynamically grows
**Cons**: Growing array may relocate (memory fragmentation), unbounded growth

**Option 2: Ring Buffer** (Bounded)
```zig
const Conversation = struct {
    messages: []Message,  // Fixed-size buffer
    head: usize,
    tail: usize,
    count: usize,
    max_messages: usize = 100,  // Keep last 100 messages
};
```

**Pros**: Bounded memory, cache-friendly, no allocation churn
**Cons**: Loses old history (acceptable for most use cases)

**Recommendation**: Ring buffer with configurable max_messages.

### Arena Allocation Strategy

Use arena allocators for request-scoped memory:

```zig
const TurnState = struct {
    arena: std.heap.ArenaAllocator,
    response_buffer: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),

    fn init(parent_allocator: Allocator) TurnState {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .response_buffer = std.ArrayList(u8).init(arena.allocator()),
            .tool_calls = std.ArrayList(ToolCall).init(arena.allocator()),
        };
    }

    fn deinit(self: *TurnState) void {
        // Single free for entire turn
        self.arena.deinit();
    }
};
```

**Benefit**: All turn-scoped allocations freed at once. No tracking individual frees.

## Minimizing JSON Serialization

### Strategy 1: Lazy Serialization

Don't serialize until absolutely necessary (sending to API):

```zig
fn sendRequest(conv: *Conversation) !void {
    // Only serialize when sending
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try std.json.stringify(.{
        .model = "claude-sonnet-4",
        .messages = conv.messages.items,
        .max_tokens = 4096,
    }, .{}, buffer.writer());

    try api_client.send(buffer.items);
}
```

**Benefit**: Serialize once per turn, not constantly.

### Strategy 2: Incremental Message Building

Don't buffer entire response before parsing:

```zig
const StreamParser = struct {
    current_message: Message,
    current_text: std.ArrayList(u8),

    fn handleChunk(self: *Self, event: SSEEvent) !void {
        switch (event.type) {
            .content_block_delta => {
                // Append directly, no intermediate buffer
                try self.current_text.appendSlice(event.delta.text);
                // Stream to UI immediately
                try ui.display(event.delta.text);
            },
            .message_stop => {
                // Finalize message
                self.current_message.content = .{
                    .text = try self.current_text.toOwnedSlice(),
                };
            },
        }
    }
};
```

**Benefit**: Stream through, don't buffer entire response.

### Strategy 3: Avoid Re-serializing History

The conversation history doesn't change, so cache its serialization:

```zig
const Conversation = struct {
    messages: std.ArrayList(Message),
    serialized_cache: ?[]const u8 = null,
    cache_valid: bool = false,

    fn addMessage(self: *Self, msg: Message) !void {
        try self.messages.append(msg);
        // Invalidate cache
        self.cache_valid = false;
        if (self.serialized_cache) |cache| {
            self.allocator.free(cache);
            self.serialized_cache = null;
        }
    }

    fn serialize(self: *Self) ![]const u8 {
        if (self.cache_valid and self.serialized_cache != null) {
            return self.serialized_cache.?;
        }

        // Serialize and cache
        var buffer = std.ArrayList(u8).init(self.allocator);
        try std.json.stringify(self.messages.items, .{}, buffer.writer());

        self.serialized_cache = try buffer.toOwnedSlice();
        self.cache_valid = true;

        return self.serialized_cache.?;
    }
};
```

**Benefit**: Only re-serialize when conversation changes (once per turn).

**Trade-off**: Extra memory for cache (worth it for CPU savings).

## Memory Budget Analysis

For 100-message conversation on Nokia N900:

### Naive Approach
- JSON strings: ~100KB (1KB per message)
- Parsed structs: ~50KB
- Intermediate buffers: ~50KB
- **Total**: ~200KB per conversation

With multiple serialization passes: ~400KB peak

### Optimized Approach
- Ring buffer (100 messages): ~50KB
- Current turn arena: ~10KB
- Serialization cache: ~100KB (amortized)
- **Total**: ~160KB steady state

**Savings**: ~40% memory reduction + less fragmentation

## Streaming Response Handling

### The Problem

API returns Server-Sent Events:
```
data: {"type":"content_block_start",...}

data: {"type":"content_block_delta","delta":{"text":"Hello"}}

data: {"type":"content_block_delta","delta":{"text":" world"}}

data: {"type":"message_stop",...}
```

### Naive Approach

Buffer entire response, then parse:
```zig
var response_buffer = std.ArrayList(u8).init(allocator);
while (try readChunk()) |chunk| {
    try response_buffer.appendSlice(chunk);
}
// Now parse entire buffer
const parsed = try parseJSON(response_buffer.items);
```

**Problem**: Response can be 10KB-100KB. Must allocate buffer for entire response.

### Optimized Approach

Incremental parsing:
```zig
const SSEParser = struct {
    line_buffer: [4096]u8,  // Fixed buffer for single line
    line_len: usize = 0,

    fn feedChunk(self: *Self, chunk: []const u8) !void {
        for (chunk) |byte| {
            if (byte == '\n') {
                // Parse complete line
                if (self.isDataLine()) {
                    const event = try self.parseEvent();
                    try self.handleEvent(event);
                }
                self.line_len = 0;
            } else {
                self.line_buffer[self.line_len] = byte;
                self.line_len += 1;
            }
        }
    }
};
```

**Benefit**: Fixed 4KB buffer vs unbounded response buffer.

## Tool Execution State

### Challenge

Tools need context (working directory, file cache, etc.) but shouldn't bloat conversation state.

### Solution: Separate Context

```zig
const AgentState = struct {
    conversation: Conversation,      // Message history
    tool_context: ToolContext,       // Execution context

    const ToolContext = struct {
        working_dir: []const u8,
        file_cache: std.StringHashMap([]const u8),
        recent_files: [10][]const u8,  // LRU cache
    };
};
```

**Principle**: Conversation state is what goes to API. Tool context is local only.

## Token Usage Tracking

Track token usage without bloating message structures:

```zig
const TokenUsage = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,

    fn update(self: *Self, response: APIResponse) void {
        self.input_tokens += response.usage.input_tokens;
        self.output_tokens += response.usage.output_tokens;
    }
};

const Session = struct {
    conversation: Conversation,
    token_usage: TokenUsage,  // Separate tracking
};
```

## Context Window Management

Claude API has token limits (~200K tokens). Must prune old messages:

```zig
const ConversationManager = struct {
    messages: RingBuffer(Message),
    max_tokens: usize = 100_000,  // Leave headroom

    fn estimateTokens(self: *Self) usize {
        // Rough estimate: 4 chars = 1 token
        var total_chars: usize = 0;
        for (self.messages.items()) |msg| {
            total_chars += msg.content.len();
        }
        return total_chars / 4;
    }

    fn pruneIfNeeded(self: *Self) !void {
        while (self.estimateTokens() > self.max_tokens) {
            // Drop oldest message
            _ = self.messages.pop_front();
        }
    }
};
```

**Strategy**: Keep recent context, drop oldest when near limit.

## Memory Layout Optimization

### Struct Packing

```zig
// Bad: 24 bytes (padding)
const Message_Bad = struct {
    role: u8,           // 1 byte + 7 padding
    content: []u8,      // 16 bytes (ptr + len)
};

// Good: 17 bytes (no padding)
const Message_Good = struct {
    content: []u8,      // 16 bytes
    role: u8,           // 1 byte
};
```

**For 100 messages**: Saves 700 bytes

### String Interning

Many strings repeat (role names, tool names):

```zig
const StringPool = struct {
    strings: std.StringHashMap([]const u8),

    fn intern(self: *Self, str: []const u8) ![]const u8 {
        if (self.strings.get(str)) |interned| {
            return interned;
        }
        const owned = try self.allocator.dupe(u8, str);
        try self.strings.put(owned, owned);
        return owned;
    }
};
```

**Benefit**: "user" role stored once, not 50 times.

## Persistence Considerations

### In-Memory Only (v1)

Conversation lost on exit. Simplest approach.

**Memory**: Only active conversation.

### Optional Save/Load (v2)

Save to file on exit, load on start:

```zig
fn saveConversation(conv: *Conversation, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try std.json.stringify(conv.messages.items, .{}, file.writer());
}
```

**Trade-off**: Disk I/O overhead, but enables resuming sessions.

### Streaming to Disk (v3+)

Append messages to file as they happen:

```zig
fn appendMessage(log: std.fs.File, msg: Message) !void {
    try std.json.stringify(msg, .{}, log.writer());
    try log.writeAll("\n");
}
```

**Benefit**: Crash-safe, bounded memory (read from disk if needed).

## Performance Targets

On Nokia N900 for 100-message conversation:

- **Memory**: <200KB for conversation state
- **Serialization time**: <10ms per turn
- **Parse time**: <5ms per response chunk
- **Total overhead**: <5% of turn time

## Recommended Architecture

```zig
const Agent = struct {
    // Long-lived state
    gpa: std.heap.GeneralPurposeAllocator,
    conversation: Conversation,  // Ring buffer, bounded
    tool_context: ToolContext,   // File cache, working dir

    // Per-turn state
    turn_arena: std.heap.ArenaAllocator,
    stream_parser: SSEParser,

    fn executeTurn(self: *Self, user_input: []const u8) !void {
        defer self.turn_arena.deinit();  // Free all turn memory

        // Add user message
        try self.conversation.addMessage(.{
            .role = .user,
            .content = .{ .text = user_input },
        });

        // Send request (lazy serialization)
        try self.sendRequest();

        // Stream response (incremental parsing)
        try self.streamResponse();

        // Execute tools if needed
        try self.executeTools();
    }
};
```

## Future Optimizations

### Message Deduplication

Hash message contents, store only unique messages:
- Save memory for repeated tool results
- Requires hash table overhead

### Compression

Compress old messages in ring buffer:
- Keep recent uncompressed for fast access
- Compress old messages (zlib ~50% ratio)
- Trade CPU for memory

### Memory-Mapped Storage

Store conversation in mmap'd file:
- OS handles paging
- Bounded RAM usage
- Slower access for old messages

**Verdict**: Defer until proven necessary.

## Testing Strategy

Measure memory and CPU:
- Track peak RSS during long conversations
- Profile serialization time
- Benchmark with 1000-message conversations
- Verify ring buffer doesn't leak

## Summary

**Key strategies**:
1. **Ring buffer**: Bounded memory, lose old history
2. **Arena allocators**: Per-turn memory, single free
3. **Lazy serialization**: Only when sending to API
4. **Incremental parsing**: Stream events, don't buffer
5. **Separate contexts**: Conversation vs tool state
6. **Cache serialization**: Don't re-serialize unchanged history

**Result**: ~160KB memory for 100 messages, <10ms serialization overhead per turn.

# Future Work & Architectural Improvements

This document tracks architectural improvements and feature ideas for zig-agent.

## Current Architecture Overview

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  main.zig   │────▶│   Agent     │────▶│  APIClient  │──▶ OpenRouter
│ (xev loop)  │     │             │     │  (SSE)      │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │
       ▼                   ▼
┌─────────────┐     ┌─────────────┐
│ TerminalUI  │     │ToolRegistry │──▶ read/write/edit/run/search/list
│ (termbox)   │     │             │
└─────────────┘     └─────────────┘
```

## Proposed Improvements

### 1. Abstract APIClient for Testability

**Status:** Not started
**Priority:** High
**Effort:** Medium
**Impact:** Unlocks Agent testing

The `Agent` struct is currently untested because it's tightly coupled to `APIClient`. Introducing an abstraction would enable mock providers for testing.

```zig
pub const ChatProvider = struct {
    ptr: *anyopaque,
    streamFn: *const fn(*anyopaque, messages: []const Message, tools: []const Tool, callback: StreamCallback) anyerror!void,

    pub fn stream(self: ChatProvider, messages: []const Message, tools: []const Tool, callback: StreamCallback) !void {
        return self.streamFn(self.ptr, messages, tools, callback);
    }
};

// Usage in Agent:
pub const Agent = struct {
    provider: ChatProvider,  // Instead of *APIClient
    // ...
};
```

**Benefits:**
- Test Agent.run() and processToolCalls() without network
- Swap providers (OpenRouter, Anthropic direct, local models)
- Deterministic test scenarios

---

### 2. Configuration System

**Status:** Not started
**Priority:** High
**Effort:** Low
**Impact:** Developer experience

Currently configuration is scattered:
- API key from environment variable
- Model hardcoded in main.zig
- Base URL hardcoded in APIClient

Proposed unified config:

```zig
pub const Config = struct {
    // API settings
    api_key: []const u8,
    model: []const u8 = "anthropic/claude-sonnet-4",
    base_url: []const u8 = "https://openrouter.ai/api/v1",

    // Limits
    max_tokens: u32 = 4096,
    timeout_secs: u32 = 300,
    max_file_size: usize = 1024 * 1024,  // 1MB

    // Memory thresholds
    memory_warning_threshold: usize = 40 * 1024 * 1024,
    memory_refuse_threshold: usize = 45 * 1024 * 1024,

    pub fn loadFromEnv(allocator: Allocator) !Config { ... }
    pub fn loadFromFile(allocator: Allocator, path: []const u8) !Config { ... }
};
```

---

### 3. Conversation Persistence

**Status:** Not started
**Priority:** Medium
**Effort:** Medium
**Impact:** User experience

Save and restore conversations to disk for:
- Long-running tasks that span sessions
- Crash recovery
- Reviewing past conversations

```zig
pub const SessionManager = struct {
    sessions_dir: []const u8,

    pub fn save(self: *SessionManager, conversation: *ConversationState, session_id: []const u8) !void { ... }
    pub fn load(self: *SessionManager, allocator: Allocator, session_id: []const u8) !ConversationState { ... }
    pub fn list(self: *SessionManager, allocator: Allocator) ![]SessionInfo { ... }
};
```

Storage format: JSON or MessagePack for messages array.

---

### 4. Structured Error Handling

**Status:** Not started
**Priority:** Medium
**Effort:** Medium
**Impact:** Debuggability

Current issues:
- `debugLog` swallows all errors silently
- No error context/wrapping
- Hard to trace failures

Proposed approach:

```zig
pub const AgentError = error{
    ApiConnectionFailed,
    ApiRateLimited,
    ToolExecutionFailed,
    ContextWindowExceeded,
    // ...
};

pub const ErrorContext = struct {
    err: anyerror,
    message: []const u8,
    source_location: ?std.builtin.SourceLocation,
    timestamp: i64,
};
```

Consider a centralized error reporter that:
- Logs to debug file with full context
- Surfaces user-friendly messages to UI
- Tracks error frequency for monitoring

---

### 5. Context Window Management

**Status:** Not started
**Priority:** Medium
**Effort:** High
**Impact:** Handles long conversations

Current state:
- Memory thresholds at 40MB/45MB
- No token counting before sending
- No automatic truncation strategy

Proposed improvements:

1. **Token counting** - Estimate tokens before API call
2. **Automatic summarization** - Summarize old messages when approaching limit
3. **Sliding window** - Keep recent N messages plus pinned system/important messages
4. **Tool result truncation** - Summarize large tool outputs

```zig
pub const ContextManager = struct {
    max_tokens: u32,

    pub fn fitToContext(self: *ContextManager, messages: []Message) ![]Message {
        // Returns messages that fit within token budget
        // Prioritizes: system prompt > recent messages > old messages
    }

    pub fn summarize(self: *ContextManager, messages: []Message) !Message {
        // Uses LLM to summarize a batch of messages into one
    }
};
```

---

### 6. Tool Plugin System

**Status:** Not started
**Priority:** Low
**Effort:** High
**Impact:** Extensibility

Current tools are compiled in. A plugin system would allow:
- User-defined tools without recompilation
- Tool sharing/distribution
- Sandboxed execution for security

Possible approaches:
1. **WASM plugins** - Sandboxed, portable
2. **External processes** - JSON-RPC over stdin/stdout
3. **Shared libraries** - Fast but platform-specific

```
~/.config/zig-agent/tools/
├── my-tool/
│   ├── manifest.json
│   └── tool.wasm
```

---

## What's Already Good

- Event-driven architecture with libxev
- Clean module separation (api/, agent/, tools/, ui/, utils/)
- Tool registry pattern for extensibility
- Memory-conscious design (RSS monitoring)
- Comprehensive test coverage for utilities (83 tests)
- SSE streaming for responsive UI

---

## Test Coverage Gaps

These are intentionally not unit tested due to complexity:

| Component | Reason | Mitigation |
|-----------|--------|------------|
| Agent.run() | Requires APIClient mock | Manual harness in src/harness/ |
| APIClient.streamChatCompletion() | Network I/O | Integration tests |
| TerminalUI rendering | Requires TTY | Manual testing |

Implementing item #1 (APIClient abstraction) would address the Agent testing gap.

---

## Notes

- Created: 2026-01-19
- Last updated: 2026-01-19

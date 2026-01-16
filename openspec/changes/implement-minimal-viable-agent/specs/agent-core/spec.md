# Spec: Agent Core

**Capability**: `agent-core`
**Change**: `implement-minimal-viable-agent`
**Status**: Draft

## Purpose

Implement the core agent loop that orchestrates API communication and tool execution. This is the "brain" that follows the pattern: receive user input → call model → execute tools → call model again until complete.

## Context

The agent loop is the fundamental pattern documented in `docs/concepts/architecture.md` lines 23-38. It's intentionally simple: the model controls the flow, we just execute tools and feed back results.

## ADDED Requirements

### Requirement: Agent shall implement core loop pattern from architecture

**Priority**: Critical
**Rationale**: This IS the agent - everything else supports this loop

The Agent MUST implement the core loop pattern:

```
while true:
    response = model(messages, tools)
    if response.stop_reason != "tool_use":
        return response.text
    results = execute(response.tool_calls)
    messages.append(results)
```

The Agent.executeTurn() method SHALL:
1. Add user message to conversation history
2. Call API with current messages and tools
3. Process streaming response chunks
4. On tool_use finish reason: execute tools, append results, call API again
5. On stop finish reason: emit completion event
6. Continue looping until natural stop

#### Scenario: Complete conversation turn

```zig
var agent = try Agent.init(allocator, &api_client, &tools, event_handler);
defer agent.deinit();

try agent.executeTurn("Read the file README.md");

// Agent loop completes:
// 1. Sends user message to API
// 2. Model requests read_file tool
// 3. Executes read_file
// 4. Sends tool result to API
// 5. Model generates final response
// 6. Emits completion event

try testing.expect(agent.conversation.messages.items.len >= 4);
// [user message, assistant tool_call, tool result, assistant response]
```

---

### Requirement: Agent shall maintain conversation history

**Priority**: Critical
**Rationale**: Multi-turn conversations require message history

The Agent SHALL:
- Store all messages in chronological order
- Include: user messages, assistant messages, tool results
- Serialize messages to OpenRouter format when calling API
- Preserve message history across turns
- Allow clearing history (for new conversation)

#### Scenario: Multi-turn conversation

```zig
try agent.executeTurn("Hello");
// After turn 1: [user: "Hello", assistant: "Hi there!"]

try agent.executeTurn("What's 2+2?");
// After turn 2: [...previous..., user: "What's 2+2?", assistant: "4"]

try testing.expectEqual(@as(usize, 4), agent.conversation.messages.items.len);
```

---

### Requirement: Agent shall emit events for UI updates

**Priority**: Critical
**Rationale**: Event-driven architecture from interface-design.md

The Agent SHALL emit AgentUpdate events:
- `.message_chunk` for each content delta from API
- `.tool_call` when model requests tool execution
- `.tool_result` after tool completes
- `.completion` when turn finishes
- `.error` on failures
- `.memory_warning` when RSS exceeds 40MB

Events MUST be emitted via callback function pointer.

#### Scenario: Event emission during turn

```zig
var events = std.ArrayList(AgentUpdate).init(allocator);
defer events.deinit();

const handler = struct {
    fn handle(event: AgentUpdate, ctx: *anyopaque) void {
        const list = @as(*std.ArrayList(AgentUpdate), @ptrCast(@alignCast(ctx)));
        list.append(event) catch unreachable;
    }
}.handle;

var agent = try Agent.init(allocator, &api_client, &tools, handler, &events);

try agent.executeTurn("Read config.json");

// Verify events were emitted
var has_tool_call = false;
var has_tool_result = false;
var has_completion = false;

for (events.items) |event| {
    switch (event) {
        .tool_call => has_tool_call = true,
        .tool_result => has_tool_result = true,
        .completion => has_completion = true,
        else => {},
    }
}

try testing.expect(has_tool_call);
try testing.expect(has_tool_result);
try testing.expect(has_completion);
```

---

### Requirement: Agent shall execute tools when requested by model

**Priority**: Critical
**Rationale**: Tool use is essential for agent functionality

When API response has finish_reason="tool_calls", the Agent SHALL:
- Extract tool call ID, name, and arguments
- Look up tool in registry by name
- Parse arguments JSON
- Execute tool
- Capture result (success, output, error)
- Format result as tool message
- Append to conversation
- Call API again with tool results

#### Scenario: Tool execution pipeline

```zig
// Model requests: read_file with path="/etc/hosts"
// (simulated via mock API client)

try agent.executeTurn("What's in /etc/hosts?");

// Agent should have:
// 1. Called API
// 2. Received tool_call for read_file
// 3. Executed read_file("/etc/hosts")
// 4. Appended tool result to messages
// 5. Called API again with result
// 6. Received final response

const messages = agent.conversation.messages.items;
var found_tool_result = false;

for (messages) |msg| {
    if (msg.role == .tool) {
        found_tool_result = true;
        try testing.expect(msg.content.len > 0); // Has file contents
    }
}

try testing.expect(found_tool_result);
```

---

### Requirement: Agent shall handle errors without crashing

**Priority**: High
**Rationale**: Robustness for constrained device

Error handling SHALL:
- Catch API errors (network, auth, rate limit)
- Catch tool execution errors (file not found, etc.)
- Emit error events with descriptive messages
- Not crash or leak memory on errors
- Return errors to caller for handling

#### Scenario: Handle tool execution error

```zig
try agent.executeTurn("Read /nonexistent/file.txt");

// Tool execution fails (file not found)
// Agent should:
// 1. Catch error
// 2. Create ToolResult with success=false
// 3. Send error to model
// 4. Model sees error and responds appropriately

var found_error_in_messages = false;
for (agent.conversation.messages.items) |msg| {
    if (msg.role == .tool and std.mem.indexOf(u8, msg.content, "not found") != null) {
        found_error_in_messages = true;
    }
}

try testing.expect(found_error_in_messages);
```

---

### Requirement: Agent shall use arena allocators for request-scoped memory

**Priority**: High
**Rationale**: Memory efficiency on constrained device

Memory management SHALL:
- Use GPA for Agent struct and persistent state
- Use ArenaAllocator for each turn (freed after completion)
- Free streaming chunks immediately after processing
- Target <50MB peak RAM during conversation

#### Scenario: Memory cleanup after turn

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    const leaked = gpa.deinit();
    try testing.expect(leaked == .ok);
}

var agent = try Agent.init(gpa.allocator(), ...);
defer agent.deinit();

try agent.executeTurn("Hello");
// Arena for turn 1 is freed

try agent.executeTurn("Goodbye");
// Arena for turn 2 is freed

// No leaks detected by GPA
```

---

### Requirement: Agent shall monitor memory and protect against OOM

**Priority**: High
**Rationale**: N900 has limited RAM (256MB shared) with no effective swap

The Agent MUST implement memory protection:
- Monitor RSS (resident set size) before each turn
- Warn user when RSS exceeds 40MB
- Refuse new input when RSS exceeds 45MB
- Emit `.memory_warning` event when approaching limit

Memory thresholds:
- Normal operation: RSS < 40MB
- Warning zone: 40MB ≤ RSS < 45MB (warn user, continue)
- Refusal zone: RSS ≥ 45MB (refuse input, emit error)

#### Scenario: Warn user at 40MB

```zig
// Simulate high memory usage
agent.setMockRSS(41 * 1024 * 1024); // 41MB

try agent.executeTurn("Hello");

// Should emit warning event but continue
var found_warning = false;
for (events.items) |event| {
    if (event == .memory_warning) found_warning = true;
}
try testing.expect(found_warning);

// Turn should still complete
try testing.expect(agent.conversation.messages.items.len > 0);
```

#### Scenario: Refuse input at 45MB

```zig
// Simulate critical memory usage
agent.setMockRSS(46 * 1024 * 1024); // 46MB

const result = agent.executeTurn("Hello");

// Should return error, not process turn
try testing.expectError(error.MemoryLimitExceeded, result);
```

---

## Non-Requirements (Out of Scope)

- TodoWrite/planning tool (v2)
- Subagent spawning (v2+)
- Concurrent turns (v1: sequential only)
- Conversation persistence (v1: in-memory only)
- Context window management (v2: assume fits in context)
- Temperature/top_p parameters (v1: use API defaults)

## Dependencies

- **Requires**: `api-client`, `tool-system`, `project-structure`
- **Provides**: Agent orchestration for `terminal-ui`

## Testing Strategy

**Unit Tests**:
- Message management (add, retrieve, clear)
- Event emission
- Error handling

**Integration Tests**:
- Full turn with mock API client
- Tool execution pipeline
- Multi-turn conversation

**Manual Tests**:
- Real API interaction
- Memory leak detection

## Related Specs

- `api-client` - API communication
- `tool-system` - Tool execution
- `terminal-ui` - Event consumption

## References

- [architecture.md](../../../../docs/concepts/architecture.md#core-agent-loop)
- [interface-design.md](../../../../docs/concepts/interface-design.md#interface-1-agentinterface-core--ui)
- [acp-patterns.md](../../../../docs/concepts/acp-patterns.md#pattern-1-streaming-update-enumeration)

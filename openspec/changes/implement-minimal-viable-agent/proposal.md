# Proposal: Implement Minimal Viable Agent (v1)

**Change ID**: `implement-minimal-viable-agent`
**Status**: Draft
**Created**: 2026-01-15

## Summary

Implement the foundational v1 system for zig-agent: a minimal but complete coding agent that proves the core architecture. This includes the basic agent loop, OpenRouter API integration, event-driven terminal UI with termbox2 + libxev, and a single tool to validate the execution pipeline.

## Target Users

**Primary**: Developers with resource-constrained devices who want AI coding assistance
- Nokia N900 owners (retrocomputing enthusiasts, embedded developers)
- Raspberry Pi Zero users
- Developers working over SSH on remote servers with limited resources
- Users who want fast startup and low memory footprint

**Secondary**: Template/reference for embedded AI applications
- IoT developers exploring on-device AI agents
- Researchers studying efficient LLM client implementations
- Developers building AI tools for edge devices

**Use Cases**:
1. Quick code questions while SSH'd into a remote server
2. File reading and explanation on memory-constrained devices
3. Proof-of-concept for embedded AI coding assistants
4. Learning resource for Zig + LLM integration

## Motivation

The project currently has comprehensive documentation but no implementation. This change establishes the working foundation that future features will build upon. The scope is intentionally minimal to:

1. **Validate the architecture** - Prove the event-driven design from interface-design.md works in practice
2. **Test library integration** - Ensure termbox2 and libxev work together correctly on ARM
3. **Prove the core loop** - Implement the fundamental "model calls tools, we execute" pattern
4. **Enable iteration** - Create a working baseline for adding features incrementally

## Goals

### Primary Goals
- ✅ Call OpenRouter API successfully with streaming responses
- ✅ Implement core agent loop (model → tool execution → model)
- ✅ Event-driven UI with termbox2 rendering and libxev event loop
- ✅ Execute at least one tool (read_file) to prove tool pipeline
- ✅ Meet basic performance targets (<50MB RAM, <500ms startup)

### Non-Goals (Deferred to v2+)
- ❌ TodoWrite/planning system (v2)
- ❌ Subagents (v2+)
- ❌ Full tool suite (v2 - just read_file for v1)
- ❌ Permission system (v2)
- ❌ Configuration files (v2)
- ❌ Advanced error recovery (v2)

## Scope

### In Scope

**1. Project Structure**
- build.zig with dependencies (termbox2, libxev)
- src/ layout following interface-design.md architecture:
  - `src/main.zig` - Entry point
  - `src/agent/` - Core agent logic
  - `src/api/` - OpenRouter client
  - `src/tools/` - Tool implementations
  - `src/ui/` - Terminal UI

**2. OpenRouter API Client** (`src/api/`)
- HTTP/1.1 client using std.http.Client
- POST /chat/completions endpoint
- SSE streaming parser
- Basic error handling (return errors, no retries yet)
- Support tool use in requests/responses

**3. Core Agent** (`src/agent/`)
- Agent loop implementation (while loop pattern from architecture.md)
- Conversation state (in-memory ArrayList of messages)
- Event emission (AgentUpdate union from ACP patterns)
- Tool dispatcher (call tools based on API responses)

**4. Terminal UI** (`src/ui/`)
- termbox2 integration for rendering
- libxev event loop for concurrent I/O (stdin + API streaming)
- Render streaming text chunks
- Basic layout (input area + output area)
- Handle Ctrl+C gracefully

**5. Tool System** (`src/tools/`)
- Tool interface/trait definition
- Single tool: `read_file` (absolute paths only per ACP patterns)
- Tool result format (success, output, error_message)

**6. Memory Management**
- GPA for top-level allocations
- Arena allocators for request-scoped memory
- Target: <50MB RAM during active conversation

### Out of Scope
- Multiple tools beyond read_file
- TodoWrite tool
- Subagent spawning
- Permission prompts
- Dynamic model selection (hardcode claude-sonnet-4.5)
- Prompt caching
- Retry logic
- Configuration file parsing

## Technical Approach

### Architecture Overview

```
┌────────────────┐
│  main.zig      │ Initialize, wire up components
└────────┬───────┘
         │
    ┌────┴────────────────────┐
    │                         │
┌───▼────────┐        ┌───────▼──────┐
│  UI Layer  │        │  Agent Core  │
│  (termbox2)│◄───────┤  (loop)      │
│  + libxev  │ events │              │
└────────────┘        └───┬──────┬───┘
                          │      │
                   ┌──────▼─┐  ┌─▼─────────┐
                   │ API    │  │ Tools     │
                   │ Client │  │ (read)    │
                   └────────┘  └───────────┘
```

### Component Breakdown

**1. Agent Core** (200-300 LOC)
```zig
const Agent = struct {
    allocator: Allocator,
    api_client: *APIClient,
    tools: *ToolRegistry,
    messages: ArrayList(Message),
    event_handler: *const fn(AgentUpdate) void,

    pub fn executeTurn(self: *Agent, user_input: []const u8) !void {
        // Add user message
        // Call API with streaming
        // On tool_use: execute tools, append results, call API again
        // On stop: emit completion event
    }
};
```

**2. API Client** (300-400 LOC)
```zig
const APIClient = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    api_key: []const u8,
    base_url: []const u8 = "https://openrouter.ai/api/v1",
    model: []const u8 = "anthropic/claude-sonnet-4.5",

    pub fn streamChatCompletion(
        self: *APIClient,
        messages: []const Message,
        tools: []const ToolDef,
        callback: *const fn(StreamChunk) void,
    ) !void {
        // Build JSON request
        // POST to /chat/completions with stream: true
        // Parse SSE lines
        // Call callback for each chunk
    }
};
```

**3. Terminal UI** (400-500 LOC)
```zig
const TerminalUI = struct {
    tb: *termbox.Termbox,
    loop: xev.Loop,
    agent: *Agent,
    output_buffer: ArrayList(u8),

    pub fn run(self: *TerminalUI) !void {
        // Initialize termbox2
        // Setup libxev watchers (stdin, signals)
        // Handle user input -> agent.executeTurn()
        // Handle agent events -> render to termbox
        // Run event loop
    }

    fn handleAgentUpdate(update: AgentUpdate) void {
        // Switch on update type, render appropriately
    }
};
```

**4. Tool System** (100-150 LOC)
```zig
const Tool = struct {
    name: []const u8,
    description: []const u8,
    execute: *const fn(Allocator, std.json.Value) anyerror!ToolResult,
};

const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,
};

// read_file tool implementation
fn executeReadFile(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    // Validate absolute path
    // Read file with size limit
    // Return result
}
```

### Dependencies

**build.zig.zon:**
```zig
.dependencies = .{
    .termbox2 = .{
        .url = "https://github.com/termbox/termbox2/archive/refs/tags/v2.0.0.tar.gz",
        // Or use system package
    },
    .libxev = .{
        .url = "https://github.com/mitchellh/libxev/archive/<hash>.tar.gz",
        .hash = "...",
    },
},
```

### Error Handling Strategy

**v1 Simplifications:**
- API errors: Return error, log to stderr, exit cleanly
- Tool errors: Return ToolResult with success=false, let model see error
- Parse errors: Return error, don't crash
- No retries, no sophisticated error recovery (v2)

### Testing Strategy

**Manual Testing Checklist:**
1. Binary compiles for x86_64 and armv7l
2. Startup time <500ms
3. Memory usage <50MB during conversation
4. Can send message to OpenRouter and get response
5. Streaming text renders in terminal
6. read_file tool executes and returns content
7. Ctrl+C exits gracefully

**Automated Tests (Basic):**
- Unit test: SSE parser with mock data
- Unit test: Message serialization to JSON
- Unit test: read_file with test fixtures

## Implementation Phases

**Realistic Timeline**: 10-14 days (with 30% buffer for unknowns)

### Phase 1: Project Skeleton (Day 1-2)
- Create build.zig with dependencies
- Set up src/ directory structure
- Add stub files for each module
- Verify builds and links
- Write README.md and BUILD.md incrementally

### Phase 2: API Client (Day 3-5)
- Implement HTTP client wrapper
- Implement SSE streaming parser (16KB buffer)
- Add basic request/response types
- Add test cases for interrupted streaming / malformed JSON
- Manual test: Call OpenRouter, print response

### Phase 3: Agent Core (Day 5-7)
- Implement Agent struct
- Implement agent loop
- Add conversation state management
- Add basic RSS monitoring (warn if approaching 40MB)
- Wire up API client
- Update USAGE.md with examples

### Phase 4: Tool System (Day 7-8)
- Define Tool interface
- Implement read_file tool
- Add tool registry
- Test tool execution in agent loop

### Phase 5: Terminal UI (Day 8-11)
- Integrate termbox2
- Integrate libxev event loop (verify it sleeps when idle for battery)
- Implement basic rendering
- Wire up agent event handling
- Test full round-trip

### Phase 6: Integration & Validation (Day 11-14)
- End-to-end testing
- Memory profiling
- Performance validation
- ARM cross-compilation and QEMU testing
- **Dogfood session**: Complete a real coding task with zig-agent
- Finalize documentation

## Success Criteria

### Technical Criteria
- [ ] Binary builds successfully for x86_64 and armv7l
- [ ] Cold startup time <500ms on x86_64 (measure on ARM via QEMU)
- [ ] Memory usage <50MB during active conversation
- [ ] Can send a message and receive streamed response from OpenRouter
- [ ] read_file tool successfully executes and returns content
- [ ] Terminal UI renders streaming text without flicker
- [ ] Ctrl+C exits cleanly without hanging
- [ ] Complete agent loop: user input → API call → tool execution → API call → response
- [ ] No memory leaks (GPA validation)
- [ ] libxev sleeps when idle (not spinning CPU)

### User Validation Criteria
- [ ] **Dogfood session**: Successfully complete a real coding task
  - Example: "Read the README and explain what this project does"
  - Example: "Read main.zig and suggest improvements"
- [ ] Works correctly over SSH connection
- [ ] Documentation is sufficient for new user to build and run

## Risks & Mitigations

### High Risk

**Risk**: termbox2 C library integration complexity
- termbox2 is a C library; Zig-C ABI requires careful handling
**Mitigation**:
- Start termbox2 integration early (T2)
- **Fallback**: Raw ANSI escape sequences if termbox2 fails (architecture supports swapping)
- Document fallback implementation path

**Risk**: OOM on constrained devices (no swap, limited RAM)
- If memory exceeds budget, process gets OOM-killed
- No graceful degradation possible
**Mitigation**:
- Add RSS monitoring - warn user if approaching 40MB
- Refuse new input if at 45MB (soft limit)
- Profile memory continuously during development

### Medium Risk

**Risk**: SSE parsing edge cases / interrupted streams
- Claude tool call arguments can exceed expectations
- Connection drops mid-JSON are possible
**Mitigation**:
- Use 16KB buffer (not 4KB) for SSE lines
- Add explicit test cases for truncated/malformed JSON
- Graceful error handling, don't crash on parse failures

**Risk**: Battery drain from busy-waiting
- Constrained devices may be battery-powered
- Spinning event loop would drain battery fast
**Mitigation**:
- Verify libxev truly sleeps when idle (not spinning)
- Add to performance validation checklist

### Low Risk

**Risk**: Memory usage exceeds 50MB during normal operation
**Mitigation**: Profile early, use arena allocators aggressively, set soft limits

**Risk**: Static build issues
**Mitigation**: Static musl builds are well-supported by Zig; cross-compile from day 1

## Open Questions (Resolved)

1. **JSON library**: Use std.json or a faster alternative?
   - **Decision**: Start with std.json, optimize later if needed
   - **Rationale**: std.json is sufficient for our throughput needs (>10MB/s), adding dependencies increases risk

2. **HTTP/2 vs HTTP/1.1**: Does OpenRouter benefit from HTTP/2?
   - **Decision**: HTTP/1.1 (std.http.Client default)
   - **Rationale**: Single connection, streaming - HTTP/2 multiplexing provides no benefit

3. **termbox2 vs raw ANSI**: Should we fallback to raw ANSI if termbox2 is problematic?
   - **Decision**: Commit to termbox2 for v1, but document fallback path
   - **Rationale**: termbox2 provides consistent cross-terminal behavior; raw ANSI is fallback if C integration fails on ARM

4. **Model hardcoding**: Why claude-sonnet-4.5?
   - **Decision**: Hardcode anthropic/claude-sonnet-4.5 in v1
   - **Rationale**: Best balance of capability vs cost for coding tasks. Model selection adds complexity without v1 value.
   - **v2**: Add model selection (Haiku for simple queries, Opus for complex reasoning)

5. **Retry logic**: Should v1 have retries?
   - **Decision**: No retries in v1, add in v1.1
   - **Rationale**: Simplifies initial implementation. v1.1 adds exponential backoff (3 retries: 1s/2s/4s)

## v2 Roadmap

Features prioritized by user value:

| Priority | Feature | Rationale |
|----------|---------|-----------|
| **P0** | write_file, bash tools | Core coding functionality |
| **P0** | Retry with backoff | Reliability (429/503 errors common) |
| **P1** | TodoWrite planning | Complex multi-step task completion |
| **P1** | Context window management | Prune/summarize at 80% capacity |
| **P2** | Model selection | Cost optimization (Haiku/Sonnet/Opus) |
| **P2** | Subagents | Large codebase exploration |
| **P3** | Configuration file | Power user customization |
| **P3** | Permission system | Security for destructive operations |

## Related Documentation

- [architecture.md](../../docs/concepts/architecture.md) - Overall design
- [interface-design.md](../../docs/concepts/interface-design.md) - Component interfaces
- [openrouter-api.md](../../docs/concepts/openrouter-api.md) - API details
- [acp-patterns.md](../../docs/concepts/acp-patterns.md) - Design patterns
- [performance-constraints.md](../../docs/concepts/performance-constraints.md) - Targets

## Next Steps

After approval:
1. Create detailed tasks.md
2. Create spec deltas for each capability
3. Begin Phase 1 implementation

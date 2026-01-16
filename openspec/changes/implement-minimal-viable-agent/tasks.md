# Tasks: Implement Minimal Viable Agent

**Change ID**: `implement-minimal-viable-agent`

This document breaks down the implementation into small, verifiable tasks ordered for incremental progress.

## Timeline

**Realistic estimate**: 10-14 days (55-65 hours with 30% buffer)
**Team size**: 1 developer

## Task Ordering Principles

1. **Foundation first**: Build system → Core types → Components
2. **Vertical slices**: Each task delivers testable functionality
3. **Dependencies clear**: Tasks marked with `[Depends: T#]`
4. **Parallel paths**: Independent tasks can run concurrently
5. **ARM validation early**: Catch platform issues before heavy investment
6. **Documentation incremental**: Write docs as you go, not at the end

## Phase 1: Project Foundation (Day 1)

### T1: Initialize Zig Project Structure
**Estimate**: 1 hour
**Parallel**: Can run standalone

- [x] Create `build.zig` with basic configuration
- [x] Set up `build.zig.zon` with project metadata
- [x] Create src/ directory structure:
  ```
  src/
  ├── main.zig
  ├── agent/
  │   └── agent.zig
  ├── api/
  │   ├── client.zig
  │   └── types.zig
  ├── tools/
  │   ├── registry.zig
  │   └── read_file.zig
  └── ui/
      └── terminal.zig
  ```
- [x] Add stub files with module docstrings
- [x] Verify `zig build` succeeds (even with empty mains)

**Validation**: `zig build` completes without errors

---

### T2: Add termbox2 Dependency
**Estimate**: 2 hours
**Parallel**: Can run standalone
**Risk**: High (C library integration)

- [x] Add termbox2 to build.zig as system library OR vendored C source
- [x] Create minimal Zig bindings in `src/ui/termbox.zig`:
  - tb_init(), tb_shutdown()
  - tb_clear(), tb_present()
  - tb_print(), tb_put_cell()
  - tb_poll_event()
- [x] Write test program that initializes termbox2 and renders "Hello"
- [x] Verify works on x86_64 (QEMU ARM test in T15)

**Validation**: Test program displays "Hello" in terminal

---

### T3: Add libxev Dependency
**Estimate**: 2 hours
**Parallel**: Can run standalone
**Risk**: Medium (new library)

- [x] Add libxev to build.zig.zon dependencies
- [x] Create minimal test using xev.Loop:
  - Initialize loop
  - Add timer callback (print every 1 second)
  - Run loop
  - Clean shutdown
- [x] Verify builds and runs

**Validation**: Test program prints timestamps every second via libxev

---

## Phase 2: API Client (Day 2-3)

### T4: Define API Request/Response Types
**Estimate**: 2 hours
**Depends**: T1

- [x] Create `src/api/types.zig`
- [x] Define core types:
  - `Message` struct (role, content)
  - `ToolDefinition` struct (name, description, parameters)
  - `ChatCompletionRequest` struct
  - `ChatCompletionChunk` struct (for SSE streaming)
  - `ToolCall` struct (id, function name, arguments)
  - [x] Add JSON serialization annotations
  - [x] Write unit test for Message serialization

**Validation**: Unit test serializes Message to correct JSON

---

### T5: Implement HTTP Request Builder
**Estimate**: 3 hours
**Depends**: T4

- [x] Create `src/api/client.zig`
- [x] Implement `APIClient` struct with:
  - allocator
  - std.http.Client instance
  - api_key: []const u8
  - base_url: []const u8
  - model: []const u8
- [x] Implement `buildChatRequest()` function:
  - Takes messages, tools
  - Returns JSON string
  - Sets proper headers (Authorization, Content-Type)
- [x] Write unit test with mock data

**Validation**: Unit test produces valid JSON request

---

### T6: Implement SSE Streaming Parser
**Estimate**: 4 hours
**Depends**: T4
**Risk**: Medium (parsing complexity)

- [x] Create `parseSSEStream()` function in `src/api/client.zig`
- [x] Parse SSE format:
  - Skip empty lines
  - Skip comment lines (start with `:`)
  - Parse `data:` lines
  - Handle `data: [DONE]` terminator
- [x] Parse JSON chunks into `ChatCompletionChunk`
- [x] Handle streaming deltas (content, tool_calls)
- [x] Write unit tests with mock SSE data:
  - Simple text streaming
  - Tool call streaming
  - Error in stream
  - Connection termination

**Validation**: All SSE parsing unit tests pass

---

### T7: Implement streamChatCompletion Method
**Estimate**: 5 hours
**Depends**: T5, T6
**Risk**: High (network + parsing together)

- [x] Implement `APIClient.streamChatCompletion()`:
  - POST to /chat/completions
  - Stream response body
  - Parse SSE chunks
  - Call callback for each chunk
  - Handle errors gracefully
- [x] Add basic error handling:
  - HTTP errors (4xx, 5xx)
  - Parse errors
  - Network errors
- [x] Manual test: Call real OpenRouter API with API key on x86_64
- [x] Verify streaming chunks arrive correctly

**Validation**: Manual test successfully streams response from OpenRouter

---

## Phase 3: Tool System (Day 4)

### T8: Define Tool Interface
**Estimate**: 1 hour
**Depends**: T1

- [x] Create `src/tools/registry.zig`
- [x] Define `Tool` struct:
  - name: []const u8
  - description: []const u8
  - parameters: ToolParameters (JSON schema)
  - execute: function pointer
- [x] Define `ToolResult` struct:
  - success: bool
  - output: []const u8
  - error_message: ?[]const u8
- [x] Create `ToolRegistry` struct (ArrayList of Tool)

**Validation**: Code compiles, types are well-defined

---

### T9: Implement read_file Tool
**Estimate**: 2 hours
**Depends**: T8

- [x] Create `src/tools/read_file.zig`
- [x] Implement `executeReadFile()` function:
  - Parse args JSON for "path"
  - Validate path is absolute (per ACP patterns)
  - Read file contents (max 1MB)
  - Return ToolResult with content or error
- [x] Add error handling:
  - File not found
  - Permission denied
  - File too large
  - Not absolute path
- [x] Write unit tests with test fixtures

**Validation**: Unit tests pass for success and error cases

---

### T10: Wire Tool Registry to API Client
**Estimate**: 1 hour
**Depends**: T8, T9

- [x] Update `APIClient` to convert `Tool[]` to OpenRouter tool definitions
- [x] Format tool definitions in OpenAI function calling format
- [x] Manual test: Send request with read_file tool definition
- [x] Verify OpenRouter accepts tool definition

**Validation**: OpenRouter API accepts request with tool definitions

---

## Phase 4: Agent Core (Day 5)

### T11: Define AgentUpdate Event Type
**Estimate**: 1 hour
**Depends**: T1

- [x] Create `src/agent/types.zig`
- [x] Define `AgentUpdate` union (from ACP patterns):
  - thought
  - message_chunk
  - tool_call
  - tool_result
  - completion
- [x] Add helper functions for creating each variant

**Validation**: Code compiles, event types are clear

---

### T12: Implement Conversation State
**Estimate**: 2 hours
**Depends**: T4, T11

- [x] Create `ConversationState` struct in `src/agent/agent.zig`:
  - messages: ArrayList(Message)
  - addMessage()
  - getHistory()
  - clear()
- [x] Write unit tests for message management

**Validation**: Unit tests pass for adding/retrieving messages

---

### T13: Implement Agent Core Loop
**Estimate**: 5 hours
**Depends**: T7, T10, T12
**Risk**: High (integrates multiple components)

- [x] Create `Agent` struct:
  - allocator
  - api_client: *APIClient
  - tools: *ToolRegistry
  - conversation: ConversationState
  - event_handler: callback function
- [x] Implement `executeTurn()`:
  1. Add user message to conversation
  2. Emit thinking event
  3. Call API with streaming
  4. On content delta: emit message_chunk event
  5. On tool_use:
     - Emit tool_call event
     - Execute tool
     - Emit tool_result event
     - Add results to conversation
     - Call API again (LOOP)
  6. On stop: emit completion event
- [x] Handle errors by emitting error events
- [x] Write integration test with mock API client

**Validation**: Integration test completes full turn successfully

---

### T13.5: Add Memory Protection
**Estimate**: 2 hours
**Depends**: T13
**Risk**: Medium (OS-specific)

Add basic OOM protection for constrained devices.

- [x] Implement `getCurrentRSS()` function (read /proc/self/statm on Linux)
- [x] Add RSS check before each turn:
  - Warn user if RSS > 40MB
  - Refuse new input if RSS > 45MB (emit error event)
- [x] Add memory_warning event type to AgentUpdate
- [x] Test with artificially inflated memory usage

**Validation**: Agent warns when memory is high, refuses input at 45MB

---

## Phase 5: Terminal UI (Day 6)

### T14: Implement Basic termbox2 Rendering
**Estimate**: 3 hours
**Depends**: T2, T11

- [ ] Create `TerminalUI` struct in `src/ui/terminal.zig`:
  - tb: termbox handle
  - output_lines: ArrayList([]const u8)
  - renderOutput()
  - renderInputLine()
- [ ] Implement `handleAgentUpdate()`:
  - Switch on AgentUpdate type
  - Append to output_lines
  - Call renderOutput()
- [ ] Implement `renderOutput()`:
  - Clear screen
  - Draw output lines (scroll if needed)
  - Draw input prompt at bottom
  - Present buffer
- [ ] Manual test: Render mock agent updates

**Validation**: Terminal displays agent updates correctly

---

### T15: Integrate libxev Event Loop
**Estimate**: 4 hours
**Depends**: T3, T14
**Risk**: High (complex integration)

- [ ] Add xev.Loop to `TerminalUI`
- [ ] Set up stdin watcher:
  - Read user input
  - On Enter: call agent.executeTurn()
  - On Ctrl+C: exit loop
- [ ] Set up signal handler for graceful shutdown
- [ ] Ensure termbox2 rendering doesn't block event loop
- [ ] Manual test: Type input, see it processed by agent

**Validation**: Can type input and trigger agent turns via libxev

---

### T16: Wire Agent Events to UI
**Estimate**: 2 hours
**Depends**: T13, T14

- [ ] Pass TerminalUI.handleAgentUpdate as event_handler to Agent
- [ ] Ensure updates render in real-time during streaming
- [ ] Test with real OpenRouter API call
- [ ] Verify no flicker or blocking

**Validation**: Streaming API response renders smoothly in terminal

---

## Phase 6: Integration & Main (Day 7)

### T17: Implement main.zig
**Estimate**: 2 hours
**Depends**: T13, T15

- [x] Read OPENROUTER_API_KEY from environment
- [x] Initialize allocator (GPA for v1)
- [x] Initialize APIClient with API key
- [x] Initialize ToolRegistry with read_file
- [x] Initialize Agent
- [x] Initialize TerminalUI
- [x] Run UI event loop
- [x] Clean shutdown on exit

**Validation**: Binary runs end-to-end

---

### T18: End-to-End Testing
**Estimate**: 3 hours
**Depends**: T17

- [x] Test complete flow:
  1. Start agent
  2. Type: "Read the file README.md"
  3. Verify model calls read_file tool
  4. Verify file content returned
  5. Verify model generates response
- [x] Test edge cases:
  - File doesn't exist
  - Network error
  - Ctrl+C during streaming
  - Multiple turns
- [x] Document any issues found

**Validation**: Complete conversation turn works end-to-end

---

### T19: Memory Profiling
**Estimate**: 2 hours
**Depends**: T18

- [x] Run agent with Zig's GPA leak detection enabled
- [x] Monitor RSS with `ps` during conversation
- [x] Verify <50MB peak usage
- [x] Profile with heaptrack if available
- [x] Fix any leaks or excessive allocations

**Validation**: Memory usage <50MB, no leaks detected

---

### T20: ARM Cross-Compilation Test
**Estimate**: 2 hours
**Depends**: T18

- [x] Cross-compile for armv7l target:
  ```
  zig build -Dtarget=arm-linux-musleabihf
  ```
- [x] Test in QEMU user mode:
  ```
  qemu-arm-static ./zig-out/bin/zig-agent
  ```
- [x] Verify basic functionality works
- [x] Document any ARM-specific issues

**Validation**: Binary runs in QEMU ARM emulation

---

### T21: Performance Validation
**Estimate**: 2 hours
**Depends**: T18, T19, T20

- [ ] Measure cold start time (time to first prompt)
- [ ] Measure conversation turn latency
- [ ] Verify <500ms startup target
- [ ] Verify libxev sleeps when idle (not spinning CPU):
  - Run agent, leave idle for 30 seconds
  - Check CPU usage with `top` or `htop`
  - Should be near 0% when waiting for input
- [ ] Document actual measurements

**Validation**: Startup time <500ms on x86_64, idle CPU <1%

---

### T22: Update Documentation
**Estimate**: 1 hour (most docs written incrementally during implementation)
**Depends**: T21

- [ ] Review and finalize docs/README.md
- [ ] Review BUILD.md (started in T1)
- [ ] Review USAGE.md (started in T17)
- [ ] Ensure environment variables documented (OPENROUTER_API_KEY)
- [ ] Update openspec/project.md with project details

**Validation**: Documentation is accurate and complete

---

### T23: Dogfood Session
**Estimate**: 2 hours
**Depends**: T22

Complete real coding tasks with zig-agent to validate user experience.

- [ ] Task 1: "Read the README.md and summarize what this project does"
  - Verify model calls read_file
  - Verify response is coherent
- [ ] Task 2: "Read src/main.zig and explain the main function"
  - Verify multi-turn conversation works
- [ ] Task 3: "What files are in the src/api/ directory? Read one and explain it"
  - Verify model can reason about filesystem
- [ ] Document any UX issues discovered
- [ ] Document any bugs found

**Validation**: All three tasks complete successfully without crashes
**Estimate**: 2 hours
**Depends**: T21

- [ ] Update docs/README.md with v1 status
- [ ] Add BUILD.md with compilation instructions
- [ ] Add USAGE.md with basic usage examples
- [ ] Document environment variables (OPENROUTER_API_KEY)
- [ ] Update openspec/project.md with project details

**Validation**: Documentation is accurate and helpful

---

## Parallel Work Opportunities

Tasks that can run in parallel:

**Group A** (Foundation):
- T1 (Project Structure)
- T2 (termbox2)
- T3 (libxev)

**Group B** (API):
- T4, T5, T6, T7 (API Client)

**Group C** (Tools):
- T8, T9, T10 (Tool System)

**Group D** (Agent):
- T11, T12 (Agent State) - Can overlap with Group B/C

**Sequential** (Integration):
- T13 → T13.5 → T14 → T15 → T16 → T17 → T18 → T19 → T20 → T21 → T22 → T23

## Risk Mitigation Tasks

**High-Risk Tasks** (need extra attention):
- T2 (termbox2 C integration)
- T7 (OpenRouter streaming)
- T13 (Agent loop)
- T15 (libxev integration)
- T20 (ARM compilation)

**Mitigation Strategy**:
- Start high-risk tasks early
- Add extra time buffers
- Have fallback plans (e.g., raw ANSI if termbox2 fails)

## Success Criteria Checklist

After completing all tasks, verify:

### Technical
- [ ] Binary builds for x86_64 and armv7l (static musl)
- [ ] Startup time <500ms
- [ ] Memory usage <50MB peak
- [ ] Memory warning at 40MB, refusal at 45MB
- [ ] Can send message to OpenRouter
- [ ] Streaming response renders correctly
- [ ] read_file tool executes successfully
- [ ] Ctrl+C exits cleanly
- [ ] No memory leaks (GPA validation)
- [ ] libxev sleeps when idle (<1% CPU)

### User Experience
- [ ] Dogfood tasks complete successfully
- [ ] Works over SSH
- [ ] Documentation sufficient for new user

## Total Estimate

**Total effort**: ~55-65 hours across 24 tasks (including T13.5, T23)
**Calendar time**: 10-14 days (realistic with buffer)
**Team size**: 1 developer

## Notes

- Estimates include 30% buffer for unexpected issues
- Library integration (termbox2, libxev) is highest risk
- Core algorithm (agent loop, API client) is well-understood from docs
- Documentation written incrementally to avoid end-of-project crunch
- Static musl builds assumed to work across architectures

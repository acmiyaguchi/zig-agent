# Implementation Tasks: Agent v2

**Change ID**: `implement-agent-v2`

## Overview

Implementation organized into 4 phases. Complete each section sequentially; mark items `[x]` when finished.

**Realistic Estimate**: 5-7 days (simpler than custom tools approach!)

---

## Phase 1: Tool Wrappers (2-3 days)

### 1.1 Shared Subprocess Infrastructure
- [ ] 1.1.1 Create `src/tools/subprocess.zig` module
- [ ] 1.1.2 Implement `execute(allocator, command, timeout, working_dir)` function
- [ ] 1.1.3 Use `std.process.Child.init()` to create subprocess
- [ ] 1.1.4 Configure subprocess with `/bin/sh -c` to support shell features
- [ ] 1.1.5 Set stdout_behavior = .Pipe and stderr_behavior = .Pipe
- [ ] 1.1.6 Implement `waitWithTimeout()` helper function
- [ ] 1.1.7 Capture stdout with `readToEndAlloc(allocator, 1MB)`
- [ ] 1.1.8 Capture stderr with `readToEndAlloc(allocator, 1MB)`
- [ ] 1.1.9 Combine stdout + stderr in output (separate with "--- stderr ---")
- [ ] 1.1.10 Add truncation warning if output exceeds 1MB
- [ ] 1.1.11 Capture exit code and set ToolResult.success appropriately
- [ ] 1.1.12 Return timeout error if command exceeds timeout

### 1.2 list_directory Tool (Read-Only)
- [ ] 1.2.1 Create `src/tools/list_directory.zig` module
- [ ] 1.2.2 Implement tool schema (path: string, recursive?: bool)
- [ ] 1.2.3 Implement `executeListDirectory()` function
- [ ] 1.2.4 Build shell command: `ls -la {path}` or `ls -laR {path}` if recursive
- [ ] 1.2.5 Call `subprocess.execute()` with 5s timeout
- [ ] 1.2.6 Return result to model
- [ ] 1.2.7 Add unit tests (simple listing, recursive, non-existent path)

### 1.3 search_files Tool (Read-Only)
- [ ] 1.3.1 Create `src/tools/search_files.zig` module
- [ ] 1.3.2 Implement tool schema (pattern: string, path: string)
- [ ] 1.3.3 Implement `executeSearchFiles()` function
- [ ] 1.3.4 Build shell command: `grep -rn '{pattern}' {path}`
- [ ] 1.3.5 Escape single quotes in pattern for shell safety
- [ ] 1.3.6 Call `subprocess.execute()` with 5s timeout
- [ ] 1.3.7 Return result to model
- [ ] 1.3.8 Add unit tests (pattern found, pattern not found, invalid path)

### 1.4 write_file Tool (Destructive)
- [ ] 1.4.1 Create `src/tools/write_file.zig` module
- [ ] 1.4.2 Implement tool schema (path: string, content: string)
- [ ] 1.4.3 Implement `executeWriteFile()` function
- [ ] 1.4.4 Build shell command: `cat > {path} <<'EOF'\n{content}\nEOF`
- [ ] 1.4.5 Call `subprocess.execute()` with 5s timeout
- [ ] 1.4.6 Return result to model
- [ ] 1.4.7 Add unit tests (create new file, overwrite existing, write to invalid path)

### 1.5 run_command Tool (Destructive)
- [ ] 1.5.1 Create `src/tools/run_command.zig` module
- [ ] 1.5.2 Implement tool schema (command: string, timeout?: int, working_dir?: string)
- [ ] 1.5.3 Implement `executeRunCommand()` function
- [ ] 1.5.4 Extract parameters (default timeout=5s)
- [ ] 1.5.5 Call `subprocess.execute()` with provided parameters
- [ ] 1.5.6 Return result to model
- [ ] 1.5.7 Add unit tests (successful command, failed command, timeout, working_dir)

### 1.6 Tool Registry Integration
- [ ] 1.6.1 Add `registerListDirectory()` method to ToolRegistry
- [ ] 1.6.2 Add `registerSearchFiles()` method to ToolRegistry
- [ ] 1.6.3 Add `registerWriteFile()` method to ToolRegistry
- [ ] 1.6.4 Add `registerRunCommand()` method to ToolRegistry
- [ ] 1.6.5 Call all registration methods in `ToolRegistry.init()`
- [ ] 1.6.6 Verify 5 tools in registry (read_file, list_directory, search_files, write_file, run_command)

---

## Phase 2: Confirmation UI (1 day)

### 2.1 Inline Y/n Confirmation
- [ ] 2.1.1 Add `requestConfirmation(tool_name: []const u8, args: std.json.Value) bool` to TerminalUI
- [ ] 2.1.2 Display inline prompt: "Execute <tool_name> <preview>? [Y/n] "
- [ ] 2.1.3 Format preview based on tool (write_file shows path, run_command shows command)
- [ ] 2.1.4 Handle keypresses (Y/y to confirm, N/n/Enter to deny)
- [ ] 2.1.5 Return boolean result to caller
- [ ] 2.1.6 Clear prompt line after response

### 2.2 Agent Integration
- [ ] 2.2.1 Add helper to identify destructive tools (write_file, run_command)
- [ ] 2.2.2 Before executing destructive tool: call confirmation prompt
- [ ] 2.2.3 Show tool name and relevant args to user in prompt
- [ ] 2.2.4 Only execute tool if user confirms (Y/y)
- [ ] 2.2.5 Return cancellation message to model if user denies
- [ ] 2.2.6 Ensure read-only tools (read_file, list_directory, search_files) skip confirmation

---

## Phase 3: Context Tracking (1-2 days)

### 3.1 Token Tracking Core
- [ ] 3.1.1 Add token counter fields to Agent struct:
         - `total_input_tokens: u32`
         - `total_output_tokens: u32`
- [ ] 3.1.2 Implement `updateTokens(input: u32, output: u32)` method
- [ ] 3.1.3 Accumulate tokens across turns (cumulative)

### 3.2 API Request & Response Changes
- [ ] 3.2.1 Add `stream_options: { include_usage: true }` to `ChatCompletionRequest` struct
- [ ] 3.2.2 Add `usage` field to `ChatCompletionChunk` struct (prompt_tokens, completion_tokens, total_tokens)
- [ ] 3.2.3 Add `.usage` variant to `StreamChunk` union for callback
- [ ] 3.2.4 Parse `usage` field from streaming response in `streamChatCompletion()`
- [ ] 3.2.5 Emit `.usage` via callback when present
- [ ] 3.2.6 Handle missing usage field gracefully (don't emit)

### 3.3 Terminal UI Status Line
- [ ] 3.3.1 Add `renderStatusLine()` function to TerminalUI
- [ ] 3.3.2 Display token count (e.g., "Tokens: 12.3K")
- [ ] 3.3.3 Render at bottom of screen (y = height - 1)
- [ ] 3.3.4 Update status line after each turn

---

## Phase 4: Integration & Testing (1 day)

### 4.1 End-to-End Scenario Testing
- [ ] 4.1.1 Scenario: List directory (no confirmation)
         - [ ] User asks agent to list current directory
         - [ ] Agent uses list_directory(path=".")
         - [ ] Tool executes immediately (no confirmation)
         - [ ] Output shows directory contents
- [ ] 4.1.2 Scenario: Search files (no confirmation)
         - [ ] User asks to find pattern in files
         - [ ] Agent uses search_files(pattern="foo", path=".")
         - [ ] Tool executes immediately (no confirmation)
         - [ ] Search results displayed
- [ ] 4.1.3 Scenario: Read file (no confirmation)
         - [ ] User asks agent to read a file
         - [ ] Agent uses read_file(path="/path/to/file")
         - [ ] Tool executes immediately (no confirmation)
         - [ ] File contents displayed
- [ ] 4.1.4 Scenario: Create new file (requires confirmation)
         - [ ] User asks agent to create a file
         - [ ] Agent uses write_file(path="test.txt", content="hello")
         - [ ] User sees prompt: "Execute write_file test.txt? [Y/n]"
         - [ ] User confirms with Y
         - [ ] File created successfully
- [ ] 4.1.5 Scenario: Run arbitrary command (requires confirmation)
         - [ ] User asks agent to run custom command
         - [ ] Agent uses run_command(command="echo 'test'")
         - [ ] User sees prompt: "Execute run_command echo 'test'? [Y/n]"
         - [ ] User confirms with Y
         - [ ] Command executes successfully
- [ ] 4.1.6 Scenario: Deny destructive operation
         - [ ] Agent proposes write_file or run_command
         - [ ] User denies with N
         - [ ] Operation NOT executed
         - [ ] Agent receives cancellation and continues
- [ ] 4.1.7 Scenario: Command timeout
         - [ ] Agent runs command that takes > timeout
         - [ ] User confirms with Y
         - [ ] Process killed after timeout
         - [ ] Timeout error returned to model

### 4.2 Performance Validation
- [ ] 4.2.1 Binary size: Verify <10MB
- [ ] 4.2.2 Memory usage: Run multi-command scenario, verify peak <55MB
- [ ] 4.2.3 Startup time: Measure cold start <500ms
- [ ] 4.2.4 Tool execution latency: Each command <100ms overhead (plus command time)

### 4.3 Cross-Platform Testing
- [ ] 4.3.1 Build for x86_64 linux
- [ ] 4.3.2 Build for armv7l (cross-compile)
- [ ] 4.3.3 Test on x86_64 (interactive session)
- [ ] 4.3.4 Verify /bin/sh exists on target systems

### 4.4 Final Checklist
- [ ] 4.4.1 All tasks marked complete
- [ ] 4.4.2 `zig build` succeeds without warnings
- [ ] 4.4.3 `zig build test` passes all tests
- [ ] 4.4.4 Manual end-to-end scenario completes successfully

---

## Summary of Files to Create/Modify

### New Files
- `src/tools/subprocess.zig` - Shared subprocess spawner
- `src/tools/list_directory.zig` - List directory tool
- `src/tools/search_files.zig` - Search files tool
- `src/tools/write_file.zig` - Write file tool
- `src/tools/run_command.zig` - General command escape hatch

### Modified Files
- `src/agent/agent.zig` - Add token tracking fields, destructive tool check
- `src/api/client.zig` - Add usage parsing
- `src/tools/registry.zig` - Add registration for 4 new tools
- `src/ui/terminal.zig` - Add status line, inline Y/n prompts

### Files Left Unchanged
- Core architecture stable from v1
- No changes to libxev or termbox2 integration
- `src/tools/read_file.zig` unchanged (keep existing tool)

---

## Estimation Breakdown

| Phase | Estimated Days | Actual | Status |
|-------|--------|--------|--------|
| 1. Subprocess Spawner | 2-3 | | Pending |
| 2. Confirmation UI | 1 | | Pending |
| 3. Context Tracking | 1-2 | | Pending |
| 4. Integration & Testing | 1 | | Pending |
| **TOTAL** | **5-7 days** | | Pending |

---

## Success Criteria Tracking

- [ ] All ~15 core tasks complete (checkboxes above)
- [ ] Binary <10MB
- [ ] Peak memory <55MB
- [ ] Startup <500ms
- [ ] End-to-end subprocess scenarios succeed
- [ ] User confirmation workflow verified
- [ ] Token tracking displays correctly

---

## Comparison with Original Design

**Original Design (Rejected)**:
- 72 tasks across 4 phases
- 7-10 days estimated
- ~1000 LOC for custom Zig tools
- 3 new tool modules with full Zig implementations

**New Design (This Proposal)**:
- ~40 tasks across 4 phases
- 5-7 days estimated
- ~300 LOC for tool wrappers + subprocess spawner
- 5 new tool modules (4 wrappers + 1 escape hatch)

**Savings**: ~32 fewer tasks, ~700 fewer LOC, 2-3 days faster, simpler implementation with zero friction for read-only ops!

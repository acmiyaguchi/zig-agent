# Implementation Tasks: Agent v2

**Change ID**: `implement-agent-v2`

## Overview

Implementation organized into 4 phases. Complete each section sequentially; mark items `[x]` when finished.

**Realistic Estimate**: 5-7 days (simpler than custom tools approach!)

---

## Phase 1: Tool Wrappers (2-3 days)

### 1.1 Shared Subprocess Infrastructure
- [x] 1.1.1 Create `src/tools/subprocess.zig` module
- [x] 1.1.2 Implement `execute(allocator, command, timeout, working_dir)` function
- [x] 1.1.3 Use `std.process.Child.init()` to create subprocess
- [x] 1.1.4 Configure subprocess with `/bin/sh -c` to support shell features
- [x] 1.1.5 Set stdout_behavior = .Pipe and stderr_behavior = .Pipe
- [x] 1.1.6 Implement `waitWithTimeout()` helper function
- [x] 1.1.7 Capture stdout with `readToEndAlloc(allocator, 1MB)`
- [x] 1.1.8 Capture stderr with `readToEndAlloc(allocator, 1MB)`
- [x] 1.1.9 Combine stdout + stderr in output (separate with "--- stderr ---")
- [x] 1.1.10 Add truncation warning if output exceeds 1MB
- [x] 1.1.11 Capture exit code and set ToolResult.success appropriately
- [x] 1.1.12 Return timeout error if command exceeds timeout

### 1.2 list_directory Tool (Read-Only)
- [x] 1.2.1 Create `src/tools/list_directory.zig` module
- [x] 1.2.2 Implement tool schema (path: string, recursive?: bool)
- [x] 1.2.3 Implement `executeListDirectory()` function
- [x] 1.2.4 Build shell command: `ls -la {path}` or `ls -laR {path}` if recursive
- [x] 1.2.5 Call `subprocess.execute()` with 5s timeout
- [x] 1.2.6 Return result to model
- [x] 1.2.7 Add unit tests (simple listing, recursive, non-existent path)

### 1.3 search_files Tool (Read-Only)
- [x] 1.3.1 Create `src/tools/search_files.zig` module
- [x] 1.3.2 Implement tool schema (pattern: string, path: string)
- [x] 1.3.3 Implement `executeSearchFiles()` function
- [x] 1.3.4 Build shell command: `grep -rn '{pattern}' {path}`
- [x] 1.3.5 Escape single quotes in pattern for shell safety
- [x] 1.3.6 Call `subprocess.execute()` with 5s timeout
- [x] 1.3.7 Return result to model
- [x] 1.3.8 Add unit tests (pattern found, pattern not found, invalid path)

### 1.4 write_file Tool (Destructive)
- [x] 1.4.1 Create `src/tools/write_file.zig` module
- [x] 1.4.2 Implement tool schema (path: string, content: string)
- [x] 1.4.3 Implement `executeWriteFile()` function
- [x] 1.4.4 Build shell command: `cat > {path} <<'EOF'\n{content}\nEOF`
- [x] 1.4.5 Call `subprocess.execute()` with 5s timeout
- [x] 1.4.6 Return result to model
- [x] 1.4.7 Add unit tests (create new file, overwrite existing, write to invalid path)

### 1.5 edit_file Tool (Destructive)
- [x] 1.5.1 Create `src/tools/edit_file.zig` module
- [x] 1.5.2 Implement tool schema (path: string, old_text: string, new_text: string)
- [x] 1.5.3 Implement `executeEditFile()` function
- [x] 1.5.4 Implement `escapeSedPattern()` helper to escape sed special characters
- [x] 1.5.5 Build shell command: `sed -i 's/{escaped_old}/{escaped_new}/g' {path}`
- [x] 1.5.6 Call `subprocess.execute()` with 5s timeout
- [x] 1.5.7 Return result to model
- [x] 1.5.8 Add unit tests (replace text, text not found, special characters, invalid path)

### 1.6 run_command Tool (Destructive)
- [x] 1.6.1 Create `src/tools/run_command.zig` module
- [x] 1.6.2 Implement tool schema (command: string, timeout?: int, working_dir?: string)
- [x] 1.6.3 Implement `executeRunCommand()` function
- [x] 1.6.4 Extract parameters (default timeout=5s)
- [x] 1.6.5 Call `subprocess.execute()` with provided parameters
- [x] 1.6.6 Return result to model
- [x] 1.6.7 Add unit tests (successful command, failed command, timeout, working_dir)

### 1.7 Tool Registry Integration
- [x] 1.7.1 Add `registerListDirectory()` method to ToolRegistry
- [x] 1.7.2 Add `registerSearchFiles()` method to ToolRegistry
- [x] 1.7.3 Add `registerWriteFile()` method to ToolRegistry
- [x] 1.7.4 Add `registerEditFile()` method to ToolRegistry
- [x] 1.7.5 Add `registerRunCommand()` method to ToolRegistry
- [x] 1.7.6 Call all registration methods in `ToolRegistry.init()`
- [x] 1.7.7 Verify 6 tools in registry (read_file, list_directory, search_files, write_file, edit_file, run_command)

---

## Phase 2: Confirmation UI (1 day)

### 2.1 Inline Y/n Confirmation
- [x] 2.1.1 Add `requestConfirmation(tool_name: []const u8, args: std.json.Value) bool` to TerminalUI
- [x] 2.1.2 Display inline prompt: "Execute <tool_name> <preview>? [Y/n] "
- [x] 2.1.3 Format preview based on tool (write_file shows path, run_command shows command)
- [x] 2.1.4 Handle keypresses (Y/y to confirm, N/n/Enter to deny)
- [x] 2.1.5 Return boolean result to caller
- [x] 2.1.6 Clear prompt line after response

### 2.2 Agent Integration
- [x] 2.2.1 Add helper to identify destructive tools (write_file, edit_file, run_command)
- [x] 2.2.2 Before executing destructive tool: call confirmation prompt
- [x] 2.2.3 Show tool name and relevant args to user in prompt
- [x] 2.2.4 Only execute tool if user confirms (Y/y)
- [x] 2.2.5 Return cancellation message to model if user denies
- [x] 2.2.6 Ensure read-only tools (read_file, list_directory, search_files) skip confirmation

---

## Phase 3: Context Tracking (1-2 days)

### 3.1 Token Tracking Core
- [x] 3.1.1 Add token counter fields to Agent struct:
         - `total_input_tokens: u32`
         - `total_output_tokens: u32`
- [x] 3.1.2 Implement `updateTokens(input: u32, output: u32)` method
- [x] 3.1.3 Accumulate tokens across turns (cumulative)

### 3.2 API Request & Response Changes
- [x] 3.2.1 Add `stream_options: { include_usage: true }` to `ChatCompletionRequest` struct
- [x] 3.2.2 Add `usage` field to `ChatCompletionChunk` struct (prompt_tokens, completion_tokens, total_tokens)
- [x] 3.2.3 Add `.usage` variant to `StreamChunk` union for callback
- [x] 3.2.4 Parse `usage` field from streaming response in `streamChatCompletion()`
- [x] 3.2.5 Emit `.usage` via callback when present
- [x] 3.2.6 Handle missing usage field gracefully (don't emit)

### 3.3 Terminal UI Status Line
- [x] 3.3.1 Add `renderStatusLine()` function to TerminalUI
- [x] 3.3.2 Display token count (e.g., "Tokens: 12.3K")
- [x] 3.3.3 Render at bottom of screen (y = height - 1)
- [x] 3.3.4 Update status line after each turn

---

## Phase 4: Integration & Testing (1 day)

### 4.1 End-to-End Scenario Testing
- [x] 4.1.1 Scenario: List directory (no confirmation)
         - [x] User asks agent to list current directory
         - [x] Agent uses list_directory(path=".")
         - [x] Tool executes immediately (no confirmation)
         - [x] Output shows directory contents
- [x] 4.1.2 Scenario: Search files (no confirmation)
         - [x] User asks to find pattern in files
         - [x] Agent uses search_files(pattern="foo", path=".")
         - [x] Tool executes immediately (no confirmation)
         - [x] Search results displayed
- [x] 4.1.3 Scenario: Read file (no confirmation)
         - [x] User asks agent to read a file
         - [x] Agent uses read_file(path="/path/to/file")
         - [x] Tool executes immediately (no confirmation)
         - [x] File contents displayed
- [x] 4.1.4 Scenario: Create new file (requires confirmation)
         - [x] User asks agent to create a file
         - [x] Agent uses write_file(path="test.txt", content="hello")
         - [x] User sees prompt: "Execute write_file test.txt? [Y/n]"
         - [x] User confirms with Y
         - [x] File created successfully
- [x] 4.1.5 Scenario: Run arbitrary command (requires confirmation)
         - [x] User asks agent to run custom command
         - [x] Agent uses run_command(command="echo 'test'")
         - [x] User sees prompt: "Execute run_command echo 'test'? [Y/n]"
         - [x] User confirms with Y
         - [x] Command executes successfully
- [x] 4.1.6 Scenario: Deny destructive operation
         - [x] Agent proposes write_file or run_command
         - [x] User denies with N
         - [x] Operation NOT executed
         - [x] Agent receives cancellation and continues
- [x] 4.1.7 Scenario: Command timeout
         - [x] Agent runs command that takes > timeout
         - [x] User confirms with Y
         - [x] Process killed after timeout
         - [x] Timeout error returned to model

### 4.2 Performance Validation
- [x] 4.2.1 Binary size: Verify <10MB
- [x] 4.2.2 Memory usage: Run multi-command scenario, verify peak <55MB
- [x] 4.2.3 Startup time: Measure cold start <500ms
- [x] 4.2.4 Tool execution latency: Each command <100ms overhead (plus command time)

### 4.3 Cross-Platform Testing
- [x] 4.3.1 Build for x86_64 linux
- [x] 4.3.2 Build for armv7l (cross-compile)
- [x] 4.3.3 Test on x86_64 (interactive session)
- [x] 4.3.4 Verify /bin/sh exists on target systems

### 4.4 Final Checklist
- [x] 4.4.1 All tasks marked complete
- [x] 4.4.2 `zig build` succeeds without warnings
- [x] 4.4.3 `zig build test` passes all tests
- [x] 4.4.4 Manual end-to-end scenario completes successfully

---

## Summary of Files to Create/Modify

### New Files
- `src/tools/subprocess.zig` - Shared subprocess spawner
- `src/tools/list_directory.zig` - List directory tool
- `src/tools/search_files.zig` - Search files tool
- `src/tools/write_file.zig` - Write file tool
- `src/tools/edit_file.zig` - Edit file tool (text replacement)
- `src/tools/run_command.zig` - General command escape hatch

### Modified Files
- `src/agent/agent.zig` - Add token tracking fields, destructive tool check
- `src/api/client.zig` - Add usage parsing
- `src/tools/registry.zig` - Add registration for 5 new tools
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

- [x] All ~15 core tasks complete (checkboxes above)
- [x] Binary <10MB
- [x] Peak memory <55MB
- [x] Startup <500ms
- [x] End-to-end subprocess scenarios succeed
- [x] User confirmation workflow verified
- [x] Token tracking displays correctly

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

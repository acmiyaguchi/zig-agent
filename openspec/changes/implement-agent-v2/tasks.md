# Implementation Tasks: Agent v2

**Change ID**: `implement-agent-v2`

## Overview

Implementation organized into 4 phases. Complete each section sequentially; mark items `[x]` when finished.

**Realistic Estimate**: 5-7 days (much simpler than custom tools approach!)

---

## Phase 1: Subprocess Spawner (2-3 days)

### 1.1 run_command Tool Core
- [ ] 1.1.1 Create `src/tools/run_command.zig` module
- [ ] 1.1.2 Implement tool schema (command: string, timeout?: int, working_dir?: string)
- [ ] 1.1.3 Implement `executeRunCommand()` function
- [ ] 1.1.4 Use `std.process.Child.init()` to create subprocess
- [ ] 1.1.5 Configure subprocess with `/bin/sh -c` to support shell features
- [ ] 1.1.6 Set stdout_behavior = .Pipe and stderr_behavior = .Pipe

### 1.2 Output Capture
- [ ] 1.2.1 Capture stdout with `readToEndAlloc(allocator, 1MB)`
- [ ] 1.2.2 Capture stderr with `readToEndAlloc(allocator, 1MB)`
- [ ] 1.2.3 Combine stdout + stderr in output (separate with "--- stderr ---")
- [ ] 1.2.4 Add truncation warning if output exceeds 1MB
- [ ] 1.2.5 Return full output to model

### 1.3 Timeout Handling
- [ ] 1.3.1 Implement `waitWithTimeout()` helper function
- [ ] 1.3.2 Default timeout to 5 seconds if not specified
- [ ] 1.3.3 Poll subprocess with `child.tryWait()` in loop
- [ ] 1.3.4 Track elapsed time and kill process if timeout exceeded
- [ ] 1.3.5 Return timeout error to model if command times out

### 1.4 Exit Code Handling
- [ ] 1.4.1 Capture exit code from subprocess termination
- [ ] 1.4.2 Set ToolResult.success = true if exit code == 0
- [ ] 1.4.3 Set ToolResult.success = false if exit code != 0
- [ ] 1.4.4 Include exit code in error message for failures
- [ ] 1.4.5 Return both output and exit status to model

### 1.5 Tool Registry Integration
- [ ] 1.5.1 Add `registerRunCommand()` method to ToolRegistry
- [ ] 1.5.2 Call `registerRunCommand()` in `ToolRegistry.init()`
- [ ] 1.5.3 Verify tool appears in registry (read_file + run_command)

### 1.6 Unit Tests
- [ ] 1.6.1 Test successful command execution (`echo "hello"`)
- [ ] 1.6.2 Test command with non-zero exit code (`false`)
- [ ] 1.6.3 Test timeout handling (sleep 10 with 1s timeout)
- [ ] 1.6.4 Test output capture (stdout + stderr)
- [ ] 1.6.5 Test output truncation (command with > 1MB output)
- [ ] 1.6.6 Test working directory parameter

---

## Phase 2: Confirmation UI (1 day)

### 2.1 Inline Y/n Confirmation
- [ ] 2.1.1 Add `requestConfirmation(message: []const u8) bool` to TerminalUI
- [ ] 2.1.2 Display inline prompt: "Execute: <command>? [Y/n] "
- [ ] 2.1.3 Handle keypresses (Y/y to confirm, N/n/Enter to deny)
- [ ] 2.1.4 Return boolean result to caller
- [ ] 2.1.5 Clear prompt line after response

### 2.2 Agent Integration
- [ ] 2.2.1 Before executing `run_command`: call confirmation prompt
- [ ] 2.2.2 Show full command to user in prompt
- [ ] 2.2.3 Only execute command if user confirms (Y/y)
- [ ] 2.2.4 Return cancellation message to model if user denies
- [ ] 2.2.5 Note: read_file does NOT require confirmation (read-only)

---

## Phase 3: Context Tracking (1-2 days)

### 3.1 Token Tracking Core
- [ ] 3.1.1 Add token counter fields to Agent struct:
         - `total_input_tokens: u32`
         - `total_output_tokens: u32`
- [ ] 3.1.2 Implement `updateTokens(input: u32, output: u32)` method
- [ ] 3.1.3 Accumulate tokens across turns (cumulative)

### 3.2 API Response Parsing
- [ ] 3.2.1 Update `APIClient.streamChatCompletion()` to parse usage from final chunk
- [ ] 3.2.2 Extract `usage.input_tokens` and `usage.completion_tokens` from response
- [ ] 3.2.3 Handle missing usage field gracefully (use default 0)
- [ ] 3.2.4 Pass usage to Agent after each API call

### 3.3 Terminal UI Status Line
- [ ] 3.3.1 Add `renderStatusLine()` function to TerminalUI
- [ ] 3.3.2 Display token count (e.g., "Tokens: 12.3K")
- [ ] 3.3.3 Render at bottom of screen (y = height - 1)
- [ ] 3.3.4 Update status line after each turn

---

## Phase 4: Integration & Testing (1 day)

### 4.1 End-to-End Scenario Testing
- [ ] 4.1.1 Scenario: List directory
         - [ ] User asks agent to list current directory
         - [ ] Agent uses run_command("ls -la")
         - [ ] User confirms with Y
         - [ ] Output shows directory contents
- [ ] 4.1.2 Scenario: Read file
         - [ ] User asks agent to read a file
         - [ ] Agent uses run_command("cat /path/to/file")
         - [ ] User confirms with Y
         - [ ] File contents displayed
- [ ] 4.1.3 Scenario: Create new file
         - [ ] User asks agent to create a file
         - [ ] Agent uses run_command("echo 'content' > file.txt")
         - [ ] User confirms with Y
         - [ ] File created successfully
- [ ] 4.1.4 Scenario: Edit existing file
         - [ ] User asks agent to modify a line
         - [ ] Agent uses run_command("sed -i 's/old/new/' file.txt")
         - [ ] User confirms with Y
         - [ ] File modified successfully
- [ ] 4.1.5 Scenario: Search files
         - [ ] User asks to find pattern in files
         - [ ] Agent uses run_command("grep -rn 'pattern' .")
         - [ ] User confirms with Y
         - [ ] Search results displayed
- [ ] 4.1.6 Scenario: Deny command execution
         - [ ] Agent proposes run_command
         - [ ] User denies with N
         - [ ] Command NOT executed
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
- `src/tools/run_command.zig`

### Modified Files
- `src/agent/agent.zig` - Add token tracking fields
- `src/api/client.zig` - Add usage parsing
- `src/tools/registry.zig` - Add registration for run_command
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
- ~1000 LOC for custom tools
- 3 new tool modules (write_file, edit_file, list_directory)

**New Design (This Proposal)**:
- ~15 core tasks across 4 phases
- 5-7 days estimated
- ~200 LOC for subprocess spawner
- 1 new tool module (run_command)

**Savings**: ~57 fewer tasks, ~800 fewer LOC, 2-3 days faster, simpler architecture!

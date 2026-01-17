# Design: Agent v2 - Hybrid Tool Approach

**Change ID**: `implement-agent-v2`

This document captures technical decisions, architectural patterns, and safety constraints for v2 features.

## Context

V1 established a working agent loop on resource-constrained devices. V2 adds subprocess execution capabilities and basic token tracking.

**Key Architectural Shift**: Instead of implementing custom Zig tools for file operations, we use a hybrid approach: structured tool wrappers that internally call coreutils. This gives us clear interfaces, zero friction for read-only operations, and simpler implementation (~300 LOC vs ~1000 LOC custom tools).

## Goals / Non-Goals

### Goals
- Enable file modification via structured `write_file` tool
- Provide directory exploration via `list_directory` tool
- Enable code search via `search_files` tool
- Provide escape hatch for arbitrary commands via `run_command`
- Zero friction for read-only operations (no confirmations)
- Confirmation only for destructive operations
- Expose token/context usage to prevent surprises
- Maintain <55MB peak memory, <500ms startup, <10MB binary

### Non-Goals
- Sandboxing/whitelisting (trust users, they're on their own machines)
- Full Zig reimplementation of file tools (wrap coreutils instead)
- Confirmation for read-only operations (safe by default)
- Full shell feature parity (run_command provides escape hatch)
- Persistent configuration (use defaults, override via CLI)
- Multi-turn context pruning (v2.1)
- Real-time output streaming (v2.1)
- Command history (v2.1)

## Technical Decisions

### Decision 1: Hybrid Approach - Structured Tools + Escape Hatch

**Choice**: Implement structured tool wrappers (list_directory, search_files, write_file, edit_file) that internally call coreutils, plus general run_command escape hatch

**Alternatives Considered**:
1. Custom Zig tools (`write_file`, `edit_file`, `list_directory`, `grep_files`) - ~1000 LOC, reimplements existing functionality
2. Single subprocess spawner only - ~200 LOC but no structure, every operation needs shell syntax
3. Hybrid approach (structured wrappers + escape hatch) - **CHOSEN** - ~300 LOC, best of both worlds

**Rationale**:
- Structured tools provide clear, typed interfaces for common operations
- Read-only tools (list_directory, search_files) have zero friction - no confirmations
- Internally wrapping coreutils means battle-tested implementations
- Model gets familiar tool names without needing to construct shell commands
- run_command provides escape hatch for anything else
- Smaller binary size (no custom file manipulation code)
- Fewer bugs to fix (we rely on coreutils, not our implementations)

**Implementation**:

Each tool is a thin wrapper that builds a shell command and calls shared subprocess spawner:

```zig
// list_directory: Wraps `ls -la {path}`
pub fn executeListDirectory(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const recursive = if (args.object.get("recursive")) |r| r.bool else false;

    // Build shell command
    const command = if (recursive)
        try std.fmt.allocPrint(allocator, "ls -laR {s}", .{path})
    else
        try std.fmt.allocPrint(allocator, "ls -la {s}", .{path});
    defer allocator.free(command);

    // Use shared subprocess spawner
    return subprocess.execute(allocator, command, 5, null);
}

// search_files: Wraps `grep -rn '{pattern}' {path}`
pub fn executeSearchFiles(allocator: Allocator, args: std.json.Value) !ToolResult {
    const pattern = args.object.get("pattern").?.string;
    const path = args.object.get("path").?.string;

    const command = try std.fmt.allocPrint(allocator, "grep -rn '{s}' {s}", .{pattern, path});
    defer allocator.free(command);

    return subprocess.execute(allocator, command, 5, null);
}

// write_file: Wraps `cat > {path} <<'EOF'\n{content}\nEOF`
pub fn executeWriteFile(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const content = args.object.get("content").?.string;

    const command = try std.fmt.allocPrint(
        allocator,
        "cat > {s} <<'EOF'\n{s}\nEOF",
        .{path, content}
    );
    defer allocator.free(command);

    return subprocess.execute(allocator, command, 5, null);
}

// edit_file: Wraps `sed -i 's/old_text/new_text/g' {path}`
pub fn executeEditFile(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const old_text = args.object.get("old_text").?.string;
    const new_text = args.object.get("new_text").?.string;

    // Escape sed special characters in old_text and new_text
    const escaped_old = try escapeSedPattern(allocator, old_text);
    defer allocator.free(escaped_old);
    const escaped_new = try escapeSedPattern(allocator, new_text);
    defer allocator.free(escaped_new);

    const command = try std.fmt.allocPrint(
        allocator,
        "sed -i 's/{s}/{s}/g' {s}",
        .{escaped_old, escaped_new, path}
    );
    defer allocator.free(command);

    return subprocess.execute(allocator, command, 5, null);
}

// run_command: General escape hatch
pub fn executeRunCommand(allocator: Allocator, args: std.json.Value) !ToolResult {
    const command = args.object.get("command").?.string;
    const timeout_secs = if (args.object.get("timeout")) |t| t.integer else 5;
    const working_dir = if (args.object.get("working_dir")) |wd| wd.string else null;

    return subprocess.execute(allocator, command, timeout_secs, working_dir);
}
```

**Trade-offs**:
- Slightly more code than single run_command (~300 LOC vs ~200 LOC)
- More tools to register and maintain
- But: much clearer interfaces, zero friction for read-only ops

**Trade-off Justification**:
- Read-only workflows (explore, search, read) have zero friction
- Model doesn't need to know shell syntax for common operations
- Structured tools are easier to test and reason about
- Still have full power via run_command escape hatch

---

### Decision 2: Confirmation Only for Destructive Operations

**Choice**: Read-only tools (read_file, list_directory, search_files) require NO confirmation. Destructive tools (write_file, edit_file, run_command) require Y/n confirmation.

**Alternatives Considered**:
1. Confirmation for all tools - too much friction, slows down read-only workflows
2. No confirmation for any tools - risky for destructive operations
3. Confirmation only for destructive tools - **CHOSEN** - balanced approach

**Rationale**:
- Reading files, listing directories, and searching are inherently safe operations
- Writing files and running arbitrary commands can be destructive
- Zero friction for exploration and analysis workflows
- Safety guard for operations that modify state

**Implementation**:
```zig
pub fn executeTool(self: *Agent, tool_name: []const u8, args: std.json.Value) !ToolResult {
    const tool = self.registry.lookup(tool_name) orelse return error.ToolNotFound;

    // Check if tool requires confirmation
    const requires_confirmation = std.mem.eql(u8, tool_name, "write_file") or
                                  std.mem.eql(u8, tool_name, "edit_file") or
                                  std.mem.eql(u8, tool_name, "run_command");

    if (requires_confirmation) {
        const confirmed = try self.ui.requestConfirmation(tool_name, args);
        if (!confirmed) {
            return ToolResult{
                .success = false,
                .output = "",
                .error_message = "Operation cancelled by user",
            };
        }
    }

    // Execute tool
    return tool.execute(self.allocator, args);
}
```

**Trade-offs**:
- More complex logic to determine which tools need confirmation
- Need to maintain list of destructive tools

**Trade-off Justification**:
- Read-only workflows are the most common (explore, search, analyze)
- Zero friction for safe operations dramatically improves UX
- Destructive operations still have safety guard

---

### Decision 3: No Sandboxing - Trust the User

**Choice**: No whitelist, no sandboxing, no restrictions on commands

**Alternatives Considered**:
1. Whitelist of allowed commands - bypassable via shell (e.g., `bash -c "forbidden command"`)
2. Sandboxing via Linux namespaces - complex, platform-specific, resource-heavy
3. No restrictions with confirmation - simple, honest about limitations

**Rationale**:
- Whitelists are security theater (easily bypassed)
- Sandboxing adds complexity and doesn't fit resource constraints
- Users already run arbitrary commands in their development workflow
- Developers are trusted to evaluate command safety
- Confirmation prompt provides visibility

**Implementation**:
```zig
// No special validation, just execute the command
// User sees full command in confirmation prompt before approval
```

**Trade-offs**:
- Security: User could accidentally approve dangerous command
- Trust: Requires user vigilance

**Trade-off Justification**:
- Honest about security model
- Simpler implementation
- Users have same risk running commands in terminal
- Confirmation prompt surfaces command for review

---

### Decision 4: Inline Y/n Confirmation (Not Modal)

**Choice**: Use inline text prompt for confirmation, not modal dialog

**Alternatives Considered**:
1. Modal dialog (centered box with buttons) - complex async handling
2. Inline Y/n prompt - simple, works with event loop

**Rationale**:
- Modal dialogs require complex state management with async event loop
- Inline prompts are trivial to implement
- One keystroke is same friction either way
- Avoids termbox2 complexity of rendering overlays

**Implementation**:
```zig
pub fn requestConfirmation(self: *TerminalUI, message: []const u8) bool {
    // Print inline: "Execute: ls -la? [Y/n] "
    self.print("Execute: ");
    self.print(message);
    self.print("? [Y/n] ");
    self.flush();

    // Block for single keypress
    const key = self.waitForKey();

    return key == 'Y' or key == 'y';
}
```

**Trade-offs**:
- Less visually distinct than modal
- No preview of command output

**Trade-off Justification**: Simplicity wins. Output preview deferred to v2.1.

---

### Decision 5: Timeout Handling with Configurable Default

**Choice**: 5-second default timeout, configurable via parameter

**Rationale**:
- Prevents hanging on infinite loops or blocking commands
- 5 seconds sufficient for most file operations
- Long-running commands can specify longer timeout
- User can break command into smaller pieces if needed

**Implementation**:
```zig
fn waitWithTimeout(child: *std.process.Child, timeout_secs: i64) !ExitResult {
    const timeout_ns = timeout_secs * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();

    while (true) {
        const elapsed = std.time.nanoTimestamp() - start;
        if (elapsed > timeout_ns) {
            // Kill process and return timeout error
            child.kill() catch {};
            return error.Timeout;
        }

        // Poll for process completion
        if (child.tryWait()) |term| {
            return ExitResult{ .exit_code = term.Exited };
        }

        // Sleep briefly to avoid spinning
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
```

**Trade-offs**:
- 5s may be too short for some operations
- Polling adds slight CPU overhead

**Trade-off Justification**: Good default for most operations. Users can increase for long tasks.

---

### Decision 6: Output Capture with 1MB Cap

**Choice**: Buffer output up to 1MB, return truncation warning if exceeded

**Rationale**:
- Prevents memory exhaustion from commands with large output
- 1MB sufficient for most command outputs
- Users can redirect to file if needed (`command > output.txt`)

**Implementation**:
```zig
const MAX_OUTPUT = 1024 * 1024; // 1MB

const stdout = try child.stdout.?.readToEndAlloc(allocator, MAX_OUTPUT);
const stderr = try child.stderr.?.readToEndAlloc(allocator, MAX_OUTPUT);

if (stdout.len >= MAX_OUTPUT or stderr.len >= MAX_OUTPUT) {
    try output.appendSlice("\n[Output truncated at 1MB limit]");
}
```

**Trade-offs**:
- Large outputs may be truncated
- Users need to redirect to file for large data

**Trade-off Justification**: Memory safety is critical. File redirection is easy workaround.

---

### Decision 7: Token Tracking - Use OpenRouter's Usage Field

**Choice**: Parse usage data from OpenRouter API responses, display in status line

**Data Source**: OpenRouter includes `usage` in streaming responses when requested:
```json
{
  "usage": {
    "prompt_tokens": 1234,
    "completion_tokens": 567,
    "total_tokens": 1801
  }
}
```

**Implementation Changes**:

1. Add `stream_options` to request:
```zig
pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: ?[]const ToolDefinition = null,
    stream: bool = true,
    stream_options: ?struct {
        include_usage: bool = true,
    } = .{ .include_usage = true },
};
```

2. Add `usage` field to `ChatCompletionChunk`:
```zig
pub const ChatCompletionChunk = struct {
    // ... existing fields ...
    usage: ?struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    } = null,
};
```

3. Parse and accumulate in client callback:
```zig
if (parsed.value.usage) |usage| {
    callback(.{ .usage = .{
        .prompt_tokens = usage.prompt_tokens,
        .completion_tokens = usage.completion_tokens,
    } }, context);
}
```

4. Display in status line:
```zig
pub fn renderStatusLine(self: *TerminalUI, tokens: u32) void {
    var buf: [50]u8 = undefined;
    const status = std.fmt.bufPrint(&buf, "Tokens: {d:.1}K", .{
        @as(f32, @floatFromInt(tokens)) / 1000.0,
    }) catch return;

    self.printAt(0, self.height - 1, status);
}
```

**Rationale**:
- OpenRouter provides accurate token counts - no estimation needed
- Simple to implement - just parse existing API response field
- Users see real usage, not approximations

**Trade-offs**:
- Depends on OpenRouter including usage (they do for streaming with `include_usage`)
- No warning when approaching context limit (add in v2.1)

**Trade-off Justification**: Use the data we already get. Simple and accurate.

---

### Decision 8: Memory Budget for Subprocess Buffers

**Choice**: Allocate ~1MB for subprocess output buffers

**Rationale**:
- Output capped at 1MB total (stdout + stderr)
- Much less than custom tools approach (~4MB)
- Arena allocator cleanup after each command

**Implementation**:
- Use arena allocator per tool execution
- Clean up after each tool call returns
- Cap output at 1MB per subprocess

**Trade-offs**:
- 1MB output limit may frustrate some users
- Can't handle commands with very large output

**Trade-off Justification**: Memory budget is firm constraint. File redirection is workaround.

---

## Risks / Trade-offs Summary

| Decision | Risk | Mitigation |
|----------|------|------------|
| No sandboxing | Dangerous commands executed | Confirmation prompt for destructive tools |
| Hybrid approach | More tools to maintain | Each tool is simple wrapper (~20-30 LOC) |
| No confirmation for read-only | None - safe by design | Read-only ops can't modify state |
| Confirmation for destructive | One extra keystroke | Only applies to write_file, run_command |
| 5s timeout | Some operations may time out | Configurable timeout parameter |
| 1MB output cap | Large outputs truncated | Users redirect to file (`> output.txt`) |
| Simple token counter | No limit warnings | Users track manually; percentage in v2.1 |

## Open Questions

1. **Should we combine stdout and stderr in output?**
   - Yes, for simplicity. Separate with "--- stderr ---" marker.

2. **What if user denies confirmation?**
   - Return error to model: "Command cancelled by user"
   - Model can decide to retry or continue differently

3. **How to handle interactive commands (like vim)?**
   - Not supported in v2. Commands must be non-interactive.
   - Document this limitation.

## Deferred Decisions (v2.1)

1. **Output Streaming**: Real-time output display for long-running commands
2. **Command History**: Store and recall previous commands
3. **Diff Previews**: Show file diffs before confirming sed operations
4. **Model Switching**: Needs UI for selection, not essential for subprocess workflow

## References

- [tool-expansion spec](specs/tool-expansion/spec.md)
- [subprocess-execution spec](specs/subprocess-execution/spec.md)
- [context-tracking spec](specs/context-tracking/spec.md)
- [API client reference](../../../../src/api/client.zig)

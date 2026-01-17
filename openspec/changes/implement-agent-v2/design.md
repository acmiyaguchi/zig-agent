# Design: Agent v2 - Subprocess Execution

**Change ID**: `implement-agent-v2`

This document captures technical decisions, architectural patterns, and safety constraints for v2 features.

## Context

V1 established a working agent loop on resource-constrained devices. V2 adds subprocess execution capabilities and basic token tracking.

**Key Architectural Shift**: Instead of implementing custom Zig tools for file operations, we leverage existing Unix tools (coreutils/busybox) via subprocess execution. This is radically simpler (~200 LOC vs ~1000 LOC) and more powerful.

## Goals / Non-Goals

### Goals
- Enable file modification via standard Unix tools (cat, sed, echo, etc.)
- Provide directory exploration (ls, find, tree)
- Enable code search (grep)
- Expose token/context usage to prevent surprises
- Maintain <55MB peak memory, <500ms startup, <10MB binary
- Trust users to evaluate command safety

### Non-Goals
- Sandboxing/whitelisting (security theater, users run npm install anyway)
- Custom file editing tools (use sed, cat, echo instead)
- Custom grep implementation (use existing grep)
- Full shell feature parity (restrictions intentional)
- Persistent configuration (use defaults, override via CLI)
- Multi-turn context pruning (v2.1)
- Real-time output streaming (v2.1)
- Command history (v2.1)

## Technical Decisions

### Decision 1: Single run_command Tool vs Multiple Custom Tools

**Choice**: Implement single `run_command` tool that spawns subprocesses

**Alternatives Considered**:
1. Custom Zig tools (`write_file`, `edit_file`, `list_directory`, `grep_files`) - ~1000 LOC, reimplements existing functionality
2. Single subprocess spawner - ~200 LOC, leverages battle-tested tools
3. Hybrid approach (some custom, some subprocess) - unnecessary complexity

**Rationale**:
- Unix tools already exist and work perfectly (ls, cat, grep, sed, find, etc.)
- Model already knows how to use these tools
- Users are familiar with these tools
- Smaller binary size (no custom file manipulation code)
- Fewer bugs to fix (we rely on coreutils, not our implementations)
- More powerful (full shell available via `bash -c "..."`)

**Implementation**:
```zig
// run_command: Execute shell command with timeout and output capture
pub fn executeRunCommand(allocator: Allocator, args: std.json.Value) !ToolResult {
    const command = args.object.get("command").?.string;
    const timeout_secs = if (args.object.get("timeout")) |t| t.integer else 5;
    const working_dir = if (args.object.get("working_dir")) |wd| wd.string else null;

    // 1. Spawn subprocess using std.process
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (working_dir) |wd| child.cwd = wd;

    // 2. Start and wait with timeout
    try child.spawn();
    const result = try waitWithTimeout(&child, timeout_secs);

    // 3. Capture output (stdout + stderr combined)
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024); // 1MB cap
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

    // 4. Format output
    var output = std.ArrayList(u8).init(allocator);
    if (stdout.len > 0) try output.appendSlice(stdout);
    if (stderr.len > 0) {
        try output.appendSlice("\n--- stderr ---\n");
        try output.appendSlice(stderr);
    }

    // 5. Return based on exit code
    const exit_code = result.exit_code;
    return ToolResult{
        .success = exit_code == 0,
        .output = output.items,
        .error_message = if (exit_code != 0)
            try std.fmt.allocPrint(allocator, "Command failed with exit code {d}", .{exit_code})
        else null,
    };
}
```

**Trade-offs**:
- Security: No sandboxing, user responsible for safe commands
- Trust: Requires trusting user to evaluate command safety
- Confirmation overhead: Every command requires Y/n approval

**Trade-off Justification**:
- Users are developers on their own machines
- They already run arbitrary commands (npm install, cargo build, etc.)
- Confirmation prompt provides visibility before execution
- Simpler implementation means fewer bugs

---

### Decision 2: No Sandboxing - Trust the User

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

### Decision 3: Inline Y/n Confirmation (Not Modal)

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

### Decision 4: Timeout Handling with Configurable Default

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

### Decision 5: Output Capture with 1MB Cap

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

### Decision 6: Token Tracking - Use OpenRouter's Usage Field

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

### Decision 7: Memory Budget for Subprocess Buffers

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
| No sandboxing | Dangerous commands executed | Confirmation prompt shows full command |
| Single subprocess tool | Less specialized than custom tools | Unix tools are more powerful and familiar |
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

- [subprocess-execution spec](specs/subprocess-execution/spec.md)
- [context-tracking spec](specs/context-tracking/spec.md)
- [API client reference](../../../../src/api/client.zig)

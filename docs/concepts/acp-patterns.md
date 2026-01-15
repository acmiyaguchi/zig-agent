# ACP-Inspired Design Patterns

## Overview

The [Agent Client Protocol (ACP)](https://agentclientprotocol.com) is a JSON-RPC-based standard for agent-to-editor communication. While we don't implement ACP itself (it adds unnecessary overhead for a standalone CLI), it contains proven design patterns worth adopting.

**Key insight**: ACP represents the collective wisdom of multiple production agent implementations (Zed, Google Gemini CLI, Claude Code in ACP mode). We can learn from this without adopting the full protocol.

## Decision: Why Not Full ACP?

**ACP is designed for**: Agent processes spawned by editors, communicating via JSON-RPC over stdio.

**Zig-agent is designed for**: Standalone CLI tool with its own terminal UI, running on constrained devices.

**Trade-offs**:
- ❌ ACP adds: JSON-RPC layer, protocol state machines, stdin/stdout multiplexing (~500KB+ overhead)
- ❌ Conflicts with: <50MB RAM target, minimal complexity philosophy
- ✅ ACP patterns worth adopting: Streaming updates, permission model, capabilities, path conventions

**Verdict**: Adopt the patterns, skip the protocol.

See: [interface-design.md](interface-design.md) for our event-driven architecture (similar goals, lighter implementation).

## Pattern 1: Streaming Update Enumeration ⭐ Most Valuable

### The Problem ACP Solves

Streaming LLM responses mix different types of content:
- Model reasoning ("thinking")
- User-facing messages
- Tool calls and results
- Completion signals

Without separation, the UI can't render these appropriately.

### ACP's Solution

```typescript
// ACP session/update notification
type SessionUpdate =
  | { kind: "thought", content: string }
  | { kind: "message", content: string }
  | { kind: "tool_call", tool: ToolCall }
  | { kind: "tool_result", result: ToolResult }
```

Each update type has distinct rendering needs:
- `thought` → dimmed/debug output
- `message` → normal streaming text
- `tool_call` → show spinner with tool name
- `tool_result` → show checkmark or error icon

### Our Implementation

```zig
const AgentUpdate = union(enum) {
    /// Model reasoning (internal thoughts)
    thought: []const u8,

    /// Message chunk streaming to user
    message_chunk: []const u8,

    /// Tool about to execute
    tool_call: struct {
        name: []const u8,
        args: std.json.Value,
    },

    /// Tool execution completed
    tool_result: struct {
        name: []const u8,
        success: bool,
        output: []const u8,
        duration_ms: u64,
    },

    /// Turn complete
    completion: enum {
        stop,           // Natural completion
        max_tokens,     // Hit token limit
        tool_use,       // Waiting for tool execution
        error,          // Error occurred
    },
};
```

### Benefits

1. **Clear rendering logic**: UI can pattern match on update type
2. **Type safety**: Can't mix up thought vs message content
3. **Extensible**: Easy to add new update types (e.g., `plan_updated`)
4. **Testable**: Mock UI just collects updates in a list

### Usage Example

```zig
fn handleUpdate(update: AgentUpdate, writer: anytype) !void {
    switch (update) {
        .thought => |text| {
            // Render in gray/dimmed
            try writer.print("\x1b[90m{s}\x1b[0m\n", .{text});
        },
        .message_chunk => |text| {
            // Render normally, streaming
            try writer.print("{s}", .{text});
        },
        .tool_call => |call| {
            // Show spinner
            try writer.print("⏳ Running {s}...\n", .{call.name});
        },
        .tool_result => |result| {
            // Show checkmark or error
            const icon = if (result.success) "✓" else "✗";
            try writer.print("{s} {s} ({d}ms)\n",
                .{icon, result.name, result.duration_ms});
        },
        .completion => |reason| {
            try writer.print("─── {s} ───\n", .{@tagName(reason)});
        },
    }
}
```

**Related**: See [interface-design.md](interface-design.md) lines 70-81 for our event system.

## Pattern 2: Absolute Paths Only

### The Problem

Relative paths cause bugs:
- Confusion about current working directory
- `../../` path traversal vulnerabilities
- Different results depending on where agent was launched

### ACP's Solution

**All file paths MUST be absolute.** No exceptions.

From ACP spec:
> "All file system paths in the protocol must be absolute paths. Relative paths are not allowed."

### Our Implementation

```zig
fn normalizePath(allocator: Allocator, user_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(user_path)) {
        return try allocator.dupe(u8, user_path);
    }

    // Convert relative to absolute immediately
    const cwd = try std.process.getCwd(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &.{cwd, user_path});
}
```

### Benefits

1. **No CWD ambiguity**: Path means the same thing everywhere
2. **Security**: Easier to validate (check prefix against workspace root)
3. **Debugging**: Logs show full paths, easier to understand
4. **Consistency**: All tools use absolute paths internally

### Enforcement

```zig
fn validateToolPath(path: []const u8) !void {
    // Reject relative paths early
    if (!std.fs.path.isAbsolute(path)) {
        return error.RelativePathNotAllowed;
    }

    // Validate workspace containment
    if (!std.mem.startsWith(u8, path, workspace_root)) {
        return error.PathOutsideWorkspace;
    }
}
```

**Related**: See [file-operations.md](file-operations.md) for path safety implementation.

## Pattern 3: 1-Based Line Numbers

### The Problem

Developers think in editor line numbers (1-based), but most programming is 0-based. This causes off-by-one errors in error messages and file navigation.

### ACP's Solution

**All line numbers are 1-based** to match editor conventions.

When you tell a user "error on line 42", they open the file and it's actually line 42. No mental offset needed.

### Our Implementation

```zig
const LineRange = struct {
    /// Line numbers are 1-based (matching editor display)
    start: usize,  // 1 = first line
    end: usize,    // inclusive

    fn toZeroBased(self: LineRange) struct { start: usize, end: usize } {
        return .{
            .start = self.start - 1,
            .end = self.end - 1,
        };
    }
};
```

### Usage

```zig
// User-facing output: 1-based
fn reportError(file: []const u8, line: usize, msg: []const u8) !void {
    try stderr.print("Error in {s}:{d}: {s}\n", .{file, line, msg});
}

// Internal processing: convert to 0-based only when indexing
fn readLineRange(path: []const u8, range: LineRange) ![]const u8 {
    const zero_based = range.toZeroBased();
    // Now use zero_based.start to index arrays
}
```

### Benefits

1. **User clarity**: Error messages match what users see in editors
2. **Reduced confusion**: No mental offset calculation
3. **Standards compliance**: Most editors are 1-based (vim, emacs, VS Code)

**Convention**: Use 1-based in all public APIs and user messages. Convert to 0-based only at the point of array indexing.

## Pattern 4: Capabilities Negotiation

### The Problem

Different agent configurations have different abilities:
- Explore agents can read but not write
- Some environments don't allow shell execution
- File size limits vary by available memory

Without explicit capabilities, the model assumes everything works, then fails at runtime.

### ACP's Solution

```typescript
// Initialize handshake includes capabilities
{
  "capabilities": {
    "fileSystem": {
      "readTextFile": true,
      "writeTextFile": true
    },
    "terminal": {
      "create": true,
      "output": true
    },
    "sessions": {
      "load": false  // Not supported
    }
  }
}
```

The agent knows upfront what tools are available and can adapt its strategy.

### Our Implementation

```zig
const AgentCapabilities = struct {
    /// File operations
    can_read_files: bool = true,
    can_write_files: bool = true,
    can_edit_files: bool = true,

    /// Shell execution
    can_execute_shell: bool = true,

    /// Resource limits
    max_file_size: usize = 10 * 1024 * 1024,  // 10MB
    max_shell_timeout: u64 = 300_000,          // 5 min (ms)
    max_output_size: usize = 1 * 1024 * 1024, // 1MB

    /// Features
    supports_subagents: bool = false,  // v1: no subagents
    supports_planning: bool = true,    // TodoWrite tool
};
```

### Subagent-Specific Capabilities

```zig
fn getCapabilitiesForAgentType(agent_type: AgentType) AgentCapabilities {
    return switch (agent_type) {
        .explore => .{
            .can_read_files = true,
            .can_write_files = false,  // Read-only!
            .can_edit_files = false,
            .can_execute_shell = true,  // Read-only commands only
            .supports_subagents = false,
        },
        .code => .{
            // Full capabilities
            .can_read_files = true,
            .can_write_files = true,
            .can_edit_files = true,
            .can_execute_shell = true,
            .supports_subagents = true,
        },
        .plan => .{
            .can_read_files = true,
            .can_write_files = false,
            .can_edit_files = false,
            .can_execute_shell = false,
            .supports_subagents = false,
        },
    };
}
```

### Tool Filtering

```zig
fn getToolsForCapabilities(caps: AgentCapabilities) []const Tool {
    var tools = std.ArrayList(Tool).init(allocator);

    if (caps.can_read_files) {
        try tools.append(ReadFileTool);
        try tools.append(GlobTool);
        try tools.append(GrepTool);
    }

    if (caps.can_write_files) {
        try tools.append(WriteFileTool);
    }

    if (caps.can_edit_files) {
        try tools.append(EditFileTool);
    }

    if (caps.can_execute_shell) {
        try tools.append(BashTool);
    }

    if (caps.supports_planning) {
        try tools.append(TodoWriteTool);
    }

    return tools.toOwnedSlice();
}
```

### Benefits

1. **Explicit constraints**: Model knows what's possible
2. **Type safety**: Can't call tools that don't exist
3. **Subagent isolation**: Restrict explore agents to read-only
4. **Runtime adaptation**: Adjust limits based on available memory

**Related**: See [architecture.md](architecture.md) lines 118-125 for agent type definitions.

## Pattern 5: Explicit Session Lifecycle

### The Problem

Without clear state boundaries, it's hard to:
- Clean up resources properly
- Handle errors and recovery
- Track session history
- Implement session persistence

### ACP's Solution

```
[uninitialized]
  ↓ initialize
[ready]
  ↓ session/new
[active]
  ↓ session/prompt → [processing] → [active]
  ↓ session/end
[completed]
```

Every session has a defined lifecycle with explicit transitions.

### Our Implementation

```zig
const SessionState = enum {
    uninitialized,      // Agent created, not ready
    ready,              // Tools loaded, can accept prompts
    processing_prompt,  // Waiting for API response
    executing_tool,     // Running tool
    awaiting_permission,// Waiting for user approval
    completed,          // Session ended normally
    error,              // Unrecoverable error
    cancelled,          // User cancelled

    fn canAcceptPrompt(self: SessionState) bool {
        return self == .ready or self == .completed;
    }

    fn canExecuteTool(self: SessionState) bool {
        return self == .processing_prompt or self == .executing_tool;
    }
};

const Session = struct {
    id: []const u8,
    state: SessionState,
    messages: std.ArrayList(Message),
    created_at: i64,

    fn transitionTo(self: *Session, new_state: SessionState) !void {
        // Validate state transition
        const valid = switch (self.state) {
            .ready => new_state == .processing_prompt,
            .processing_prompt => new_state == .executing_tool or
                                  new_state == .completed or
                                  new_state == .error,
            .executing_tool => new_state == .processing_prompt or
                              new_state == .awaiting_permission or
                              new_state == .error,
            .awaiting_permission => new_state == .executing_tool or
                                   new_state == .cancelled,
            else => false,
        };

        if (!valid) {
            return error.InvalidStateTransition;
        }

        self.state = new_state;
    }
};
```

### Error Recovery

```zig
fn handleError(session: *Session, err: anyerror) !void {
    const recoverable = switch (err) {
        error.APITimeout => true,
        error.RateLimited => true,
        error.ToolExecutionFailed => true,
        else => false,
    };

    if (recoverable) {
        // Reset to ready state, keep conversation history
        try session.transitionTo(.ready);
    } else {
        // Unrecoverable error
        try session.transitionTo(.error);
    }
}
```

### Benefits

1. **Clear boundaries**: Know when to allocate/free resources
2. **Error handling**: Can recover based on current state
3. **Testing**: Easy to mock specific states
4. **Debugging**: Logs show state transitions

**Related**: See [conversation-state.md](conversation-state.md) for message management.

## Pattern 6: Permission Request Pattern

### The Problem

Agents shouldn't blindly execute dangerous commands:
- `rm -rf /` could destroy the system
- `git push --force` could overwrite remote
- `curl | bash` could download malware

### ACP's Solution

Separate tool execution into two phases:
1. **Request**: Agent asks "Can I run this tool?"
2. **Approval**: Client prompts user → yes/no/always
3. **Execution**: Only if approved

```typescript
// Agent requests permission
await client.request_permission({
  tool: "bash",
  args: { command: "git push origin main" },
  reason: "Push committed changes to remote"
})

// User sees: "Allow agent to run: git push origin main? [Yes/No/Always]"
```

### Our Implementation

```zig
const PermissionRequest = struct {
    tool_name: []const u8,
    args: std.json.Value,
    reason: ?[]const u8,
};

const PermissionResponse = enum {
    allow_once,     // Allow this single execution
    allow_always,   // Allow all future executions of this tool
    deny,           // Reject this execution
};

fn requestPermission(req: PermissionRequest) !PermissionResponse {
    // Check if previously approved
    if (isAlwaysAllowed(req.tool_name, req.args)) {
        return .allow_once;  // Execute without prompting
    }

    // Prompt user
    try stdout.print("\nAgent wants to run: {s}\n", .{req.tool_name});
    try stdout.print("Command: {}\n", .{req.args});
    if (req.reason) |r| {
        try stdout.print("Reason: {s}\n", .{r});
    }
    try stdout.print("\n[A]llow once  [L]always  [D]eny: ", .{});

    const response = try stdin.readByte();
    return switch (response) {
        'a', 'A' => .allow_once,
        'l', 'L' => blk: {
            // Store approval for future use
            try addToAllowList(req.tool_name, req.args);
            break :blk .allow_always;
        },
        'd', 'D' => .deny,
        else => .deny,  // Default to safe option
    };
}
```

### Dangerous Command Detection

```zig
fn isDangerousCommand(cmd: []const u8) bool {
    const dangerous_patterns = [_][]const u8{
        "rm -rf /",
        "dd if=",
        "mkfs",
        "> /dev/sd",
        "curl | bash",
        "wget | sh",
        "--force",
        "DROP TABLE",
        "DROP DATABASE",
    };

    for (dangerous_patterns) |pattern| {
        if (std.mem.indexOf(u8, cmd, pattern) != null) {
            return true;
        }
    }
    return false;
}

fn executeBash(cmd: []const u8) !ToolResult {
    // Always require permission for shell commands
    const approved = try requestPermission(.{
        .tool_name = "bash",
        .args = .{ .string = cmd },
        .reason = if (isDangerousCommand(cmd))
            "⚠️  POTENTIALLY DANGEROUS COMMAND"
        else
            null,
    });

    if (approved == .deny) {
        return ToolResult{
            .success = false,
            .output = "",
            .error_message = "Permission denied by user",
        };
    }

    // Execute the command
    return try runCommand(cmd);
}
```

### Benefits

1. **Security**: User controls what agent can do
2. **Transparency**: User sees all tool executions
3. **Convenience**: "Always allow" for trusted operations
4. **Safety**: Dangerous commands explicitly flagged

**Related**: See [tool-execution.md](tool-execution.md) lines 42-53 for security considerations.

## Pattern 7: Meta Extension Convention

### The Problem

When debugging or adding custom features, you need a place to put extra data without polluting the core data model.

### ACP's Solution

- Custom data goes in `_meta` fields
- Custom methods/tools start with underscore `_`

```typescript
{
  "tool": "read_file",
  "path": "/foo/bar.zig",
  "_meta": {
    "cache_hit": true,
    "read_time_ms": 12,
    "source": "memory_cache"
  }
}
```

This makes debugging easier without cluttering core data.

### Our Implementation

```zig
const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,

    /// Optional metadata (debugging, performance tracking, etc.)
    meta: ?std.json.Value = null,
};

// Usage:
fn readFile(path: []const u8) !ToolResult {
    const start = std.time.milliTimestamp();
    const content = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    const duration = std.time.milliTimestamp() - start;

    return ToolResult{
        .success = true,
        .output = content,
        .meta = .{ .object = .{
            .{ "read_time_ms", .{ .integer = duration } },
            .{ "file_size", .{ .integer = content.len } },
            .{ "cache_hit", .{ .bool = false } },
        }},
    };
}
```

### Logging with Metadata

```zig
fn logToolExecution(name: []const u8, result: ToolResult) !void {
    if (result.meta) |meta| {
        try logger.info("Tool {s}: {}", .{name, meta});
    }
}

// Output: Tool read_file: {"read_time_ms":12,"file_size":4096,"cache_hit":false}
```

### Benefits

1. **Clean separation**: Core vs debugging data
2. **Optional**: Zero overhead if not used
3. **Extensible**: Add new metadata without changing structs
4. **Debugging**: Rich context in logs

## Implementation Checklist

For zig-agent v1, implement these in order of value:

- [x] **Pattern 1: Streaming update enum** (foundation for good UX)
  - [ ] Define `AgentUpdate` union type
  - [ ] Update UI event handlers to pattern match on update type
  - [ ] Map API streaming events to appropriate update types

- [ ] **Pattern 2: Absolute paths** (easy security win)
  - [ ] Add `normalizePath()` function
  - [ ] Validate all tool paths are absolute
  - [ ] Reject relative paths early

- [ ] **Pattern 3: 1-based line numbers** (user clarity)
  - [ ] Use 1-based in all error messages
  - [ ] Convert to 0-based only when indexing
  - [ ] Document convention in code comments

- [ ] **Pattern 6: Permission system** (critical for safety)
  - [ ] Implement `requestPermission()` function
  - [ ] Add dangerous command detection
  - [ ] Store allow-list for approved operations

- [ ] **Pattern 4: Capabilities struct** (needed for subagents in v2)
  - [ ] Define `AgentCapabilities` struct
  - [ ] Filter tools based on capabilities
  - [ ] Use for explore/code/plan agent types

- [ ] **Pattern 5: Session state machine** (helps with error handling)
  - [ ] Define `SessionState` enum
  - [ ] Add state transition validation
  - [ ] Implement error recovery based on state

- [ ] **Pattern 7: Meta extension** (nice-to-have for debugging)
  - [ ] Add `meta` field to `ToolResult`
  - [ ] Log metadata in development mode
  - [ ] Use for performance tracking

## Cross-References

These patterns appear throughout our architecture:

- **Streaming updates** → [interface-design.md](interface-design.md#streaming-update-pattern)
- **Tool design** → [tool-execution.md](tool-execution.md#acp-inspired-tool-patterns)
- **Subagent capabilities** → [architecture.md](architecture.md#subagent-architecture)
- **Session lifecycle** → [conversation-state.md](conversation-state.md)
- **Permission model** → [tool-execution.md](tool-execution.md#security-considerations)
- **Path safety** → [file-operations.md](file-operations.md)

## External References

- [Agent Client Protocol Specification](https://agentclientprotocol.com)
- [ACP Overview - Zed](https://zed.dev/acp)
- [Intro to ACP - goose blog](https://block.github.io/goose/blog/2025/10/24/intro-to-agent-client-protocol-acp/)
- [Agent Client Protocol: The LSP for AI Coding Agents](https://blog.promptlayer.com/agent-client-protocol-the-lsp-for-ai-coding-agents/)

## Summary

We don't implement ACP (too much overhead for standalone CLI), but we adopt its proven patterns:

1. **Streaming update enum** - Separate thoughts/messages/tool calls for proper rendering
2. **Absolute paths only** - Eliminate CWD ambiguity and path traversal bugs
3. **1-based line numbers** - Match editor conventions for user clarity
4. **Capabilities negotiation** - Explicit tool availability, especially for subagents
5. **Session lifecycle** - Clear state boundaries for error handling
6. **Permission requests** - User control over dangerous operations
7. **Meta extension** - Clean debugging data without core pollution

These patterns are **language-agnostic design wisdom** that solve real problems in agent systems.

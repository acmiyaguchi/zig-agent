# Tool Execution

## Overview

The agent must execute tools (read files, run commands, search code) requested by Claude. This must be done safely and efficiently.

## Tool Categories

### File Operations
- **Read**: Read file contents with line ranges
- **Write**: Create or overwrite files
- **Edit**: Make surgical edits to existing files
- **Glob**: Pattern-based file search

### Code Search
- **Grep**: Content search with regex
- **Find**: File name search

### Shell Execution
- **Bash**: Execute arbitrary shell commands (with user permission)

### Analysis
- **Parse**: Syntax tree generation (future)
- **Analyze**: Static analysis (future)

## Execution Model

### Synchronous Execution
Most tools execute synchronously:
1. Receive tool use request from API
2. Execute tool
3. Capture output
4. Send result back to API
5. Continue conversation

### Asynchronous Execution (Future)
For long-running tools:
- Execute in background
- Allow user interaction during execution
- Stream progress updates

## Security Considerations

### Sandboxing
- Restrict file access to workspace directory
- Prevent directory traversal attacks
- Validate all input parameters

### Permission Model
- User confirmation for destructive operations
- Whitelist allowed commands
- No execution of arbitrary downloaded code

### Resource Limits
- Memory limit per tool execution: 10MB
- Timeout per tool: 30 seconds (configurable)
- Max output size: 1MB (truncate if exceeded)

## ACP-Inspired Tool Patterns

**Inspired by**: [Agent Client Protocol (ACP)](../concepts/acp-patterns.md)

These design patterns from ACP improve tool safety, clarity, and reliability:

### Absolute Paths Only

**All file paths must be absolute.** No relative paths allowed.

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

fn validateToolPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return error.RelativePathNotAllowed;
    }

    if (!std.mem.startsWith(u8, path, workspace_root)) {
        return error.PathOutsideWorkspace;
    }
}
```

**Benefits**: Eliminates CWD ambiguity, easier security validation, clearer debugging.

See: [acp-patterns.md](acp-patterns.md#pattern-2-absolute-paths-only)

### 1-Based Line Numbers

**All line numbers are 1-based** to match editor conventions.

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

**Convention**: Use 1-based in all user-facing output and APIs. Convert to 0-based only when indexing arrays.

**Benefits**: Error messages match editor line numbers, no mental offset needed.

See: [acp-patterns.md](acp-patterns.md#pattern-3-1-based-line-numbers)

### Permission Requests

**Always request permission for potentially dangerous operations.**

```zig
const PermissionResponse = enum {
    allow_once,     // Allow this single execution
    allow_always,   // Allow all future executions
    deny,           // Reject this execution
};

fn executeBash(cmd: []const u8) !ToolResult {
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

    return try runCommand(cmd);
}
```

**Dangerous patterns** to detect:
- `rm -rf /`
- `dd if=`
- `mkfs`
- `curl | bash`
- `--force` flags
- SQL `DROP` statements

See: [acp-patterns.md](acp-patterns.md#pattern-6-permission-request-pattern)

### Tool Capabilities

**Explicitly declare what each tool can do.**

```zig
const AgentCapabilities = struct {
    can_read_files: bool = true,
    can_write_files: bool = true,
    can_execute_shell: bool = true,
    max_file_size: usize = 10 * 1024 * 1024,  // 10MB
    max_shell_timeout: u64 = 300_000,          // 5 min
};

fn getToolsForCapabilities(caps: AgentCapabilities) []const Tool {
    var tools = std.ArrayList(Tool).init(allocator);

    if (caps.can_read_files) {
        try tools.append(ReadFileTool);
        try tools.append(GlobTool);
    }

    if (caps.can_write_files) {
        try tools.append(WriteFileTool);
    }

    if (caps.can_execute_shell) {
        try tools.append(BashTool);
    }

    return tools.toOwnedSlice();
}
```

**Use case**: Restrict explore subagents to read-only operations.

See: [acp-patterns.md](acp-patterns.md#pattern-4-capabilities-negotiation)

## Tool Implementation

### File Reading
```zig
fn readFile(allocator: Allocator, path: []const u8,
            offset: usize, limit: usize) ![]const u8 {
    // Validate path is within workspace
    // Open file with read-only access
    // Seek to offset
    // Read up to limit bytes
    // Return content
}
```

### Pattern Matching
```zig
fn glob(allocator: Allocator, pattern: []const u8) ![][]const u8 {
    // Parse glob pattern
    // Walk directory tree
    // Match files against pattern
    // Return sorted list of matches
}
```

### Command Execution
```zig
fn execBash(allocator: Allocator, command: []const u8) !ExecResult {
    // Request user permission
    // Fork/exec shell
    // Capture stdout/stderr
    // Wait for completion with timeout
    // Return exit code and output
}
```

## Error Handling

- File not found: Return clear error to API
- Permission denied: Explain and suggest alternatives
- Timeout: Kill process, report partial output
- Out of memory: Fail gracefully, don't crash

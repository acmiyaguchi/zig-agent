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

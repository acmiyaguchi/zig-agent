# Spec Delta: Subprocess Execution - Shared Infrastructure

**Capability**: `subprocess-execution`
**Change**: `implement-agent-v2`
**Status**: Draft

## Purpose

Provide shared subprocess spawner infrastructure used internally by all new tools (list_directory, search_files, write_file, run_command). This module handles the common concerns of spawning processes, capturing output, enforcing timeouts, and managing exit codes.

## Context

V1 had only `read_file` (pure Zig implementation). V2 adds multiple tools that wrap coreutils:
- Shared subprocess spawner (`src/tools/subprocess.zig`)
- Used internally by list_directory, search_files, write_file, run_command
- Timeout handling (default 5s, configurable)
- Output capture (stdout + stderr combined)
- Exit code handling
- 1MB output cap

**Architectural Insight**: Instead of each tool reimplementing subprocess logic, we centralize it in one place. Each tool wrapper is just ~20-30 LOC that builds a command string and calls `subprocess.execute()`.

## ADDED Requirements

### Requirement: Subprocess module shall provide shared execute function

**Priority**: Critical
**Rationale**: Centralized subprocess spawning used by all tool wrappers

The subprocess module (`src/tools/subprocess.zig`) SHALL provide:
- Function: `execute(allocator, command, timeout_secs, working_dir)`
- Parameters:
  - `allocator` (Allocator): Memory allocator
  - `command` (string): Shell command to execute
  - `timeout_secs` (int): Timeout in seconds
  - `working_dir` (optional string): Working directory (null = current)
- Behavior: Spawn subprocess using `/bin/sh -c`, capture output, return exit code
- Output: Combined stdout + stderr (separated with "--- stderr ---" marker)
- Size limit: Cap output at 1MB (return truncation warning if exceeded)
- Timeout: Kill process if execution exceeds timeout
- Exit code: Return success=true if exit code 0, false otherwise
- Used internally by: list_directory, search_files, write_file, run_command

#### Scenario: Execute simple command

```zig
// Tool wrapper calls: subprocess.execute(allocator, "ls -la", 5, null)
// Expected result:
// - Subprocess spawned: /bin/sh -c "ls -la"
// - Output captured: directory listing
// - Returns: { success: true, output: "[directory listing]" }
```

#### Scenario: Execute command with timeout

```zig
// Tool wrapper calls: subprocess.execute(allocator, "sleep 10", 1, null)
// Expected result:
// - Subprocess spawned
// - Process killed after 1 second
// - Returns: { success: false, error_message: "Command timed out after 1s" }
```

#### Scenario: Command fails with non-zero exit code

```zig
// Tool wrapper calls: subprocess.execute(allocator, "grep 'pattern' /missing/file", 5, null)
// Expected result:
// - Command executed
// - Exit code: 2 (grep error)
// - Returns: { success: false, output: "stderr output", error_message: "Command failed with exit code 2" }
```

#### Scenario: Command with large output

```zig
// Tool wrapper calls: subprocess.execute(allocator, "find / -type f", 30, null)
// Expected result:
// - Output captured up to 1MB
// - Returns: { success: true, output: "[first 1MB of results]\n[Output truncated at 1MB limit]" }
```

#### Scenario: Working directory parameter

```zig
// Tool wrapper calls: subprocess.execute(allocator, "pwd", 5, "/tmp")
// Expected result:
// - Command executed in /tmp
// - Output: /tmp
```

---

### Requirement: Subprocess spawner shall capture both stdout and stderr

**Priority**: High
**Rationale**: Tools need to see error messages to report failures accurately

The subprocess spawner SHALL:
- Capture stdout using pipe
- Capture stderr using pipe
- Combine outputs with "--- stderr ---" separator if both present
- Return combined output to model
- Cap total output at 1MB

#### Scenario: Command with stdout only

```
subprocess.execute(allocator, "echo 'hello'", 5, null)

Output:
hello

Returns: { success: true, output: "hello\n" }
```

#### Scenario: Command with stderr only

```
subprocess.execute(allocator, "ls /nonexistent", 5, null)

Output:
--- stderr ---
ls: cannot access '/nonexistent': No such file or directory

Returns: { success: false, output: "[above]", error_message: "Command failed with exit code 2" }
```

#### Scenario: Command with both stdout and stderr

```
subprocess.execute(allocator, "grep 'pattern' file1.txt file2.txt", 5, null)
(where file1.txt exists but file2.txt doesn't)

Output:
file1.txt:matching line

--- stderr ---
grep: file2.txt: No such file or directory

Returns: { success: false, output: "[above]", error_message: "Command failed with exit code 2" }
```

---

### Requirement: Subprocess spawner is internal infrastructure

**Priority**: Medium
**Rationale**: Subprocess spawner is implementation detail, not user-facing

The subprocess spawner SHALL:
- Be a pure function with no side effects (except subprocess execution)
- Not interact with UI or confirmation system
- Be called by tool wrappers after any confirmation logic
- Return results to caller (tool wrapper)
- Be testable in isolation

**Note**: Confirmation logic lives in the agent, not in subprocess spawner. Tool wrappers simply call subprocess.execute() and return the result.

#### Scenario: Tool wrapper uses subprocess spawner

```
// Tool wrapper (write_file.zig):
pub fn executeWriteFile(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const content = args.object.get("content").?.string;

    // Build command
    const command = try std.fmt.allocPrint(
        allocator,
        "cat > {s} <<'EOF'\n{s}\nEOF",
        .{path, content}
    );
    defer allocator.free(command);

    // Call subprocess spawner (no confirmation logic here)
    return subprocess.execute(allocator, command, 5, null);
}

// Confirmation happens in agent before calling executeWriteFile()
```

---

### Requirement: Subprocess shall timeout if execution exceeds limit

**Priority**: High
**Rationale**: Prevent hanging on infinite loops or blocking commands

The run_command tool SHALL:
- Accept optional `timeout` parameter (default: 5 seconds)
- Track elapsed time during subprocess execution
- Kill subprocess if timeout exceeded
- Return timeout error to model
- User can specify longer timeout for slow operations

#### Scenario: Command completes within timeout

```zig
// Agent receives: run_command(command="sleep 2", timeout=5)
// Expected: Command completes after 2s, returns success
```

#### Scenario: Command exceeds timeout

```zig
// Agent receives: run_command(command="sleep 10", timeout=2)
// Expected result:
// - Process spawned
// - After 2s, process killed
// - Tool returns: { success: false, error_message: "Command timed out after 2s" }
```

#### Scenario: Long-running command with increased timeout

```zig
// Agent receives: run_command(command="find / -name '*.log'", timeout=30)
// Expected: Command allowed to run for up to 30 seconds
```

---

### Requirement: Subprocess spawner shall use /bin/sh for shell features

**Priority**: Medium
**Rationale**: Enable pipes, redirection, globbing, and other shell features

The run_command tool SHALL:
- Execute commands using `/bin/sh -c "<command>"`
- Support shell features: pipes, redirection, globbing, variable expansion
- Work on any Unix system with POSIX shell

#### Scenario: Command with pipes

```zig
// subprocess.execute(allocator, "cat file.txt | grep 'pattern' | wc -l", 5, null)
// Expected: Shell processes pipe, returns line count
```

#### Scenario: Command with redirection

```zig
// subprocess.execute(allocator, "echo 'content' > newfile.txt", 5, null)
// Expected: Shell creates file with content
```

#### Scenario: Command with globbing

```zig
// subprocess.execute(allocator, "ls *.txt", 5, null)
// Expected: Shell expands glob, lists matching files
```

#### Scenario: Complex shell command

```zig
// subprocess.execute(allocator, "for f in *.txt; do wc -l $f; done", 5, null)
// Expected: Shell executes loop, returns line counts for all .txt files
```

---

## MODIFIED Requirements

None - subprocess spawner is new infrastructure that doesn't modify existing requirements. Tool execution and confirmation logic are handled at the agent level (see tool-expansion spec).

---

## Non-Requirements (Out of Scope for v2)

- Confirmation logic (handled by agent, not subprocess spawner)
- Real-time output streaming (deferred to v2.1)
- Interactive command support (vim, less, etc. - not supported)
- Process management (kill, pause, resume - deferred)
- Environment variable customization (use current environment)
- Stdin piping (deferred to v2.1)
- Custom escape/quoting logic (tools responsible for building safe commands)

## Dependencies

- **Requires**: Zig standard library (`std.process`)
- **Provides**: Subprocess spawning infrastructure for tool wrappers
- **Used by**: `list_directory`, `search_files`, `write_file`, `run_command`

## Testing Strategy

**Unit Tests**:
- `subprocess.execute()`: successful execution, failure exit codes, timeout handling
- Output capture: stdout only, stderr only, both combined
- Output truncation at 1MB limit
- Working directory parameter
- Shell features: pipes, redirection, globbing
- Exit code handling: 0, non-zero, timeout

**Integration Tests**:
- Tool wrappers use subprocess spawner correctly
- Commands execute and return results
- Results formatted correctly
- Timeout enforcement works

**Manual Tests**:
- Execute various shell commands
- Verify output capture
- Test timeout with long-running command
- Verify working directory parameter

## Related Specs

- `tool-expansion` - Tool wrappers that use subprocess spawner
- `agent-core` - Tool execution loop with confirmation logic
- `tool-system` (base v1) - Tool interface

## References

- [Design: Hybrid Approach](../../design.md#decision-1-hybrid-approach---structured-tools--escape-hatch)
- [Design: No Sandboxing](../../design.md#decision-3-no-sandboxing---trust-the-user)
- [Design: Timeout Handling](../../design.md#decision-5-timeout-handling-with-configurable-default)
- [Design: Output Capture](../../design.md#decision-6-output-capture-with-1mb-cap)

## Example Internal Usage

### Example: list_directory tool using subprocess spawner

```zig
// src/tools/list_directory.zig
pub fn executeListDirectory(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const recursive = if (args.object.get("recursive")) |r| r.bool else false;

    const command = if (recursive)
        try std.fmt.allocPrint(allocator, "ls -laR {s}", .{path})
    else
        try std.fmt.allocPrint(allocator, "ls -la {s}", .{path});
    defer allocator.free(command);

    // Call shared subprocess spawner
    return subprocess.execute(allocator, command, 5, null);
}
```

### Example: search_files tool using subprocess spawner

```zig
// src/tools/search_files.zig
pub fn executeSearchFiles(allocator: Allocator, args: std.json.Value) !ToolResult {
    const pattern = args.object.get("pattern").?.string;
    const path = args.object.get("path").?.string;

    // Escape single quotes in pattern
    const escaped_pattern = try escapeShellString(allocator, pattern);
    defer allocator.free(escaped_pattern);

    const command = try std.fmt.allocPrint(
        allocator,
        "grep -rn '{s}' {s}",
        .{escaped_pattern, path}
    );
    defer allocator.free(command);

    // Call shared subprocess spawner
    return subprocess.execute(allocator, command, 5, null);
}
```

### Example: write_file tool using subprocess spawner

```zig
// src/tools/write_file.zig
pub fn executeWriteFile(allocator: Allocator, args: std.json.Value) !ToolResult {
    const path = args.object.get("path").?.string;
    const content = args.object.get("content").?.string;

    const command = try std.fmt.allocPrint(
        allocator,
        "cat > {s} <<'EOF'\n{s}\nEOF",
        .{path, content}
    );
    defer allocator.free(command);

    // Call shared subprocess spawner
    return subprocess.execute(allocator, command, 5, null);
}
```

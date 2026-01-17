# Spec Delta: Tool Expansion - Structured Wrappers

**Capability**: `tool-expansion`
**Change**: `implement-agent-v2`
**Status**: Draft

## Purpose

Expand the tool system with structured wrappers around coreutils for common operations: list_directory, search_files, write_file. These tools provide clear, typed interfaces while internally leveraging battle-tested Unix utilities. Read-only tools require no confirmation; destructive tools require Y/n approval.

## Context

V1 had only `read_file`. V2 adds structured tools that internally wrap shell commands:
- `list_directory` - Wraps `ls -la`
- `search_files` - Wraps `grep -rn`
- `write_file` - Wraps `cat > file`
- `run_command` - General escape hatch for anything else

**Key Insight**: Each tool is a thin wrapper (~20-30 LOC) that builds a shell command and calls the shared subprocess spawner. This gives us clear interfaces without reimplementing functionality.

## ADDED Requirements

### Requirement: Tool system shall provide list_directory tool

**Priority**: High
**Rationale**: Directory listing is fundamental for exploring codebases

The Tool Registry SHALL provide `list_directory` tool with:
- Parameters:
  - `path` (string, required): Directory path to list
  - `recursive` (bool, optional): Whether to list recursively (default: false)
- Behavior: Internally executes `ls -la {path}` or `ls -laR {path}` if recursive
- No confirmation required (read-only operation)
- Returns directory listing with permissions, sizes, timestamps

#### Scenario: List current directory

```zig
// Agent receives: list_directory(path=".")
// Tool internally runs: ls -la .
// Expected result:
// - Subprocess spawned
// - Output captured: directory listing
// - Tool returns: { success: true, output: "[listing]" }
// - No confirmation prompt shown
```

#### Scenario: List directory recursively

```zig
// Agent receives: list_directory(path="src", recursive=true)
// Tool internally runs: ls -laR src
// Expected result:
// - Subprocess spawned
// - Output captured: recursive listing
// - Tool returns: { success: true, output: "[recursive listing]" }
```

#### Scenario: List non-existent directory

```zig
// Agent receives: list_directory(path="/nonexistent")
// Tool internally runs: ls -la /nonexistent
// Expected result:
// - Command fails with exit code 2
// - Tool returns: { success: false, output: "ls: cannot access...", error_message: "Command failed with exit code 2" }
```

---

### Requirement: Tool system shall provide search_files tool

**Priority**: High
**Rationale**: Code search is essential for understanding and modifying codebases

The Tool Registry SHALL provide `search_files` tool with:
- Parameters:
  - `pattern` (string, required): Search pattern (regex)
  - `path` (string, required): Directory or file to search
- Behavior: Internally executes `grep -rn '{pattern}' {path}`
- No confirmation required (read-only operation)
- Returns matching lines with file names and line numbers
- Properly escapes single quotes in pattern for shell safety

#### Scenario: Search for pattern found

```zig
// Agent receives: search_files(pattern="TODO", path="src")
// Tool internally runs: grep -rn 'TODO' src
// Expected result:
// - Subprocess spawned
// - Output captured: matching lines with file:line:content format
// - Tool returns: { success: true, output: "src/file.zig:42:// TODO: fix this" }
```

#### Scenario: Search for pattern not found

```zig
// Agent receives: search_files(pattern="NONEXISTENT", path="src")
// Tool internally runs: grep -rn 'NONEXISTENT' src
// Expected result:
// - Command exits with code 1 (no matches)
// - Tool returns: { success: false, output: "", error_message: "Command failed with exit code 1" }
```

#### Scenario: Search with special characters in pattern

```zig
// Agent receives: search_files(pattern="function's", path="src")
// Tool internally runs: grep -rn 'function'"'"'s' src (properly escaped)
// Expected result:
// - Pattern with single quote is safely escaped
// - Search executes correctly
```

---

### Requirement: Tool system shall provide write_file tool

**Priority**: High
**Rationale**: File creation is fundamental for coding tasks

The Tool Registry SHALL provide `write_file` tool with:
- Parameters:
  - `path` (string, required): File path to write
  - `content` (string, required): File content
- Behavior: Internally executes `cat > {path} <<'EOF'\n{content}\nEOF`
- **Requires Y/n confirmation** (destructive operation)
- Overwrites existing file if present
- Creates new file if doesn't exist

#### Scenario: Create new file

```zig
// Agent receives: write_file(path="test.txt", content="hello world")
// User sees prompt: "Execute write_file test.txt? [Y/n]"
// User confirms: Y
// Tool internally runs: cat > test.txt <<'EOF'
//                       hello world
//                       EOF
// Expected result:
// - File created with content
// - Tool returns: { success: true, output: "" }
```

#### Scenario: Overwrite existing file

```zig
// Agent receives: write_file(path="existing.txt", content="new content")
// User sees prompt: "Execute write_file existing.txt? [Y/n]"
// User confirms: Y
// Tool internally runs: cat > existing.txt <<'EOF'
//                       new content
//                       EOF
// Expected result:
// - Existing file overwritten
// - Tool returns: { success: true, output: "" }
```

#### Scenario: User denies write operation

```zig
// Agent receives: write_file(path="important.txt", content="new content")
// User sees prompt: "Execute write_file important.txt? [Y/n]"
// User denies: N
// Expected result:
// - Command NOT executed
// - Tool returns: { success: false, error_message: "Operation cancelled by user" }
```

#### Scenario: Write to invalid path

```zig
// Agent receives: write_file(path="/root/file.txt", content="content")
// User confirms: Y
// Tool internally runs: cat > /root/file.txt <<'EOF'...
// Expected result:
// - Command fails (permission denied)
// - Tool returns: { success: false, output: "bash: /root/file.txt: Permission denied", error_message: "Command failed with exit code 1" }
```

---

### Requirement: Tool system shall provide run_command escape hatch

**Priority**: Medium
**Rationale**: Provides flexibility for operations not covered by structured tools

The Tool Registry SHALL provide `run_command` tool with:
- Parameters:
  - `command` (string, required): Shell command to execute
  - `timeout` (int, optional): Timeout in seconds (default: 5)
  - `working_dir` (string, optional): Working directory (default: current)
- Behavior: Directly executes command via subprocess spawner
- **Requires Y/n confirmation** (potentially destructive)
- Supports full shell features (pipes, redirection, etc.)

#### Scenario: Run simple command

```zig
// Agent receives: run_command(command="echo 'test'")
// User sees prompt: "Execute run_command echo 'test'? [Y/n]"
// User confirms: Y
// Tool internally runs: echo 'test'
// Expected result:
// - Command executes
// - Tool returns: { success: true, output: "test\n" }
```

#### Scenario: Run command with timeout

```zig
// Agent receives: run_command(command="sleep 10", timeout=2)
// User confirms: Y
// Expected result:
// - Process spawned
// - After 2s, process killed
// - Tool returns: { success: false, error_message: "Command timed out after 2s" }
```

#### Scenario: Run command in specific directory

```zig
// Agent receives: run_command(command="pwd", working_dir="/tmp")
// User confirms: Y
// Tool internally runs: pwd (in /tmp)
// Expected result:
// - Command executes in /tmp
// - Tool returns: { success: true, output: "/tmp\n" }
```

---

### Requirement: Read-only tools shall execute without confirmation

**Priority**: High
**Rationale**: Zero friction for safe exploration operations

The agent SHALL:
- Identify read-only tools: `read_file`, `list_directory`, `search_files`
- Execute these tools immediately when requested by model
- Skip confirmation prompt entirely
- Return results directly to model

#### Scenario: Read-only tool executes immediately

```
Agent receives tool call: list_directory(path="src")
Agent: Identify as read-only tool
Agent: Execute immediately (no UI interaction)
Agent: Return results to model
Model: Receives directory listing without any user prompt
```

---

### Requirement: Destructive tools shall require confirmation

**Priority**: High
**Rationale**: Safety guard for operations that modify state

The agent SHALL:
- Identify destructive tools: `write_file`, `run_command`
- Pause execution before running tool
- Request user confirmation via inline Y/n prompt
- Only execute if user confirms (Y/y)
- Return cancellation error if user denies

#### Scenario: Destructive tool requires confirmation

```
Agent receives tool call: write_file(path="file.txt", content="hello")
Agent: Identify as destructive tool
UI: Show prompt: "Execute write_file file.txt? [Y/n]"
User: Press Y
Agent: Execute tool
Agent: Return results to model

Alternative:
User: Press N
Agent: Cancel operation
Agent: Return error to model: "Operation cancelled by user"
```

---

## MODIFIED Requirements

None - these are entirely new tools, no modifications to existing requirements.

---

## Non-Requirements (Out of Scope for v2)

- Edit-in-place tool (use write_file to overwrite)
- Diff preview before write (deferred to v2.1)
- Move/rename tool (use run_command with `mv`)
- Delete tool (use run_command with `rm`)
- Copy tool (use run_command with `cp`)
- Mkdir tool (use run_command with `mkdir`)
- Custom implementations of ls, grep, cat (wrap existing tools instead)

## Dependencies

- **Requires**: `subprocess-execution` (shared subprocess spawner), `agent-core`, `terminal-ui`
- **Provides**: Structured tools for common operations

## Testing Strategy

**Unit Tests**:
- `list_directory`: simple listing, recursive, non-existent path
- `search_files`: pattern found, not found, special characters in pattern
- `write_file`: create new, overwrite existing, invalid path
- `run_command`: simple command, timeout, working directory

**Integration Tests**:
- All tools registered in registry
- Read-only tools execute without confirmation
- Destructive tools trigger confirmation prompts
- Confirmation denial prevents execution
- Tool results formatted correctly

**Manual Tests**:
- List directory and verify output
- Search for pattern across files
- Create new file with write_file
- Run arbitrary command via run_command
- Deny destructive operation and verify cancellation

## Related Specs

- `subprocess-execution` - Shared subprocess spawner infrastructure
- `agent-core` - Tool execution loop with confirmation logic
- `terminal-ui` - Inline confirmation prompts

## References

- [Design: Hybrid Approach](../../design.md#decision-1-hybrid-approach---structured-tools--escape-hatch)
- [Design: Confirmation Only for Destructive Operations](../../design.md#decision-2-confirmation-only-for-destructive-operations)

## Example Workflows

### Workflow: Explore codebase (zero friction)

```
User: "Show me the project structure and find all TODO comments"

Agent: Let me explore the codebase.
list_directory(path=".", recursive=true)
[Executes immediately - no confirmation]
Result: Shows full directory tree

Agent: Now searching for TODOs.
search_files(pattern="TODO", path=".")
[Executes immediately - no confirmation]
Result: src/file1.zig:42:// TODO: fix this
        src/file2.zig:15:// TODO: optimize

Agent: Found 2 TODO comments in the codebase.
```

### Workflow: Create new file (requires confirmation)

```
User: "Create a new test file for the Agent module"

Agent: I'll create a test file.
write_file(path="src/agent/agent_test.zig", content="const std = @import(\"std\");\n\ntest \"agent initialization\" {\n    // TODO: implement\n}\n")
[User sees prompt: "Execute write_file src/agent/agent_test.zig? [Y/n]"]
User confirms: Y
Result: File created successfully

Agent: Test file created at src/agent/agent_test.zig
```

### Workflow: Complex operation via run_command

```
User: "Count the total lines of Zig code in the project"

Agent: I'll use wc to count lines.
run_command(command="find src -name '*.zig' -exec wc -l {} + | tail -1")
[User sees prompt: "Execute run_command find src -name '*.zig'...? [Y/n]"]
User confirms: Y
Result: 1234 total

Agent: The project has 1,234 lines of Zig code.
```

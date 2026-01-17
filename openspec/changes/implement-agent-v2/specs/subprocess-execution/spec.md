# Spec Delta: Subprocess Execution

**Capability**: `subprocess-execution`
**Change**: `implement-agent-v2`
**Status**: Draft

## Purpose

Add subprocess execution capabilities via a single `run_command` tool, enabling the model to leverage existing Unix tools (coreutils/busybox) instead of custom Zig implementations. This transforms the agent from read-only to fully capable of file manipulation, code search, and directory exploration using familiar command-line tools.

## Context

V1 had only `read_file`. V2 adds subprocess execution with:
- Single `run_command` tool that spawns subprocesses
- Timeout handling (default 5s, configurable)
- Output capture (stdout + stderr)
- Exit code handling
- User confirmation for all commands

**Architectural Insight**: Why reimplement `ls`, `grep`, `cat`, `sed` in Zig when they already exist and work perfectly? This approach leverages battle-tested tools, reduces code complexity (~200 LOC vs ~1000 LOC), and provides more power (full shell via `bash -c`).

## ADDED Requirements

### Requirement: Tool system shall support run_command tool

**Priority**: Critical
**Rationale**: Subprocess execution is the core capability enabling all file operations

The Tool Registry SHALL provide `run_command` tool with:
- Parameters:
  - `command` (string, required): Shell command to execute
  - `timeout` (int, optional): Timeout in seconds (default: 5)
  - `working_dir` (string, optional): Working directory (default: current)
- Behavior: Spawn subprocess using `/bin/sh -c`, capture output, return exit code
- Output: Combined stdout + stderr (separated with "--- stderr ---" marker)
- Size limit: Cap output at 1MB (return truncation warning if exceeded)
- Timeout: Kill process if execution exceeds timeout
- Exit code: Return success=true if exit code 0, false otherwise

#### Scenario: Execute simple command

```zig
// Agent receives: run_command(command="ls -la")
// Expected result:
// - Subprocess spawned: /bin/sh -c "ls -la"
// - Output captured: directory listing
// - Tool returns: { success: true, output: "[directory listing]" }
```

#### Scenario: Execute command with timeout

```zig
// Agent receives: run_command(command="sleep 10", timeout=1)
// Expected result:
// - Subprocess spawned
// - Process killed after 1 second
// - Tool returns: { success: false, error_message: "Command timed out after 1s" }
```

#### Scenario: Command fails with non-zero exit code

```zig
// Agent receives: run_command(command="grep 'nonexistent' /missing/file")
// Expected result:
// - Command executed
// - Exit code: 2 (grep no match + error)
// - Tool returns: { success: false, output: "stderr output", error_message: "Command failed with exit code 2" }
```

#### Scenario: Command with large output

```zig
// Agent receives: run_command(command="find / -type f")
// Expected result:
// - Output captured up to 1MB
// - Tool returns: { success: true, output: "[first 1MB of results]\n[Output truncated at 1MB limit]" }
```

#### Scenario: Working directory parameter

```zig
// Agent receives: run_command(command="ls", working_dir="/home/user/project")
// Expected result:
// - Command executed in /home/user/project
// - Output: files in that directory
```

---

### Requirement: run_command shall capture both stdout and stderr

**Priority**: High
**Rationale**: Models need to see error messages to debug command failures

The run_command tool SHALL:
- Capture stdout using pipe
- Capture stderr using pipe
- Combine outputs with "--- stderr ---" separator if both present
- Return combined output to model
- Cap total output at 1MB

#### Scenario: Command with stdout only

```
Agent receives: run_command(command="echo 'hello'")

Tool output:
hello

Tool returns: { success: true, output: "hello\n" }
```

#### Scenario: Command with stderr only

```
Agent receives: run_command(command="ls /nonexistent 2>&1")

Tool output:
ls: cannot access '/nonexistent': No such file or directory

Tool returns: { success: false, output: "ls: cannot access '/nonexistent': No such file or directory\n", error_message: "Command failed with exit code 2" }
```

#### Scenario: Command with both stdout and stderr

```
Agent receives: run_command(command="grep 'pattern' file1.txt file2.txt")
(where file1.txt exists but file2.txt doesn't)

Tool output:
file1.txt:matching line

--- stderr ---
grep: file2.txt: No such file or directory

Tool returns: { success: false, output: "[above]", error_message: "Command failed with exit code 2" }
```

---

### Requirement: Subprocess execution requires user confirmation

**Priority**: High
**Rationale**: User must approve commands before execution for safety

Before executing `run_command`, the system SHALL:
- Pause agent execution
- Display inline confirmation prompt with full command
- Wait for user keypress (Y/y to confirm, N/n/Enter to cancel)
- Only execute if user approves
- Cancel operation if user denies, return error to model

**Note**: `read_file` does NOT require confirmation (read-only tool).

#### Scenario: User confirms command

```
Agent receives: run_command(command="echo 'hello' > test.txt")

UI shows inline prompt:
Execute: echo 'hello' > test.txt? [Y/n]

User presses Y:
- Command executed
- Tool returns: { success: true, output: "" }

User presses N:
- Command NOT executed
- Tool returns: { success: false, error_message: "Operation cancelled by user" }
```

#### Scenario: User denies command

```
Agent receives: run_command(command="rm -rf /important/data")

UI shows inline prompt:
Execute: rm -rf /important/data? [Y/n]

User presses N:
- Command NOT executed
- Tool returns: { success: false, error_message: "Operation cancelled by user" }
- Model receives error and can respond appropriately
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

### Requirement: run_command shall use /bin/sh for shell features

**Priority**: Medium
**Rationale**: Enable pipes, redirection, globbing, and other shell features

The run_command tool SHALL:
- Execute commands using `/bin/sh -c "<command>"`
- Support shell features: pipes, redirection, globbing, variable expansion
- Work on any Unix system with POSIX shell

#### Scenario: Command with pipes

```zig
// Agent receives: run_command(command="cat file.txt | grep 'pattern' | wc -l")
// Expected: Shell processes pipe, returns line count
```

#### Scenario: Command with redirection

```zig
// Agent receives: run_command(command="echo 'content' > newfile.txt")
// Expected: Shell creates file with content
```

#### Scenario: Command with globbing

```zig
// Agent receives: run_command(command="ls *.txt")
// Expected: Shell expands glob, lists matching files
```

#### Scenario: Complex shell command

```zig
// Agent receives: run_command(command="bash -c 'for f in *.txt; do wc -l $f; done'")
// Expected: Shell executes loop, returns line counts for all .txt files
```

---

## MODIFIED Requirements

### Requirement: Agent shall execute tools when requested by model

**Priority**: Critical (Modified)
**Rationale**: Extended to support subprocess execution with confirmation

The Agent SHALL:
- Execute read-only tools immediately when requested by model (read_file)
- Request user confirmation for subprocess execution (run_command)
- Extract tool call ID, name, and arguments from API response
- Look up tool in registry by name
- Parse arguments JSON
- Capture result (success, output, error)
- Format result as tool message
- Append to conversation
- Call API again with tool results

#### Scenario: Read-only tool executes immediately

```zig
// Agent receives tool call: read_file(path="/home/user/README.md")
// Agent: Look up "read_file" in registry
// Agent: Execute immediately (no confirmation needed)
// Agent: Capture output, send to model
// Model receives file contents
```

#### Scenario: run_command waits for confirmation

```zig
// Agent receives tool call: run_command(command="ls -la")
// Agent: Pause execution
// UI: Show inline Y/n prompt: "Execute: ls -la? [Y/n]"
// User: Press Y to approve
// Agent: Execute command, capture result, send to model
// User: Press N to deny
// Agent: Cancel operation, send error to model
```

---

## Non-Requirements (Out of Scope for v2)

- Sandboxing/whitelisting commands (trust user to evaluate safety)
- Real-time output streaming (deferred to v2.1)
- Interactive command support (vim, less, etc. - not supported)
- Command history (deferred to v2.1)
- Diff previews for file modifications (deferred to v2.1)
- Process management (kill, pause, resume - deferred)
- Environment variable customization (use current environment)
- Stdin piping (deferred to v2.1)

## Dependencies

- **Requires**: `agent-core`, `terminal-ui`, `tool-system` (base)
- **Provides**: subprocess execution for `agent-core`

## Testing Strategy

**Unit Tests**:
- `run_command`: successful execution, failure exit codes, timeout handling
- Output capture: stdout only, stderr only, both combined
- Output truncation at 1MB limit
- Working directory parameter
- Shell features: pipes, redirection, globbing

**Integration Tests**:
- Tool registry includes run_command
- Commands execute through agent loop
- Tool results formatted correctly
- Confirmation prompts work
- User cancellation handled correctly

**Manual Tests**:
- List directory: `ls -la`
- Read file: `cat file.txt`
- Create file: `echo 'content' > file.txt`
- Edit file: `sed -i 's/old/new/' file.txt`
- Search files: `grep -rn 'pattern' .`
- Confirm and deny operations
- Timeout handling

## Related Specs

- `agent-core` - Tool execution loop
- `tool-system` (base v1) - Tool interface
- `terminal-ui` - Inline confirmation prompts
- `context-tracking` - Token tracking (unchanged)

## References

- [Design: Single run_command Tool](../../design.md#decision-1-single-run_command-tool-vs-multiple-custom-tools)
- [Design: No Sandboxing](../../design.md#decision-2-no-sandboxing---trust-the-user)
- [Design: Timeout Handling](../../design.md#decision-4-timeout-handling-with-configurable-default)
- [Design: Output Capture](../../design.md#decision-5-output-capture-with-1mb-cap)

## Example Workflows

### Workflow: Multi-file refactoring

```
User: "Replace all occurrences of 'oldFunction' with 'newFunction' in src/"

Agent: Let me search for files containing that pattern first.
run_command(command="grep -rl 'oldFunction' src/")
[User confirms: Y]
Result: src/file1.js, src/file2.js

Agent: I'll update both files.
run_command(command="sed -i 's/oldFunction/newFunction/g' src/file1.js src/file2.js")
[User confirms: Y]
Result: success

Agent: Let me verify the changes.
run_command(command="grep -n 'newFunction' src/file1.js src/file2.js")
[User confirms: Y]
Result: Shows updated lines
```

### Workflow: Explore and create

```
User: "Create a new test file in the tests directory"

Agent: Let me check the tests directory structure.
run_command(command="ls -la tests/")
[User confirms: Y]
Result: Shows existing test files

Agent: I'll create a new test file.
run_command(command="cat > tests/new_test.js <<'EOF'
const assert = require('assert');
describe('New Test', () => {
  it('should pass', () => {
    assert.equal(1, 1);
  });
});
EOF")
[User confirms: Y]
Result: success

Agent: File created. Let me verify.
run_command(command="cat tests/new_test.js")
[User confirms: Y]
Result: Shows file contents
```

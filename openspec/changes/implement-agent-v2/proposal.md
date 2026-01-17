# Change: Implement Agent v2 - Subprocess Execution

**Change ID**: `implement-agent-v2`
**Status**: Draft
**Created**: 2026-01-16

## Summary

Extend zig-agent v1 with subprocess execution capabilities via a single `run_command` tool, leveraging existing Unix tools (coreutils/busybox) instead of reimplementing file operations in Zig. Also adds basic token tracking in the status line. These changes enable practical coding workflows while maintaining strict resource constraints and simplicity.

## Target Users

**Primary**: Developers on resource-constrained devices who need:
- File modification capabilities (not just reading)
- Directory exploration and code search
- Visibility into token usage and context window status
- Familiarity of standard Unix tools (cat, grep, sed, ls)

**Secondary**: DevOps/SRE professionals using remote resource-limited systems over SSH who need integrated development tooling without provisioning full Node-js environments

**Use Cases**:
1. Multi-file edits for refactoring: `cat file.txt` → analyze → `sed -i '...' file.txt` → verify
2. Create new files from scratch: `echo "content" > file.txt` or `cat > file <<EOF`
3. Explore codebase structure: `ls -la`, `find`, `tree`
4. Search across files: `grep -rn "pattern" .`
5. Context-aware development: understand how full the context window is

## Motivation

V1 successfully proved the core agent loop works on resource-constrained devices. However, users quickly discover limitations:

1. **No file editing**: Users must read, modify elsewhere, and re-read - breaks flow
2. **Context opacity**: Users don't know if they're approaching token limits; conversation abruptly stops

**Original v2 Approach (Rejected)**: Implement custom Zig tools for `write_file`, `edit_file`, `list_directory`, `grep_files`, etc. This would have required ~1000 LOC and reimplemented functionality that already exists.

**New v2 Approach (This Proposal)**: Use subprocess execution to leverage existing Unix tools. Why reimplement `ls`, `grep`, `cat`, `sed` when they already work perfectly?

V2 addresses these critical gaps with radical simplicity:
- Single `run_command` tool spawns subprocesses with timeout and output capture
- Model uses standard Unix commands it already knows (`cat`, `ls`, `grep`, `sed`, `echo`, `bash -c`)
- Safety via confirmation prompts (show command, user approves with Y/n)
- No sandboxing/whitelist - trust the user (they're developers on their own machine)
- Token tracking prevents "full context" surprises

**Benefits**:
- Massively simpler implementation (~200 LOC vs ~1000 LOC)
- Battle-tested tools, no bugs to fix
- Works on any Unix system with coreutils or busybox
- Model already knows how to use these commands
- Smaller binary (no custom file manipulation code)

**Deferred to v2.1**:
- Model switching (convenience feature, not core necessity)

## What Changes

### New Capabilities

- **Subprocess Execution**: Single `run_command` tool with parameters:
  - `command` (string): Shell command to execute
  - `timeout` (optional int): Timeout in seconds (default: 5s)
  - `working_dir` (optional string): Working directory (default: current)
- **Output Capture**: Capture stdout + stderr, return to model
- **Exit Code Handling**: Report success/failure based on exit code
- **Token Tracking UI**: Display current tokens used in status line
- **Inline Confirmation**: Simple Y/n prompts before executing any command

### Modified Capabilities

- **Tool Registry**: Add `run_command` tool (keep existing `read_file`)
- **Terminal UI**: Add token count to status line, inline Y/n confirmation prompts
- **API Client**: Track usage from response headers

### Breaking Changes

- **⚠️ BREAKING**: Command execution requires explicit user confirmation
  - Mitigation: Inline Y/n prompt shows full command before approval
  - Rationale: Trust user to evaluate safety (they run `npm install` anyway)

## Impact

### Affected Specs

- `subprocess-execution`: New spec for run_command tool (replaces tool-expansion)
- `context-tracking`: Token tracking (unchanged from previous design)
- `terminal-ui`: Status line display, inline confirmation prompts
- `api-client`: Usage tracking

### Affected Code

- `src/tools/registry.zig`: Register run_command tool
- `src/tools/run_command.zig` (new): Subprocess spawner with timeout
- `src/api/client.zig`: Usage tracking from headers
- `src/ui/terminal.zig`: Status line rendering, inline Y/n prompts

### Performance Impact

- **Binary size**: +~50KB (subprocess spawner) → ~6.9MB total (<10MB budget, smaller than custom tools!)
- **Memory overhead**: +~1MB (subprocess output buffers) → ~52MB peak (within budget, less than custom tools!)
- **Startup time**: +10ms (minimal, registration only)

### User Experience Impact

- **Positive**: Users can complete full coding tasks using familiar Unix tools
- **Positive**: Visibility into token usage prevents surprises
- **Positive**: Model already knows these tools (cat, grep, sed), no learning curve
- **Positive**: Full power of shell available via `bash -c "..."`
- **Negative**: Inline Y/n prompt adds one keystroke per command execution

## Risk Assessment

### High Risk

**Risk**: Arbitrary command execution without sandboxing
- **Mitigation**: Require explicit user confirmation before executing, show full command
- **Rationale**: Users are developers on their own machines. They already run arbitrary commands (`npm install`, `cargo build`, etc.). Trust them to evaluate safety.
- **Fallback**: Users responsible for backups and safe command evaluation

### Medium Risk

**Risk**: Command output too large for memory budget
- **Mitigation**: Cap output at 1MB, return truncation warning if exceeded
- **Fallback**: Users can redirect output to files (`command > output.txt`) and read the file

**Risk**: Subprocess timeout too short for long-running commands
- **Mitigation**: Configurable timeout parameter (default 5s), users can increase for long operations
- **Fallback**: Document timeout behavior, suggest breaking into smaller commands

### Low Risk

**Risk**: Memory overhead from subprocess output buffers exceeds budget
- **Mitigation**: 1MB output cap, arena allocator cleanup per turn

**Risk**: API changes (usage tracking header format)
- **Mitigation**: Graceful degradation if headers missing, reasonable defaults

**Risk**: Token tracking inaccuracy
- **Mitigation**: Use conservative estimates, display as approximate

## Design Principles

- **Constraint-Aware**: All new features respect the 55MB memory budget and <500ms startup goal
- **User Control**: All command execution requires explicit user confirmation
- **Leverage Existing Tools**: Don't reimplement what already exists
- **Trust the User**: They're developers, they know what commands are safe
- **Simplicity First**: ~200 LOC subprocess spawner vs ~1000 LOC custom tools
- **Transparency**: Token tracking surfaces exactly what the user needs to know

## Success Criteria

### Technical
- [ ] Binary builds for x86_64 and armv7l (<10MB)
- [ ] Peak memory usage <55MB during multi-command scenario
- [ ] Token tracking displays in status line
- [ ] Subprocess execution with timeout and output capture
- [ ] run_command tool tested with > 80% code coverage

### User Validation
- [ ] Successfully create a new file: `echo "content" > file.txt`
- [ ] Successfully edit an existing file: `sed -i 's/old/new/' file.txt`
- [ ] List directory contents: `ls -la`
- [ ] Search across files: `grep -rn "pattern" .`
- [ ] Read file contents: `cat file.txt`
- [ ] Observe token count increasing during conversation
- [ ] Attempt command execution, receive Y/n prompt, verify safety

## Timeline and Estimation

**Realistic Estimate**: 5-7 days (much simpler than original design!)

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| **Phase 1: Subprocess Spawner** | 2-3 days | run_command tool with timeout, output capture, exit code handling |
| **Phase 2: Confirmation UI** | 1 day | Inline Y/n prompts before command execution |
| **Phase 3: Context Tracking** | 1-2 days | Token tracking from API, status line display |
| **Phase 4: Integration & Testing** | 1 day | End-to-end scenarios, performance validation |

## v2.1 Roadmap (Deferred Features)

The following features are explicitly deferred to v2.1:

1. **Model Switching** - Dynamic selection between Haiku/Sonnet/Opus
   - Rationale: Convenience feature, not essential for core workflow
   - Prerequisite: Complete v2 and validate subprocess workflow

2. **Command History** - Store and recall previous commands
   - Rationale: Nice-to-have for common operations
   - Prerequisite: Complete basic subprocess execution

3. **Diff Previews** - Show file diffs before confirming sed/write operations
   - Rationale: Nice-to-have but adds UI complexity
   - Prerequisite: Complete basic confirmation flow

4. **Output Streaming** - Stream subprocess output in real-time
   - Rationale: Better UX for long-running commands
   - Prerequisite: Complete basic buffered output capture

## Related Context

- **v1 Proposal**: `openspec/changes/archive/2026-01-16-implement-minimal-viable-agent/proposal.md`
- **v1 Design**: `openspec/changes/archive/2026-01-16-implement-minimal-viable-agent/design.md`

## Next Steps

After approval:
1. Review spec deltas for feasibility
2. Begin Phase 1 (tool expansion - write_file first)
3. Validate atomic write semantics
4. Implement inline confirmation prompts

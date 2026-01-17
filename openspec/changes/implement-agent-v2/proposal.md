# Change: Implement Agent v2 - Hybrid Tool Approach

**Change ID**: `implement-agent-v2`
**Status**: Draft
**Created**: 2026-01-16

## Summary

Extend zig-agent v1 with subprocess execution capabilities using a hybrid approach: individual structured tools wrapping coreutils (read_file, list_directory, search_files, write_file), plus a general escape hatch (run_command). Read-only tools require no confirmation; destructive tools require Y/n prompts. Also adds basic token tracking in the status line. These changes enable practical coding workflows while maintaining strict resource constraints and simplicity.

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

**New v2 Approach (This Proposal)**: Hybrid approach with structured tools wrapping coreutils. Why reimplement `ls`, `grep`, `cat` when they already work perfectly?

V2 addresses these critical gaps with a balanced approach:
- Individual structured tools: `list_directory`, `search_files`, `write_file` (wrap coreutils internally)
- Keep existing `read_file` tool (already works fine in v1)
- General escape hatch: `run_command` for anything else
- Read-only tools (read_file, list_directory, search_files) require NO confirmation
- Destructive tools (write_file, run_command) require Y/n confirmation
- All new tools use shared subprocess spawner infrastructure
- Token tracking prevents "full context" surprises

**Benefits**:
- Clear, typed tool interfaces for common operations
- Read-only workflows have zero friction (no confirmations)
- Simpler implementation (~300 LOC vs ~1000 LOC)
- Battle-tested coreutils under the hood, no bugs to fix
- Works on any Unix system with coreutils or busybox
- Model gets structured tools but can still use shell when needed
- Smaller binary (leverage existing tools)

**Deferred to v2.1**:
- Model switching (convenience feature, not core necessity)

## What Changes

### New Capabilities

- **Structured Read-Only Tools** (no confirmation required):
  - `list_directory` - Wraps `ls -la {path}` with optional recursive flag
    - Parameters: `path` (string), `recursive` (optional bool)
  - `search_files` - Wraps `grep -rn '{pattern}' {path}`
    - Parameters: `pattern` (string), `path` (string)

- **Structured Destructive Tools** (require Y/n confirmation):
  - `write_file` - Wraps `cat > {path} <<'EOF'\n{content}\nEOF`
    - Parameters: `path` (string), `content` (string)
  - `edit_file` - Wraps `sed -i 's/old_text/new_text/g' {path}`
    - Parameters: `path` (string), `old_text` (string), `new_text` (string)
  - `run_command` - General escape hatch for any shell command
    - Parameters: `command` (string), `timeout` (optional int), `working_dir` (optional string)

- **Shared Infrastructure**:
  - Subprocess spawner used by all new tools internally
  - Timeout handling (default: 5s)
  - Output capture (stdout + stderr combined)
  - Exit code handling
  - 1MB output cap with truncation warnings

- **Token Tracking UI**: Display current tokens used in status line
- **Inline Confirmation**: Simple Y/n prompts for destructive operations only

### Modified Capabilities

- **Tool Registry**: Add 4 new tools (keep existing `read_file`)
  - Total: `read_file`, `list_directory`, `search_files`, `write_file`, `run_command`
- **Terminal UI**: Add token count to status line, inline Y/n confirmation prompts
- **API Client**: Track usage from response headers

### Breaking Changes

- **⚠️ BREAKING**: Destructive operations require explicit user confirmation
  - Applies to: `write_file`, `run_command` only
  - Does NOT apply to: `read_file`, `list_directory`, `search_files`
  - Mitigation: Inline Y/n prompt shows full operation before approval
  - Rationale: Read-only tools are safe; destructive tools need user approval

## Impact

### Affected Specs

- `tool-expansion`: New spec for structured tools (list_directory, search_files, write_file)
- `subprocess-execution`: Shared subprocess spawner infrastructure (used internally by all new tools)
- `context-tracking`: Token tracking (unchanged from previous design)
- `terminal-ui`: Status line display, inline confirmation prompts
- `api-client`: Usage tracking

### Affected Code

- `src/tools/registry.zig`: Register 4 new tools
- `src/tools/list_directory.zig` (new): Wraps `ls -la`
- `src/tools/search_files.zig` (new): Wraps `grep -rn`
- `src/tools/write_file.zig` (new): Wraps `cat > file`
- `src/tools/run_command.zig` (new): General escape hatch
- `src/tools/subprocess.zig` (new): Shared subprocess spawner with timeout
- `src/api/client.zig`: Usage tracking from headers
- `src/ui/terminal.zig`: Status line rendering, inline Y/n prompts

### Performance Impact

- **Binary size**: +~80KB (5 tool wrappers + subprocess spawner) → ~7.0MB total (<10MB budget, smaller than custom tools!)
- **Memory overhead**: +~1MB (subprocess output buffers) → ~52MB peak (within budget, less than custom tools!)
- **Startup time**: +15ms (minimal, registration only)

### User Experience Impact

- **Positive**: Read-only workflows (explore, search, read) have ZERO friction - no confirmations
- **Positive**: Clear, structured tool interfaces for common operations
- **Positive**: Users can complete full coding tasks
- **Positive**: Visibility into token usage prevents surprises
- **Positive**: Full power of shell available via `run_command` escape hatch
- **Negative**: Inline Y/n prompt adds one keystroke per destructive operation (write_file, run_command)

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
- [ ] List directory contents using `list_directory` (no confirmation required)
- [ ] Search across files using `search_files` (no confirmation required)
- [ ] Read file contents using `read_file` (no confirmation required)
- [ ] Create a new file using `write_file` (requires Y/n confirmation)
- [ ] Run arbitrary command using `run_command` (requires Y/n confirmation)
- [ ] Observe token count increasing during conversation
- [ ] Verify read-only operations execute immediately without prompts
- [ ] Verify destructive operations show Y/n prompt before execution

## Timeline and Estimation

**Realistic Estimate**: 5-7 days (simpler than original custom tools design!)

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| **Phase 1: Tool Wrappers** | 2-3 days | Shared subprocess spawner, 4 new tool wrappers (list_directory, search_files, write_file, run_command) |
| **Phase 2: Confirmation UI** | 1 day | Inline Y/n prompts for destructive tools only |
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
2. Begin Phase 1 (shared subprocess spawner, then individual tool wrappers)
3. Implement read-only tools first (list_directory, search_files) - no confirmation needed
4. Implement destructive tools (write_file, run_command) with confirmation prompts
5. Validate end-to-end workflows

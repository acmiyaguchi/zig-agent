# Spec: Project Structure

**Capability**: `project-structure`
**Change**: `implement-minimal-viable-agent`
**Status**: Draft

## Purpose

Establish the foundational build system and source code organization for zig-agent v1. This spec defines the Zig build configuration, dependency management, and module structure that all other components build upon.

## Context

The project currently has comprehensive documentation but no implementation. This spec creates the scaffolding that enables incremental development following the architecture defined in `docs/concepts/interface-design.md`.

## ADDED Requirements

### Requirement: Build system shall compile for x86_64 and ARMv7l targets

**Priority**: Critical
**Rationale**: Multi-architecture support is a core project goal (Nokia N900 = ARMv7l)

The build.zig file SHALL:
- Support x86_64-linux-musl target (development)
- Support arm-linux-musleabihf target (N900)
- Allow target selection via `-Dtarget=` flag
- Use musl libc for static linking
- Optimize for size in release builds (`ReleaseSafe` or `ReleaseSmall`)

#### Scenario: Cross-compile for ARM

```bash
# Developer compiles for ARM from x86_64 machine
$ zig build -Dtarget=arm-linux-musleabihf -Doptimize=ReleaseSmall
# Build succeeds
# Binary is created at zig-out/bin/zig-agent
# Binary is statically linked with musl
$ file zig-out/bin/zig-agent
zig-out/bin/zig-agent: ELF 32-bit LSB executable, ARM, statically linked
```

---

### Requirement: Dependency management shall include termbox2 and libxev

**Priority**: Critical
**Rationale**: Core UI dependencies for terminal rendering and event loop

The build.zig.zon file SHALL:
- Declare libxev dependency from GitHub
- Declare termbox2 as system library OR vendored C source
- Specify exact commit hashes for reproducible builds
- Link dependencies to executable

#### Scenario: Build with dependencies

```bash
$ zig build
# Downloads libxev from GitHub
# Links termbox2 (system or vendored)
# Compiles successfully
# Binary includes both dependencies
$ ldd zig-out/bin/zig-agent
# Shows statically linked (no dynamic dependencies except possibly libc)
```

---

### Requirement: Source layout shall follow interface-design.md architecture

**Priority**: High
**Rationale**: Clean separation of concerns enables testing and future UI swapping

The src/ directory structure SHALL:
- Organize code by architectural layer (agent, api, tools, ui)
- Use module.zig convention for package exports
- Separate types from implementation where appropriate
- Follow Zig standard library conventions

```
src/
├── main.zig              # Entry point, wires components together
├── agent/
│   ├── agent.zig         # Core Agent struct and loop
│   └── types.zig         # AgentUpdate, Message, etc.
├── api/
│   ├── client.zig        # APIClient implementation
│   └── types.zig         # Request/Response types
├── tools/
│   ├── registry.zig      # Tool, ToolRegistry, ToolResult
│   └── read_file.zig     # read_file tool implementation
└── ui/
    ├── terminal.zig      # TerminalUI with termbox2 + libxev
    └── termbox.zig       # Zig bindings for termbox2 C library
```

#### Scenario: Import agent module from main

```zig
// src/main.zig
const std = @import("std");
const agent = @import("agent/agent.zig");
const api = @import("api/client.zig");
const ui = @import("ui/terminal.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Can create instances of each module's types
    var api_client = try api.APIClient.init(gpa.allocator(), api_key);
    var my_agent = try agent.Agent.init(gpa.allocator(), &api_client);
    var terminal = try ui.TerminalUI.init(gpa.allocator(), &my_agent);

    try terminal.run();
}
```

---

### Requirement: Build artifacts shall meet size constraints

**Priority**: High
**Rationale**: Resource-constrained target device (N900)

The compiled binary SHALL:
- Be <2MB for ReleaseSmall builds
- Be <5MB for ReleaseSafe builds
- Be statically linked (no runtime dependencies)
- Strip debug symbols in release builds

#### Scenario: Check binary size

```bash
$ zig build -Doptimize=ReleaseSmall
$ ls -lh zig-out/bin/zig-agent
-rwxr-xr-x 1 user user 1.8M Jan 15 10:00 zig-agent
# Size is under 2MB target
```

---

### Requirement: Build shall complete in <30 seconds on modern hardware

**Priority**: Medium
**Rationale**: Fast iteration during development

Clean builds on typical development machine (4+ cores, SSD) SHALL:
- Complete in <30 seconds for debug builds
- Complete in <60 seconds for release builds
- Use incremental compilation effectively

#### Scenario: Clean build timing

```bash
$ rm -rf zig-cache zig-out
$ time zig build
# ... build output ...
real    0m18.234s
# Build completes in < 30 seconds
```

---

### Requirement: Project metadata shall document essential information

**Priority**: Medium
**Rationale**: Discoverability and tooling support

The build.zig.zon file MUST include:
- Project name: "zig-agent"
- Version: "0.1.0" (for v1)
- Minimum Zig version requirement
- Dependencies with locked versions

#### Scenario: View project metadata

```bash
$ cat build.zig.zon
.{
    .name = "zig-agent",
    .version = "0.1.0",
    .minimum_zig_version = "0.11.0",
    .dependencies = .{
        .libxev = .{
            .url = "https://github.com/mitchellh/libxev/archive/...",
            .hash = "12205e8...",
        },
    },
}
```

---

## Non-Requirements (Out of Scope)

- Multi-platform support beyond Linux (no Windows/macOS in v1)
- Debug vs release build modes (simple ReleaseSmall for v1)
- Custom build options beyond target/optimize
- Package manager integration (no Nix, etc.)
- CI/CD pipeline configuration (manual builds for v1)

## Dependencies

- **Zig toolchain**: 0.11.0 or later
- **libxev**: GitHub repository, specific commit
- **termbox2**: System library or vendored C source

## Testing Strategy

**Build Validation**:
- Build for x86_64 succeeds
- Build for armv7l succeeds
- Binary is statically linked
- Binary size is within constraints

**Cross-Platform Testing**:
- x86_64 binary runs on Ubuntu 22.04
- armv7l binary runs in QEMU user mode
- Performance meets targets (<500ms startup)

## Related Specs

- `api-client` - Requires project structure to exist
- `agent-core` - Requires project structure to exist
- `tool-system` - Requires project structure to exist
- `terminal-ui` - Requires project structure and dependencies

## Migration Notes

N/A (greenfield implementation)

## Open Questions

1. **termbox2 integration**: System package vs vendored source?
   - **Decision**: Try system package first, fall back to vendor if unavailable

2. **Zig version**: Require 0.11, 0.12, or latest?
   - **Decision**: Target 0.12 for better ARM support and std.http improvements

## References

- [Zig Build System](https://ziglang.org/learn/build-system/)
- [interface-design.md](../../../../docs/concepts/interface-design.md#project-structure)
- [performance-constraints.md](../../../../docs/concepts/performance-constraints.md)

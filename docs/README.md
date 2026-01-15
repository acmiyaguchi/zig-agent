# Zig-Agent Documentation

## Overview

Zig-agent is a high-performance, resource-efficient coding agent built in Zig. It provides Claude-powered development assistance on constrained devices where the official Claude Code CLI is too resource-intensive.

**Primary target**: Nokia N900 and similar ARMv7l devices with limited RAM and CPU resources.

## Project Goals

- **Ultra-low resource usage**: <50MB RAM, <2MB binary
- **Fast**: <500ms cold start, responsive even on old hardware
- **Cross-platform**: ARMv7l, ARMv8, x86_64
- **Full-featured**: All core Claude Code capabilities
- **No dependencies**: Single static binary

## Documentation Structure

```
docs/
├── README.md (this file)         # Project overview and documentation guide
├── REFERENCES.md                 # External resources and references
└── concepts/                     # Core design concepts
    ├── architecture.md           # Overall system architecture and philosophy
    ├── acp-patterns.md          # Design patterns from Agent Client Protocol
    ├── interface-design.md      # Clean separation: Core, UI, Tools, API
    ├── concurrency-model.md     # Interactive I/O and event loop
    ├── planning-system.md       # Task tracking and TodoWrite tool
    ├── memory-management.md      # Memory allocation and subagent budgets
    ├── conversation-state.md    # Message tracking and serialization
    ├── api-client.md            # Claude API communication
    ├── streaming.md             # SSE response handling
    ├── tool-execution.md        # Tool system design
    ├── file-operations.md       # File I/O implementation
    ├── performance-constraints.md # Target metrics and optimization
    ├── terminal-ui.md           # Terminal interface and rendering
    └── testing-debugging.md     # Memory profiling, debugging, validation
```

## Reading Guide

### For New Contributors

Start here to understand the project:

1. **[architecture.md](concepts/architecture.md)** - System overview and components
2. **[acp-patterns.md](concepts/acp-patterns.md)** - Proven design patterns we adopt
3. **[performance-constraints.md](concepts/performance-constraints.md)** - Why this project exists
4. **[REFERENCES.md](REFERENCES.md)** - Related projects and libraries

### For Implementation

When building specific subsystems:

#### Core Agent Architecture
- [architecture.md](concepts/architecture.md) - Core loop and philosophy
- [acp-patterns.md](concepts/acp-patterns.md) - Streaming updates, session lifecycle, capabilities
- [interface-design.md](concepts/interface-design.md) - Event-driven architecture
- [concurrency-model.md](concepts/concurrency-model.md) - Interactive I/O with libxev
- [planning-system.md](concepts/planning-system.md) - Task tracking
- [conversation-state.md](concepts/conversation-state.md) - Message management
- [memory-management.md](concepts/memory-management.md) - Subagent strategies

#### API Communication
- [api-client.md](concepts/api-client.md) - HTTP client design
- [streaming.md](concepts/streaming.md) - SSE parsing and handling
- [REFERENCES.md](REFERENCES.md#api-and-streaming) - API documentation

#### Tool System
- [tool-execution.md](concepts/tool-execution.md) - Tool dispatch and execution
- [acp-patterns.md](concepts/acp-patterns.md) - Permission model, absolute paths, capabilities
- [file-operations.md](concepts/file-operations.md) - File I/O patterns
- [REFERENCES.md](REFERENCES.md#zig-libraries-and-patterns) - Zig libraries

#### Memory Optimization
- [memory-management.md](concepts/memory-management.md) - Allocator strategies
- [performance-constraints.md](concepts/performance-constraints.md) - Memory budgets
- [REFERENCES.md](REFERENCES.md#memory-management-patterns) - Implementation patterns

### For Performance Tuning

Focus on these documents:

1. **[performance-constraints.md](concepts/performance-constraints.md)** - Metrics and targets
2. **[memory-management.md](concepts/memory-management.md)** - Allocation optimization
3. **[REFERENCES.md](REFERENCES.md#testing-and-benchmarking)** - Profiling tools

### For Testing and Validation

Verify assumptions on real hardware:

1. **[testing-debugging.md](concepts/testing-debugging.md)** - Memory profiling, debugging strategies
2. **[memory-management.md](concepts/memory-management.md)** - Memory budgets to validate
3. **[performance-constraints.md](concepts/performance-constraints.md)** - Performance targets

**Critical**: Test on actual N900 hardware to validate all memory and performance assumptions.

## Concept Documents

Each concept document covers a major subsystem of the agent:

### [architecture.md](concepts/architecture.md)
Describes the overall system design, component relationships, and data flow. Start here for the big picture.

**Key topics**:
- Philosophy: "The model is 80%. Code is 20%."
- Core agent loop pattern (shared by all coding agents)
- System components and interaction patterns
- Subagent architecture for context isolation (v2+)
- Concurrency model (libxev event loop for interactive I/O)

### [acp-patterns.md](concepts/acp-patterns.md)
Design patterns adopted from the Agent Client Protocol that improve safety, clarity, and user experience.

**Key topics**:
- Why we adopt ACP patterns but not the full protocol
- Streaming update enumeration (thought/message/tool separation)
- Absolute paths only (eliminates CWD bugs)
- 1-based line numbers (matches editor conventions)
- Capabilities negotiation (restrict subagent tools)
- Permission request pattern (user control over dangerous ops)
- Session lifecycle state machine
- Meta extension convention for debugging data

**Cross-references**: These patterns appear in [interface-design.md](concepts/interface-design.md), [tool-execution.md](concepts/tool-execution.md), and throughout the codebase.

### [interface-design.md](concepts/interface-design.md)
Defines clean boundaries between core agent logic, UI rendering, tools, and API client.

**Key topics**:
- Event-driven architecture (agent emits events, UI handles them)
- Three core interfaces: AgentInterface, ToolInterface, APIClientInterface
- Project structure and module organization
- Dependency flow (downward only, no cycles)
- Testing strategy (test components independently)
- UI implementations (Terminal, HTTP API, future GUI)

### [concurrency-model.md](concepts/concurrency-model.md)
Explains how to handle interactive features: typing while output streams.

**Key topics**:
- Concurrent I/O requirements (stdin + socket + terminal)
- Event loop (libxev) vs multi-threading vs poll()
- Why libxev wins on constrained devices (efficient, ~100KB overhead)
- Interactive features: Ctrl+C cancellation, progress updates
- Performance on single-core ARM (event loop beats threads 5-10x)

### [planning-system.md](concepts/planning-system.md)
Covers explicit task tracking to prevent "context fade" during multi-step tasks.

**Key topics**:
- TodoWrite tool design and constraints
- Structured planning for complex tasks
- Memory overhead (~3.5KB, negligible)
- Usage patterns and integration strategies

### [memory-management.md](concepts/memory-management.md)
Details the memory allocation strategy critical for running on devices with only 256MB RAM.

**Key topics**:
- Allocator hierarchy (GPA, Arena, Fixed Buffer)
- Memory budgets per component
- Subagent memory budgets (22MB per agent, strategies for constrained devices)
- Sequential vs parallel subagent execution strategies
- Optimization techniques (zero-copy, pooling, arena reuse)

### [conversation-state.md](concepts/conversation-state.md)
Covers efficient data structures for tracking conversation history and minimizing JSON serialization overhead.

**Key topics**:
- In-memory message representation (ring buffers, arena allocators)
- Lazy serialization (only when sending to API)
- Incremental parsing (stream events, don't buffer entire responses)
- Context window management and message pruning

### [api-client.md](concepts/api-client.md)
Explains how we communicate efficiently with the Claude API.

**Key topics**:
- HTTP/2 client design
- Connection management and pooling
- Request lifecycle and error handling

### [streaming.md](concepts/streaming.md)
Covers incremental parsing of Server-Sent Events from the Claude API.

**Key topics**:
- SSE protocol and parsing
- Incremental JSON decoding
- Backpressure and flow control

### [tool-execution.md](concepts/tool-execution.md)
Describes the tool system that executes file operations, shell commands, and code analysis.

**Key topics**:
- Tool categories (file ops, search, shell)
- Security and sandboxing
- Resource limits and timeouts

### [file-operations.md](concepts/file-operations.md)
Details efficient file I/O operations used by the tool system.

**Key topics**:
- Read, write, edit, glob, grep operations
- Memory-mapped I/O for large files
- Path safety and workspace isolation

### [performance-constraints.md](concepts/performance-constraints.md)
Defines target performance metrics based on Nokia N900 hardware specs.

**Key topics**:
- Target hardware specifications
- Performance budgets (memory, latency, throughput)
- ARM-specific optimizations

### [terminal-ui.md](concepts/terminal-ui.md)
Evaluates terminal UI approaches and rendering efficiency strategies.

**Key topics**:
- Library evaluation (ncurses, termbox2, Clay, vaxis, raw ANSI)
- Efficient rendering (buffering, differential updates, rate limiting)
- Display patterns (streaming text, progress indicators, status bars)
- Progressive implementation (raw ANSI → termbox2 → termbox2+Clay)

### [testing-debugging.md](concepts/testing-debugging.md)
Comprehensive guide to validating memory usage, debugging, and profiling on constrained devices.

**Key topics**:
- Zig's built-in memory leak detection (GeneralPurposeAllocator)
- RSS monitoring (`/proc/self/statm`, continuous tracking)
- External profiling tools (Valgrind, Massif, heaptrack, perf)
- Debugging strategies (GDB remote debugging, printf, logging)
- Testing on QEMU (emulated ARM) and real N900 hardware
- Performance benchmarking and acceptance criteria

**Critical**: Test early on real hardware to validate all assumptions!

## References

The **[REFERENCES.md](REFERENCES.md)** document catalogs external resources:

### Similar Projects
Other coding agents and AI assistants (Aider, Continue, Cody)

### Zig Libraries
HTTP clients, JSON parsers, TUI libraries, command execution

### Constrained Device Development
Nokia N900/Maemo resources, ARM optimization guides, embedded Linux

### API Documentation
Claude API docs, SSE protocol, HTTP/2 specifications

### Design Patterns
State machines, memory management patterns, security practices

## Development Workflow

### Research Phase
1. Check **REFERENCES.md** for existing solutions
2. Read relevant concept documents
3. Review similar project implementations

### Design Phase
1. Update or create concept documents with your approach
2. Consider performance constraints from day one
3. Design with memory budgets in mind

### Implementation Phase
1. Follow patterns from concept documents
2. Use Zig standard library where possible
3. Benchmark early and often

### Testing Phase
1. Test on target hardware (ARM emulation or real device)
2. Profile memory usage and performance
3. Validate against targets in performance-constraints.md

## Documentation as Knowledge Base

Our documentation is highly interconnected - each document cross-references related concepts:

### Key Document Relationships

```
architecture.md (hub)
  ├─→ acp-patterns.md (design patterns)
  ├─→ interface-design.md (event system)
  │    └─→ acp-patterns.md (streaming updates)
  ├─→ concurrency-model.md (libxev)
  ├─→ planning-system.md (TodoWrite)
  ├─→ memory-management.md (subagents)
  └─→ tool-execution.md (tools)
       └─→ acp-patterns.md (permissions, capabilities)
            └─→ file-operations.md (path safety)

performance-constraints.md
  ├─→ memory-management.md (budgets)
  ├─→ testing-debugging.md (validation)
  └─→ concurrency-model.md (event loop efficiency)

REFERENCES.md
  └─→ All docs (external resources)
```

### Navigation Tips

1. **Follow cross-references**: Links like `[acp-patterns.md](acp-patterns.md#pattern-1)` jump to specific sections
2. **Check "Related" sections**: Most docs end with related document links
3. **Use this README**: The reading guide groups docs by topic
4. **Start at architecture.md**: The central hub for understanding the system

### Keeping Documentation Current

When updating code:
- Update relevant concept documents
- Add cross-references to related docs
- Update this README if adding new documents
- Check that examples still match implementation

## Future Documentation

As the project evolves, we may add:

- **docs/api/** - Internal API documentation
- **docs/decisions/** - Architecture Decision Records (ADRs)
- **docs/guides/** - Usage guides and tutorials
- **docs/benchmarks/** - Performance benchmark results

## Contributing

When contributing, please:

1. Read the relevant concept documents first
2. Update documentation when changing designs
3. Add references to **REFERENCES.md** when using external resources
4. Keep performance constraints in mind for all changes

## Questions?

- Check concept documents for design details
- Review REFERENCES.md for external resources
- Open an issue for clarification or discussion

---

**Let's build the most efficient coding agent possible! 🚀**

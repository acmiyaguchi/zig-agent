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
    ├── architecture.md           # Overall system architecture
    ├── memory-management.md      # Memory allocation strategies
    ├── api-client.md            # Claude API communication
    ├── streaming.md             # SSE response handling
    ├── tool-execution.md        # Tool system design
    ├── file-operations.md       # File I/O implementation
    ├── performance-constraints.md # Target metrics and optimization
    └── terminal-ui.md           # Terminal interface and rendering
```

## Reading Guide

### For New Contributors

Start here to understand the project:

1. **[architecture.md](concepts/architecture.md)** - System overview and components
2. **[performance-constraints.md](concepts/performance-constraints.md)** - Why this project exists
3. **[REFERENCES.md](REFERENCES.md)** - Related projects and libraries

### For Implementation

When building specific subsystems:

#### API Communication
- [api-client.md](concepts/api-client.md) - HTTP client design
- [streaming.md](concepts/streaming.md) - SSE parsing and handling
- [REFERENCES.md](REFERENCES.md#api-and-streaming) - API documentation

#### Tool System
- [tool-execution.md](concepts/tool-execution.md) - Tool dispatch and execution
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

## Concept Documents

Each concept document covers a major subsystem of the agent:

### [architecture.md](concepts/architecture.md)
Describes the overall system design, component relationships, and data flow. Start here for the big picture.

**Key topics**:
- System components
- Design goals (memory, startup time, efficiency)
- Component interaction patterns

### [memory-management.md](concepts/memory-management.md)
Details the memory allocation strategy critical for running on devices with only 256MB RAM.

**Key topics**:
- Allocator hierarchy (GPA, Arena, Fixed Buffer)
- Memory budgets and limits
- Optimization techniques (zero-copy, pooling)

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

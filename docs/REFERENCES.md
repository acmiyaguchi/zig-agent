# References

This document contains references to other projects, libraries, and resources that can inform our implementation.

## Similar Projects

### Claude Code (Official)
- **Repo**: Closed source (electron-based)
- **Language**: TypeScript/JavaScript
- **Relevant patterns**: Tool execution model, streaming UI
- **What to learn**: API usage patterns, tool definitions
- **What to avoid**: Heavy dependencies, Electron overhead

### Aider
- **Repo**: https://github.com/paul-gauthier/aider
- **Language**: Python
- **Relevant patterns**: Git integration, file editing strategies
- **What to learn**: Diff generation, edit validation
- **What to avoid**: Python runtime overhead

### Continue.dev
- **Repo**: https://github.com/continuedev/continue
- **Language**: TypeScript
- **Relevant patterns**: IDE integration, context management
- **What to learn**: Code indexing, context window management

### Cody (Sourcegraph)
- **Repo**: https://github.com/sourcegraph/cody
- **Language**: TypeScript
- **Relevant patterns**: Code search, embeddings
- **What to learn**: Fast code navigation, caching strategies

### Building Claude Code from Scratch (learn-claude-code)
- **Blog**: https://medium.com/@yashv6655/building-claude-code-from-scratch-a-simple-journey-into-ai-agents-2ca43eccad6e
- **Repo**: https://github.com/shareAI-lab/learn-claude-code
- **Language**: Python
- **Relevant patterns**: Progressive implementation (v0→v4), minimal agent loop, tool execution
- **What to learn**:
  - **Core agent loop**: Simple while loop with tool execution feedback
  - **Progressive complexity**: 50 → 200 → 300 → 450 → 550 lines across 5 versions
  - **Tool patterns**: Bash, Read, Write, Edit as foundational tools
  - **Task decomposition**: TodoManager for explicit planning
  - **Sub-agents**: Spawning isolated child agents with clean context
  - **Skills system**: Domain knowledge loaded on-demand via SKILL.md files
  - **Philosophy**: "The model is 80%. Code is 20%" - simplicity over complexity
- **What to avoid**: Over-engineering the framework (let the model do the work)

## Zig Libraries and Patterns

### HTTP Client
- **std.http**: Built-in HTTP client (std.http.Client)
- **zig-http**: https://github.com/truemedian/hzzp (lightweight HTTP/1.1)
- **zap**: https://github.com/zigzap/zap (web server, client examples)
- **h11**: https://github.com/karlseguin/http.zig (HTTP/1.1 parser)

### JSON Parsing
- **std.json**: Built-in JSON parser
- **zig-json**: https://github.com/getty-zig/json (faster alternative)
- **json.zig**: https://github.com/mlugg/json (streaming parser)

### TLS/SSL
- **std.crypto**: Built-in cryptography
- **Bindings to OpenSSL/LibreSSL**: For TLS support
- **BearSSL**: Lightweight TLS library (consider for embedded)

### Command Execution
- **std.process**: Built-in process spawning
- **std.ChildProcess**: For capturing output

### Terminal UI
- **zig-cli**: https://github.com/sam701/zig-cli (CLI parsing)
- **vaxis**: https://github.com/rockorager/libvaxis (TUI library)
- **ansi-term**: Raw ANSI escape codes (minimal dependency)

### File Watching
- **std.fs.watch**: Platform-specific file watching (limited)
- **inotify** (Linux): Direct system API for file events

### Testing
- **zig test**: Built-in test framework
- **zig-bench**: https://github.com/Hejsil/zig-bench (benchmarking)

## Constrained Device Development

### Nokia N900 / Maemo
- **Maemo SDK**: https://wiki.maemo.org/Documentation
- **Scratchbox**: Cross-compilation environment
- **QEMU ARM**: Emulation for testing
- **Community**: talk.maemo.org

### ARM Optimization
- **ARM NEON**: SIMD intrinsics for ARM
- **ARM Developer Docs**: https://developer.arm.com/documentation
- **Zig ARM Backend**: Built-in ARM code generation

### Embedded Linux
- **musl libc**: Lightweight C library (Zig compatible)
- **BusyBox**: Minimal Unix tools (for testing in constrained envs)
- **Alpine Linux**: Minimal distro (for testing)

## API and Streaming

### Claude API
- **Docs**: https://docs.anthropic.com/
- **API Reference**: https://docs.anthropic.com/en/api/
- **Streaming**: Server-Sent Events (SSE) format
- **Rate Limits**: Documented per tier

### SSE (Server-Sent Events)
- **Spec**: https://html.spec.whatwg.org/multipage/server-sent-events.html
- **Examples**: Many JavaScript examples, few low-level
- **Parsing**: Simple line-based protocol

### HTTP/2
- **RFC 7540**: HTTP/2 specification
- **nghttp2**: C library (potential binding target)
- **h2**: Rust implementation (for reference)

## Memory Management Patterns

### Arena Allocators
- **Zig std.heap.ArenaAllocator**: Built-in arena
- **Pattern**: Used in compilers, game engines
- **Reference**: "Fast Bump Allocation" strategies

### Object Pools
- **Pattern**: Pre-allocate and reuse objects
- **Example**: Connection pools, buffer pools
- **Zig**: Custom pool with ArrayList or HashMap

### Zero-Copy Parsing
- **Pattern**: Parse in-place without allocating
- **Examples**: simdjson, Zig's std.json (streaming)
- **Benefits**: Lower memory, fewer allocations

## Build and Distribution

### Static Linking
- **Zig**: Native static linking support
- **musl**: For glibc-free static binaries
- **Advantages**: Single binary, no dependencies

### Cross-Compilation
- **Zig**: First-class cross-compilation
- **Targets**: `zig targets` lists all supported
- **Example**: `zig build -Dtarget=arm-linux-musleabihf`

### Size Optimization
- **-O ReleaseSmall**: Optimize for binary size
- **Strip**: Remove debug symbols
- **UPX**: Executable compression (optional)

## Testing and Benchmarking

### Performance Testing
- **Valgrind**: Memory profiling (on x86_64)
- **perf**: Linux profiling tool
- **heaptrack**: Memory leak detection
- **hyperfine**: Command-line benchmarking

### Cross-Architecture Testing
- **QEMU User Mode**: Run ARM binaries on x86_64
- **QEMU System Mode**: Full ARM system emulation
- **Docker**: Multiarch builds with buildx

### CI/CD
- **GitHub Actions**: Free for open source
- **Multi-arch builds**: Use action-rs or custom Docker
- **Artifact hosting**: GitHub Releases

## Relevant Design Patterns

### State Machines
- **Use case**: SSE parsing, conversation flow
- **Pattern**: Explicit states, clear transitions
- **Zig**: Tagged unions perfect for this

### Command Pattern
- **Use case**: Tool execution, undo/redo
- **Pattern**: Encapsulate operations as objects
- **Zig**: Structs with function pointers

### Observer Pattern
- **Use case**: UI updates from streaming events
- **Pattern**: Callbacks or channels
- **Zig**: Function pointers or event queues

### Strategy Pattern
- **Use case**: Different allocators, parsers
- **Pattern**: Runtime polymorphism via interfaces
- **Zig**: Comptime or runtime dispatch

## Security References

### Input Validation
- **OWASP**: Input validation cheat sheet
- **Pattern**: Allowlist over blocklist
- **Zig**: Compile-time validation where possible

### Sandboxing
- **seccomp** (Linux): System call filtering
- **pledge/unveil** (OpenBSD): Capability-based security
- **namespaces**: Linux containerization primitives

### Safe String Handling
- **Pattern**: Length-prefixed strings (Zig default)
- **Avoid**: C-style null-terminated strings
- **Zig**: []const u8 slices (bounds checked)

## Documentation

### API Documentation
- **zig doc**: Built-in doc generator
- **Doc comments**: /// for public APIs
- **Examples**: Include code examples in docs

### Architecture Decision Records (ADRs)
- **Pattern**: Document important decisions
- **Format**: Markdown with context, decision, consequences
- **Location**: docs/decisions/ (future)

## Community Resources

### Zig Community
- **Zig Discord**: Active community
- **Zig Forum**: ziggit.dev
- **Zig News**: zigmonthly.org
- **Learning**: ziglearn.org

### Mobile Linux
- **postmarketOS**: Linux for mobile devices
- **Mobian**: Debian for mobile
- **Community**: Mobile Linux forums

### ARM Development
- **ARM Community**: community.arm.com
- **NEON Intrinsics**: ARM SIMD programming
- **Cross-compilation**: Embedded Linux wiki

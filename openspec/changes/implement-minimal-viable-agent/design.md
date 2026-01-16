# Design: Implement Minimal Viable Agent

**Change ID**: `implement-minimal-viable-agent`

This document captures technical decisions and their rationale for the v1 implementation.

## Context

We're building a minimal coding agent targeting resource-constrained devices (Nokia N900: ARMv7l, 256MB RAM). The design must balance functionality with strict resource limits.

## Goals / Non-Goals

### Goals
- Prove the core agent loop works end-to-end
- Validate termbox2 + libxev integration
- Establish foundation for incremental feature additions
- Meet performance targets (<50MB RAM, <500ms startup)

### Non-Goals
- Full feature parity with Claude Code
- Production-grade error recovery
- Multi-model support
- Subagent architecture

## Technical Decisions

### Decision 1: Model Selection - Hardcode claude-sonnet-4.5

**Choice**: Hardcode `anthropic/claude-sonnet-4.5` via OpenRouter

**Alternatives Considered**:
1. Dynamic model selection (user config)
2. Auto-selection based on task complexity
3. Multiple model support

**Rationale**:
- Sonnet 4.5 is the best balance of capability vs cost for coding tasks
- Adding model selection increases complexity without v1 value
- OpenRouter provides unified API regardless of model
- Can add model selection in v2 without architectural changes

**Trade-offs**:
- Users can't optimize cost by using Haiku for simple queries
- No fallback if Sonnet is unavailable
- Acceptable for v1 proof-of-concept

---

### Decision 2: No Retry Logic in v1

**Choice**: Return errors immediately, no automatic retries

**Alternatives Considered**:
1. Exponential backoff (3 retries: 1s/2s/4s)
2. Infinite retry with user cancellation
3. Configurable retry policy

**Rationale**:
- Simplifies initial implementation
- Users can manually retry
- Transient errors (429, 503) are visible for debugging
- v1.1 will add simple backoff

**Trade-offs**:
- Users see more errors that could be auto-recovered
- Acceptable for v1 - users expect some rough edges

**v1.1 Plan**: Add exponential backoff with 3 retries (1s, 2s, 4s delays)

---

### Decision 3: termbox2 for Terminal UI

**Choice**: Use termbox2 C library for terminal rendering

**Alternatives Considered**:
1. Raw ANSI escape sequences
2. ncurses
3. notcurses
4. Custom Zig TUI library

**Rationale**:
- termbox2 is minimal and well-tested
- Clean C API is easy to bind from Zig
- Handles terminal quirks (different terminal emulators)
- Small footprint (~50KB added to binary)

**Trade-offs**:
- C dependency adds integration complexity
- May fail on exotic terminals
- Architecture allows swapping to raw ANSI if needed

**Fallback Plan**: If termbox2 fails on ARM, implement raw ANSI backend:
- Use standard ANSI escape sequences
- Less portable but simpler
- No external dependency

---

### Decision 4: libxev for Event Loop

**Choice**: Use libxev for single-threaded concurrent I/O

**Alternatives Considered**:
1. Multi-threading (std.Thread)
2. Raw poll() syscall
3. async/await (Zig's suspend/resume)

**Rationale**:
- Single-threaded model matches hardware (single-core ARM)
- Avoids thread stack memory overhead (3-6MB per thread)
- Zero runtime allocations
- Production-tested in other Zig projects

**Trade-offs**:
- Callback-based code is more complex than blocking
- Learning curve for event-driven patterns
- Worth it for memory savings

---

### Decision 5: 16KB SSE Line Buffer

**Choice**: Use 16KB buffer for parsing SSE lines

**Alternatives Considered**:
1. 4KB buffer (original proposal)
2. Dynamic growth up to 64KB
3. Streaming JSON parser

**Rationale**:
- Claude tool call arguments can exceed 4KB (multi-file edits)
- 16KB handles 99%+ of real-world cases
- Fixed size avoids allocation complexity
- Memory cost is acceptable (16KB of 50MB budget = 0.03%)

**Trade-offs**:
- Very large tool calls (>16KB) will fail
- Acceptable limitation for v1

---

### Decision 6: Memory Protection Strategy

**Choice**: Soft limits with user warnings, not hard enforcement

**Implementation**:
```
RSS < 40MB: Normal operation
RSS 40-45MB: Warn user, continue accepting input
RSS > 45MB: Refuse new input, emit error event
```

**Alternatives Considered**:
1. Hard limit with process termination
2. No limits (let OOM killer handle it)
3. Aggressive memory reclamation

**Rationale**:
- Soft limits give user time to react
- Better UX than sudden termination
- 45MB soft limit leaves ~5MB headroom before 50MB target

**Trade-offs**:
- Not foolproof - a single large allocation could still OOM
- Acceptable for v1 - protects against gradual memory growth

---

### Decision 7: Static Linking with musl

**Choice**: Static linking with musl libc for all targets

**Alternatives Considered**:
1. Dynamic linking with glibc
2. Mixed (static code, dynamic libc)
3. Platform-specific builds

**Rationale**:
- Single binary deployment, no runtime dependencies
- Works on old systems (Maemo 5 has old glibc)
- Consistent behavior across distributions
- Zig makes this trivial

**Trade-offs**:
- Slightly larger binary than dynamic linking
- Can't benefit from system library updates
- Worth it for deployment simplicity

---

## Risks / Trade-offs Summary

| Decision | Risk | Mitigation |
|----------|------|------------|
| Hardcoded model | Model unavailability | Manual OpenRouter dashboard fallback |
| No retries | User frustration | v1.1 adds backoff |
| termbox2 | ARM compatibility | ANSI fallback documented |
| 16KB buffer | Large tool calls fail | Accept limitation for v1 |
| Soft memory limits | OOM still possible | Leave headroom, monitor |

## Open Questions

1. **SSL/TLS on ARM**: Does Zig's bundled TLS work correctly on ARMv7l?
   - Will validate during implementation
   - Fallback: Use curl subprocess (adds dependency)

2. **termbox2 + libxev interaction**: Any conflicts between their event models?
   - Will validate during T15 integration
   - Fallback: Sequential polling instead of integrated loop

## References

- [architecture.md](../../docs/concepts/architecture.md)
- [performance-constraints.md](../../docs/concepts/performance-constraints.md)
- [acp-patterns.md](../../docs/concepts/acp-patterns.md)

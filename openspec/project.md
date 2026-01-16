# Project Context

## Purpose

zig-agent is a lightweight coding agent built in Zig, designed to run on resource-constrained devices (Nokia N900, Raspberry Pi, etc.) where Node.js-based tools like Claude Code are too heavy.

**Goals:**
- Ultra-low resource usage (<50MB RAM, <2MB binary)
- Fast cold start (<500ms)
- Cross-platform (ARMv7l, ARMv8, x86_64)
- Single static binary, no runtime dependencies

## Tech Stack

- **Language**: Zig 0.14.0+
- **Event Loop**: libxev (efficient async I/O)
- **Terminal UI**: termbox2 (lightweight ncurses alternative)
- **API**: OpenRouter (Claude via OpenAI-compatible API)
- **Testing**: pytest + tmux harness for UI tests

## Project Conventions

### Code Style

- Follow Zig standard library conventions
- Use descriptive names (no abbreviations except well-known: `ctx`, `ptr`, `buf`)
- Error handling: return errors, don't panic
- Memory: prefer arena allocators for request-scoped data

### Architecture Patterns

- **Event-driven**: Agent emits events, UI subscribes
- **Streaming**: Parse SSE incrementally, never buffer full responses
- **Tool execution**: Synchronous within agent loop
- **Memory protection**: Monitor RSS, warn at 40MB, refuse at 45MB

### Testing Strategy

- Unit tests: `zig build test`
- Integration tests: pytest with tmux harness (for termbox2 UI)
- Manual tests: `manual_test_*.zig` binaries

### Git Workflow

- Main branch: always buildable
- Commits: imperative mood, reference task IDs (T15, T16, etc.)
- No force pushes to main

## Domain Context

This is a **coding agent** - an AI assistant that can read/write code, execute tools, and have multi-turn conversations. Key concepts:

- **Agent loop**: User message → API call → Tool calls → Response
- **Streaming**: API responses arrive as SSE chunks
- **Tools**: Functions the model can call (read_file, write_file, etc.)
- **Context window**: Limited token budget for conversation history

## Important Constraints

- **Memory**: Target devices have 256MB-1GB RAM
- **CPU**: Single-core ARM, no SIMD
- **Network**: May be slow/unreliable
- **Storage**: Limited, prefer small binaries

## External Dependencies

- **OpenRouter API**: https://openrouter.ai/docs
- **termbox2**: Vendored in `vendor/termbox2/`
- **libxev**: Fetched via `build.zig.zon`

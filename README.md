# zig-agent

A lightweight, resource-efficient coding agent built in Zig. Designed to run on constrained devices like the Nokia N900 where the official Claude Code CLI is too resource-intensive.

## Current Status: v1 MVP

The minimal viable agent is functional with core features:

| Feature | Status |
|---------|--------|
| OpenRouter API streaming | Working |
| Terminal UI (termbox2) | Working |
| Event loop (libxev) | Working |
| Tool: read_file | Working |
| Memory protection | Working |
| Ctrl+C clean exit | Working |

### What Works

- Interactive REPL with colored terminal UI
- Streaming responses from Claude (via OpenRouter)
- File reading tool for the agent to inspect code
- Memory usage warnings at 40MB, refusal at 45MB
- Keyboard input while streaming (non-blocking I/O)
- Clean shutdown via Ctrl+C or `quit`/`exit` commands

### Not Yet Implemented

- Additional tools (write_file, edit, glob, grep, bash)
- Subagent spawning
- Plan mode
- Context window pruning
- ARM hardware testing

## Requirements

- Zig 0.14.0+
- OpenRouter API key

## Quick Start

```bash
# Set your API key
export OPENROUTER_API_KEY="sk-or-..."

# Build
zig build

# Run
./zig-out/bin/zig-agent
```

## Usage

Once running, you'll see a `>` prompt. Type messages to interact with Claude:

```
> Read the file src/main.zig and explain what it does
```

The agent can read files in the current directory using the `read_file` tool.

**Commands:**
- `quit` or `exit` - Exit the agent
- `Ctrl+C` - Force exit
- `Up/Down arrows` - Scroll output history

## Project Structure

```
src/
├── main.zig           # Entry point, libxev event loop
├── agent/
│   ├── agent.zig      # Core agent loop, tool execution
│   └── types.zig      # AgentUpdate event types
├── api/
│   ├── client.zig     # OpenRouter HTTP client, SSE streaming
│   └── types.zig      # API request/response types
├── tools/
│   ├── registry.zig   # Tool registry
│   └── read_file.zig  # File reading tool
└── ui/
    ├── terminal.zig   # Terminal UI (colors, scrolling, input)
    └── termbox.zig    # termbox2 Zig bindings
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    main.zig                             │
│  ┌─────────────────────────────────────────────────┐   │
│  │              InteractiveMode                     │   │
│  │  ┌─────────┐  ┌──────────┐  ┌──────────────┐   │   │
│  │  │xev.Loop │──│ termbox  │──│  TerminalUI  │   │   │
│  │  └────┬────┘  └──────────┘  └──────┬───────┘   │   │
│  │       │                            │            │   │
│  │       │ poll TTY fd                │ render     │   │
│  │       ▼                            ▼            │   │
│  │  ┌─────────────────────────────────────────┐   │   │
│  │  │                 Agent                    │   │   │
│  │  │  ┌───────────┐  ┌────────────────────┐  │   │   │
│  │  │  │ APIClient │  │   ToolRegistry     │  │   │   │
│  │  │  │ (OpenRouter)│ │ (read_file, ...)  │  │   │   │
│  │  │  └───────────┘  └────────────────────┘  │   │   │
│  │  └─────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Performance Targets

| Metric | Target | Status |
|--------|--------|--------|
| Binary size | <2MB | TBD |
| Peak memory | <50MB | TBD |
| Cold start | <500ms | TBD |
| Idle CPU | <1% | TBD |

## Development

```bash
# Run tests
zig build test

# Run with tmux (for termbox testing)
uv run --with pytest pytest scripts/test_termbox.py -v

# Manual test binaries
zig build && ./zig-out/bin/manual_test_ui
```

## Documentation

See [docs/README.md](docs/README.md) for detailed architecture documentation.

## License

MIT

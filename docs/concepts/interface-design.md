# Interface Design

## Overview

Clean separation between core agent logic and UI rendering enables:
- **Testability**: Test agent logic without UI
- **Flexibility**: Swap UI implementations (TUI, GUI, HTTP API)
- **Maintainability**: Changes to UI don't affect core logic

This document defines the contracts and boundaries between system components.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────┐
│                    User Input                       │
│         (stdin, files, command-line args)           │
└───────────────────┬─────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────┐
│                  UI Layer                           │
│   (Terminal, HTTP Server, Desktop App, etc.)       │
│                                                     │
│   - Parse user input                                │
│   - Render agent output                             │
│   - Handle interactive events                       │
└───────────────────┬─────────────────────────────────┘
                    │ AgentInterface (Event-driven)
                    ▼
┌─────────────────────────────────────────────────────┐
│                 Agent Core                          │
│         (UI-agnostic business logic)                │
│                                                     │
│   - Conversation management                         │
│   - Planning (TodoWrite)                            │
│   - API communication                               │
│   - Tool orchestration                              │
└───────────┬──────────────────┬──────────────────────┘
            │                  │
            │ ToolInterface    │ APIClientInterface
            ▼                  ▼
┌────────────────────┐  ┌──────────────────────────┐
│   Tool Executor    │  │     API Client           │
│                    │  │                          │
│  - Bash            │  │  - HTTP/2 client         │
│  - File ops        │  │  - SSE parser            │
│  - Code search     │  │  - Streaming             │
└────────────────────┘  └──────────────────────────┘
```

## Core Design Principle

**Event-driven decoupling**: The agent core emits events upward to the UI layer and receives commands downward. The UI never directly calls rendering functions from within core logic.

```
UI Layer:
  ├─ Receives events from core (text_chunk, tool_started, error)
  ├─ Renders to terminal/HTTP/GUI
  └─ Sends commands to core (executeTurn, cancel)

Agent Core:
  ├─ Emits events (no UI knowledge)
  ├─ Receives commands
  └─ Orchestrates API + Tools
```

## Interface 1: AgentInterface (Core ↔ UI)

### Event Types

The agent emits events to notify the UI of state changes:

| Event | Purpose | Data |
|-------|---------|------|
| `text_chunk` | Streaming response from Claude | Text content |
| `tool_started` | Tool execution beginning | Tool name, arguments |
| `tool_completed` | Tool execution finished | Tool name, output, duration |
| `thinking` | Agent is processing | (no data - show spinner) |
| `turn_complete` | Conversation turn finished | Success flag, token count |
| `error` | Something went wrong | Error message, severity |

### Command Interface

The UI sends commands to the agent:

| Command | Purpose | Parameters |
|---------|---------|------------|
| `executeTurn()` | Start a new conversation turn | User input text |
| `cancel()` | Stop current operation | (none) |
| `getState()` | Query current agent state | (none) |

### Event Handler Contract

**UI implements**: A callback that receives events from the agent.

**Signature**: `handleEvent(event: AgentEvent) → void`

**Agent calls this** whenever something happens (new text, tool execution, etc.)

**UI decides** how to render each event (terminal output, HTTP SSE, GUI update, etc.)

### State Exposure

Agent exposes read-only state for UI to display:

- `is_busy: bool` - Currently processing?
- `current_tool: ?string` - Which tool is running?
- `conversation_length: usize` - Number of messages
- `tokens_used: usize` - Total tokens consumed

UI queries this state but **cannot modify it** (unidirectional data flow).

## Interface 2: ToolInterface (Core ↔ Tools)

### Plugin Architecture

Tools are plugins that implement a common interface. The agent core doesn't know about specific tools, only the interface.

### Tool Contract

Each tool provides:

| Method | Purpose | Returns |
|--------|---------|---------|
| `name()` | Tool identifier | String |
| `description()` | What this tool does | String |
| `execute(args)` | Run the tool | ToolResult (success, output, error) |

### Tool Registry

The core maintains a registry of available tools:

- `register(tool)` - Add a tool to registry
- `get(name)` - Look up tool by name
- `execute(name, args)` - Run a tool by name

### Tool Result

All tools return a standard result structure:

- `success: bool` - Did it work?
- `output: string` - Tool output (stdout/file contents/etc.)
- `error_message: ?string` - If failed, why?

### Benefit: Extensibility

Adding new tools doesn't require modifying agent core. Just implement the interface and register.

## Interface 3: APIClientInterface (Core ↔ API)

### Streaming Event Model

The API client emits events as the Claude API streams responses:

| Event | When | Data |
|-------|------|------|
| `message_start` | Message begins | Message ID, model |
| `content_delta` | Text chunk arrives | Text content |
| `tool_use` | Model requests tool | Tool name, ID, arguments (JSON) |
| `message_stop` | Message complete | Token usage metadata |
| `error` | API error | Error message |

### Request Structure

The agent sends requests with:

- Model name
- Conversation messages (history)
- Available tools (definitions)
- Max tokens

### Stream Handler Contract

**Agent core implements**: A callback that receives API events.

**Signature**: `handleAPIEvent(event: APIEvent) → void`

**API client calls this** as events arrive from the network.

**Agent core decides** what to do (emit to UI, execute tool, update state).

### Benefits

- API client is **swappable** (real HTTP client vs mock for testing)
- Streaming is **transparent** to agent core (just receives events)
- Error handling is **unified** (errors are just another event type)

## Data Flow Example

### User Types "analyze this file"

```
1. UI: Reads stdin → "analyze this file"
2. UI → Agent: executeTurn("analyze this file")
3. Agent → API: Send request with messages + tools
4. API → Agent: message_start event
5. Agent → UI: thinking event
   └─ UI renders spinner
6. API → Agent: tool_use event (bash, "ls")
7. Agent → Tool Registry: execute("bash", "ls")
8. Tool → Agent: ToolResult { output: "file1.txt\nfile2.txt" }
9. Agent → UI: tool_started event
   └─ UI renders "Executing bash..."
10. Agent → UI: tool_completed event
    └─ UI renders "✓ bash (15ms)"
11. Agent → API: Send tool result
12. API → Agent: content_delta events (text chunks)
13. Agent → UI: text_chunk events (each chunk)
    └─ UI renders streaming text
14. API → Agent: message_stop event
15. Agent → UI: turn_complete event
    └─ UI renders "[42 tokens]"
```

**Key insight**: Agent orchestrates but never renders. UI receives events and decides how to display.

## Project Structure

```
src/
├── main.zig                  # Entry point (choose UI)
│
├── agent/                    # Core agent (UI-agnostic)
│   ├── agent.zig             # Agent interface + orchestration
│   ├── conversation.zig      # Message history management
│   ├── planning.zig          # TodoWrite tool implementation
│   └── subagent.zig          # Subagent spawning logic
│
├── api/                      # API client (agent-agnostic)
│   ├── client.zig            # HTTP/2 client + SSE parser
│   ├── streaming.zig         # Event emission from SSE stream
│   └── types.zig             # Request/Response types
│
├── tools/                    # Tool implementations
│   ├── registry.zig          # Plugin registry
│   ├── bash.zig              # Bash tool
│   ├── file.zig              # File operations (read/write/edit)
│   └── search.zig            # Grep/glob tools
│
└── ui/                       # UI implementations
    ├── terminal.zig          # Terminal UI (TUI with libxev)
    ├── http.zig              # HTTP API server (optional)
    └── desktop.zig           # Desktop GUI (future)
```

## Dependency Flow

```
Dependencies flow downward only (no cycles):

main.zig
  ↓
ui/ (terminal.zig, http.zig)
  ↓
agent/ (agent.zig, conversation.zig)
  ↓ ↓
  ↓ └─→ api/ (client.zig, streaming.zig)
  ↓
  └────→ tools/ (registry.zig, bash.zig, file.zig)
```

**Rules**:
- UI depends on agent (not vice versa)
- Agent depends on API client and tools
- API client and tools are independent of each other
- No circular dependencies

## UI Implementation Patterns

### Terminal UI

**Responsibilities**:
- Read stdin (using libxev for non-blocking)
- Render events to stdout (ANSI escape codes)
- Handle Ctrl+C and interactive commands

**Event handling**:
- `text_chunk` → Write to stdout immediately (streaming)
- `tool_started` → Print "> Running bash..."
- `tool_completed` → Print "✓ bash (15ms)"
- `thinking` → Show animated spinner
- `error` → Print error in red

### HTTP API UI (Alternative)

**Responsibilities**:
- HTTP server listening on port
- SSE endpoint for streaming events
- REST API for commands

**Event handling**:
- `text_chunk` → Send as SSE data chunk
- `tool_started` → Send SSE event "tool_start"
- `tool_completed` → Send SSE event "tool_complete"
- `error` → Send as HTTP error response

**Same agent core, different UI** - just swap the event handler.

## Testing Strategy

### Unit Testing (Without UI)

Create a test event handler that collects events instead of rendering:

**Test handler**: Records all events in a list.

**Test procedure**:
1. Create agent with test handler
2. Execute turn with test input
3. Verify events emitted (text chunks, tools executed, etc.)

**Benefit**: Test agent logic without any UI code.

### Integration Testing (With Mock API)

Create a mock API client that returns pre-programmed responses:

**Mock API**: Returns canned events (message_start, content_delta, tool_use).

**Test procedure**:
1. Inject mock API client into agent
2. Execute turn
3. Verify agent orchestrates correctly (calls tools, emits events)

**Benefit**: Test agent behavior without network calls.

### UI Testing (With Mock Agent)

Create a mock agent that emits test events:

**Mock agent**: Emits scripted events (simulate streaming, tool execution).

**Test procedure**:
1. UI receives events from mock agent
2. Verify UI renders correctly (compare terminal output, HTTP responses)

**Benefit**: Test UI rendering without full agent stack.

## Interface Benefits

### 1. Testability

Each component can be tested independently:
- Agent core (with test event handler + mock API)
- Tools (with test inputs → verify outputs)
- API client (with mock HTTP responses)
- UI (with mock agent emitting test events)

### 2. Flexibility

Swap implementations without changing contracts:
- Terminal UI ↔ HTTP API ↔ Desktop GUI (same agent core)
- Real API client ↔ Mock API client (same agent logic)
- Bash tool ↔ Sandboxed bash tool (same tool interface)

### 3. Parallel Development

Teams can work independently:
- UI team implements event handlers
- Agent team implements orchestration logic
- Tools team implements specific tools
- API team implements streaming client

As long as interfaces match, integration is straightforward.

### 4. Clear Boundaries

Each module has well-defined inputs/outputs:
- UI: Receives events, sends commands
- Agent: Receives commands, emits events
- Tools: Receive args, return results
- API: Receive requests, emit stream events

No hidden dependencies or tight coupling.

## Implementation Phases

### Phase 1: Core Interfaces

Define the three main interfaces:
- AgentInterface (events + commands)
- ToolInterface (plugin contract)
- APIClientInterface (streaming events)

### Phase 2: Minimal Agent

Implement agent core with:
- Single tool (bash)
- Mock API client (returns canned responses)
- Test event handler (collects events)

**Goal**: Prove the architecture works.

### Phase 3: Real Components

Replace mocks with real implementations:
- Real API client (HTTP/2 + SSE parsing)
- Full tool set (bash, file ops, search)
- Terminal UI (libxev + ANSI rendering)

**Goal**: Working end-to-end system.

### Phase 4: Advanced Features

Add complexity within existing interfaces:
- Subagents (spawn isolated agent instances)
- Planning system (TodoWrite tool)
- Multiple UI options (terminal + HTTP)

**Goal**: Feature-complete with clean architecture.

## Comparison: Our Design vs OpenCode

### OpenCode Architecture (Reference Implementation)

OpenCode is a production AI agent with proven architecture:

```
packages/opencode/src/
├── agent/          # Agent brain, prompts, context
├── session/        # Message history, LLM lifecycle
├── acp/            # Agent Client Protocol
├── bus/            # Event bus (decoupling)
├── mcp/            # Model Context Protocol
├── lsp/            # Language Server Protocol
├── tool/           # Tools (bash, file, git, edit, ripgrep, web)
└── cli/            # TUI interface

packages/
├── console/        # Web UI (SolidJS)
├── desktop/        # Tauri desktop app
├── ui/             # Shared component library
└── sdk/            # API SDK
```

### Key Similarities (Validation of Our Design)

| Concept | OpenCode | Our Design |
|---------|----------|------------|
| **Core/UI separation** | Agent core in `opencode`, UIs in separate packages | Agent core in `agent/`, UIs in `ui/` |
| **Event-driven** | Event `Bus` for decoupling | Event handlers (AgentInterface) |
| **Tool plugins** | `src/tool/` with standard interface | `tools/` with ToolInterface |
| **Multiple UIs** | Console, Desktop, CLI, VS Code | Terminal, HTTP, Desktop (future) |
| **Tool categories** | bash, file, git, edit, search | bash, file, edit, search |

**Insight**: Our event-driven architecture with clean interfaces matches the proven pattern from OpenCode.

### Key Differences (Optimized for Constrained Devices)

| Aspect | OpenCode | Our Design |
|--------|----------|------------|
| **Deployment** | Monorepo, multiple packages | Single static binary |
| **LLM support** | Multi-provider (OpenAI, Anthropic, etc.) | Claude-only (simpler, focused) |
| **Protocols** | ACP, MCP, LSP | Direct Claude API |
| **Event system** | Centralized event bus | Direct callbacks (less overhead) |
| **Runtime** | Bun/Node.js (~50-100MB) | Zig native (<2MB binary) |
| **Target** | Developer machines, cloud | Nokia N900, constrained devices |

**Insight**: We simplify where possible (single LLM, direct API) to minimize overhead while keeping the proven architectural patterns.

### What We Learn from OpenCode

#### 1. Event-Driven Decoupling Works

OpenCode uses an event `Bus` to decouple components. This allows:
- Agent emits events without knowing who's listening
- Multiple UIs can subscribe to same events
- Tools can emit progress events

**Our approach**: Same concept, lighter implementation (direct callbacks vs bus).

#### 2. Protocol Abstraction Enables Flexibility

OpenCode abstracts LLM communication via protocols (ACP, MCP). This enables:
- Swap LLM providers without changing agent logic
- Standardized tool discovery and execution
- Multiple client implementations

**Our approach**: Start without protocols (direct Claude API), add abstraction layer if we need multiple providers later.

#### 3. Tool Plugin System is Essential

OpenCode's `src/tool/` shows tools as first-class plugins:
- Each tool implements common interface
- Tools can be added without modifying core
- Tools are composable (one tool can call another)

**Our approach**: Identical philosophy (ToolInterface), proven to work.

#### 4. Multiple UI Frontends Are Viable

OpenCode supports Console (web), Desktop (Tauri), CLI (TUI), and VS Code:
- All share same agent core
- Each UI is just an event handler
- No agent logic duplicated

**Our approach**: Same design (multiple UIs, one core), start with terminal, add HTTP/desktop later.

### Our Architecture is OpenCode's Architecture, Simplified

**Shared principles**:
- Event-driven agent core
- Tool plugin system
- UI decoupling
- Multiple frontends

**Optimizations for constrained devices**:
- Single binary (vs monorepo)
- Direct API (vs protocol layers)
- Callbacks (vs event bus)
- Native code (vs JavaScript runtime)

**Result**: Proven architecture patterns, optimized for resource efficiency.

## Summary

**Three core interfaces**:
1. **AgentInterface**: Event-driven communication (core → UI)
2. **ToolInterface**: Plugin system for tools (core → tools)
3. **APIClientInterface**: Streaming events (API → core)

**Key principles** (validated by OpenCode):
- **Unidirectional data flow**: Events flow up, commands flow down
- **Event-driven**: Agent emits events, UI handles them (never calls UI directly)
- **Plugin architecture**: Tools and UI are swappable implementations
- **No circular dependencies**: Clear dependency graph (downward only)

**Result**: Clean, testable, flexible architecture that separates concerns - proven at scale by OpenCode, optimized for constrained devices.

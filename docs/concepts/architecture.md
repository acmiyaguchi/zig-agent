# Architecture

## Overview

Zig-agent is a high-performance, resource-efficient coding agent designed to run on constrained devices (e.g., Nokia N900 with ARMv7l architecture). It provides Claude-powered assistance in environments where the official Claude Code CLI is too resource-intensive.

## Philosophy

> **"The model is 80%. Code is 20%."**

Modern AI agents work not because of clever engineering, but because the language model is trained to be an agent. The model makes all the critical decisions:
- Which tools to call
- In what order
- When to stop

Our job as implementers is to:
1. **Provide reliable tools** - File operations, shell execution, code search
2. **Run the core loop efficiently** - Minimal overhead, fast tool execution
3. **Stay out of the way** - Don't over-engineer, let the model handle complexity

This philosophy aligns perfectly with Zig's values: explicit, simple, and fast. We build the scaffolding; Claude does the thinking.

## Core Agent Loop

Every coding agent, from Claude Code to Cursor, shares the same fundamental pattern:

```
while true:
    response = model(messages, tools)
    if response.stop_reason != "tool_use":
        return response.text
    results = execute(response.tool_calls)
    messages.append(results)
```

That's it. The model calls tools until it decides the task is complete. Everything else is refinement.

**Key insight**: The model controls the loop. We just execute tools and feed back results.

## Design Goals

1. **Low Memory Footprint**: Target <50MB RAM usage during operation
2. **Fast Startup**: Cold start in <500ms
3. **Efficient Streaming**: Handle API responses with minimal buffering
4. **Static Linking**: Single binary deployment with no runtime dependencies
5. **Cross-Architecture Support**: ARM (armv7l, aarch64) and x86_64

## System Components

### Core Agent
- Main event loop and request orchestrator (libxev for concurrent I/O)
- Conversation state management
- Tool dispatch system
- Planning system (TodoWrite tool for multi-step tasks)
- Subagent spawning and lifecycle management (v2+)

### API Client
- HTTP/2 client for Claude API
- Streaming response parser
- Connection pooling and retry logic

### Tool Execution Engine
- Sandboxed command execution
- File system operations
- Code editing and analysis tools

### User Interface
- Terminal UI with minimal dependencies
- Streaming output rendering
- Interactive prompts and confirmations

## Planning System

For complex multi-step tasks, explicit task tracking prevents "context fade" where the model loses track of what it's doing after many tool calls.

**Implementation**: TodoWrite tool (inspired by learn-claude-code v2)
- Structured task list with status tracking
- Constraints: Max 20 items, only ONE in_progress
- Memory overhead: ~3.5KB (negligible)

See [planning-system.md](planning-system.md) for details.

## Subagent Architecture

For large tasks that would pollute the main agent's context, we can spawn isolated subagents. This is inspired by learn-claude-code v3.

### The Problem: Context Pollution

**Single agent**:
```
[exploring...] cat file1.py -> 500 lines
[exploring...] cat file2.py -> 300 lines
... 15 more files ...
[now refactoring...] "Wait, what was in file1?"
```

The model's context fills with exploration details, leaving little room for the actual task.

### The Solution: Subagents with Isolated Context

**Main agent + subagents**:
```
Main Agent:
  [Task: explore codebase]
    -> Subagent explores 20 files (in its own context)
    -> Returns ONLY: "Auth in src/auth/, DB in src/models/"
  [now refactoring with clean context]
```

Each subagent has:
1. Fresh message history (no context pollution)
2. Filtered tools (explore agents can't write)
3. Specialized system prompt
4. Returns only summary to parent

**Key insight**: Process isolation = Context isolation

### Agent Types

| Type | Tools | Purpose |
|------|-------|---------|
| explore | bash, read_file | Read-only codebase exploration |
| code | all tools | Full implementation power |
| plan | bash, read_file | Design without modifying |

### Memory Implications for N900

**Critical consideration**: Each subagent needs its own memory!

```
Parent agent:     ~20MB
Child agent 1:    ~20MB
Child agent 2:    ~20MB
Total:            ~60MB (exceeds 50MB budget!)
```

### Strategies for Constrained Devices

#### Option 1: Sequential Execution (Recommended for v1)
- Spawn one subagent at a time
- Wait for completion before spawning next
- Reuse memory allocation between agents
- **Memory**: ~40MB peak (parent + one child)

#### Option 2: Agent Pooling (v2)
- Pre-allocate 2 agent slots
- Reuse slots for new tasks
- Arena allocator: free on completion, reuse memory
- **Memory**: ~50MB peak (parent + 2 children)

#### Option 3: Defer Subagents (v3+)
- Start without subagent support
- Prove single agent works on N900
- Add subagents once memory profile is validated
- **Memory**: ~20MB (single agent only)

**Recommendation**: Start with Option 3 (no subagents in v1). Add sequential subagents in v2 once we have real memory measurements from the device.

### Subagent Lifecycle

```zig
const SubagentTask = struct {
    agent_type: AgentType,  // explore, code, plan
    task_description: []const u8,
    result: ?[]const u8 = null,

    const AgentType = enum {
        explore,
        code,
        plan,
    };
};

fn spawnSubagent(task: SubagentTask, allocator: Allocator) ![]const u8 {
    // Create fresh conversation history
    var messages = std.ArrayList(Message).init(allocator);
    defer messages.deinit();

    // Add task as first user message
    try messages.append(.{
        .role = .user,
        .content = .{ .text = task.task_description },
    });

    // Get filtered tools for this agent type
    const tools = getToolsForAgentType(task.agent_type);

    // Run agent loop in isolated context
    const result = try runAgentLoop(messages, tools, allocator);

    // Return only final summary (not full history!)
    return result;
}
```

See [memory-management.md](memory-management.md) for arena allocator reuse strategy.

## Concurrency Model

The agent requires concurrent I/O for interactive features:
- **User input**: Read from stdin (typing, Ctrl+C)
- **API streaming**: Read from network socket
- **Terminal output**: Render while streaming

**Implementation**: Event loop (libxev) for single-threaded concurrent I/O.

### Why libxev?

**Requirements**:
- User can type while agent streams output
- Ctrl+C cancels current operation
- Progress indicators update in real-time

**Options considered**:
1. **libxev (event loop)** ← Chosen
   - Single-threaded, efficient on ARM
   - Zero runtime allocations
   - +100KB binary size
2. **Multi-threading**: Too heavy (3-6MB for thread stacks)
3. **poll() syscall**: Manual but viable alternative

**Trade-off**: libxev adds callback complexity but provides production-ready concurrent I/O for interactive features.

### Event Loop Pattern

```zig
loop.read(stdin, onUserInput);      // Handle typing
loop.read(api_socket, onAPIChunk);  // Handle streaming
loop.timer(100ms, onProgressUpdate); // Update spinner
loop.run();                          // Process events
```

When stdin or socket has data, corresponding callback fires. No blocking, terminal stays responsive.

See [concurrency-model.md](concurrency-model.md) for detailed analysis and alternatives.

## Data Flow

```
User Input → Agent Core → API Client → Claude API
                ↓              ↓
           Tool Execution   ← Streaming Response
                ↓
           File System / Shell
                ↓
           Response → User
```

## Memory Management Strategy

- Arena allocators for request-scoped memory
- Pool allocators for frequently allocated small objects
- Streaming parsers to avoid loading entire responses in memory
- Zero-copy operations where possible

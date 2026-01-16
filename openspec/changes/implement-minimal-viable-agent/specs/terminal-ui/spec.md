# Spec: Terminal UI

**Capability**: `terminal-ui`
**Change**: `implement-minimal-viable-agent`
**Status**: Draft

## Purpose

Implement event-driven terminal UI using termbox2 for rendering and libxev for concurrent I/O. This provides the user interface layer that consumes agent events and handles user input.

## Context

The UI architecture is event-driven per `interface-design.md`: agent emits events → UI renders. libxev enables concurrent I/O (user typing while model streams).

## ADDED Requirements

### Requirement: UI shall integrate termbox2 for terminal rendering

**Priority**: Critical
**Rationale**: Cross-platform TUI library chosen in terminal-ui.md

The UI SHALL:
- Initialize termbox2 on startup
- Render to termbox2 buffer (not directly to stdout)
- Use tb_present() for flicker-free updates
- Clean up termbox2 on exit
- Handle terminal resize events

#### Scenario: Initialize and render

```zig
var ui = try TerminalUI.init(allocator, &agent);
defer ui.deinit();

// termbox2 is initialized
try testing.expect(ui.tb != null);

// Can render text
try ui.renderText(0, 0, "Hello, World!");
try ui.present();

// Screen shows "Hello, World!" at (0, 0)
```

---

### Requirement: UI shall integrate libxev for event loop

**Priority**: Critical
**Rationale**: Non-blocking I/O for responsive UX

The libxev event loop SHALL handle:
- stdin reads (user input)
- Signal handling (Ctrl+C)
- Timer events (optional: cursor blink)
- Agent event processing

#### Scenario: Run event loop

```zig
var ui = try TerminalUI.init(allocator, &agent);
defer ui.deinit();

// Set up stdin watcher
try ui.loop.add(.{
    .fd = std.io.getStdIn().handle,
    .callback = onStdinRead,
});

// Run loop (blocks until exit)
try ui.run();

// Loop exits on Ctrl+C or explicit stop
```

---

### Requirement: UI shall render agent updates in real-time

**Priority**: High
**Rationale**: Streaming text UX

The handleAgentUpdate callback SHALL:
- Render .message_chunk updates immediately
- Show tool execution status (.tool_call, .tool_result)
- Update display without blocking event loop
- Prevent flicker using double buffering

#### Scenario: Render streaming text

```zig
const updates = &[_]AgentUpdate{
    .{ .message_chunk = "Hello" },
    .{ .message_chunk = " world" },
    .{ .message_chunk = "!" },
};

for (updates) |update| {
    ui.handleAgentUpdate(update);
}

// Terminal shows "Hello world!" built incrementally
try testing.expectEqualStrings("Hello world!", ui.output_buffer.items);
```

---

### Requirement: UI shall handle user input line-by-line

**Priority**: High
**Rationale**: Chat interface pattern

User input SHALL:
- Accumulate keystrokes in input buffer
- On Enter: send to agent.executeTurn(), clear buffer
- Support backspace to edit input
- Show input line at bottom of screen

#### Scenario: User types and submits

```zig
// Simulate user typing "Hello" + Enter
try ui.handleKeyPress('H');
try ui.handleKeyPress('e');
try ui.handleKeyPress('l');
try ui.handleKeyPress('l');
try ui.handleKeyPress('o');
try ui.handleKeyPress('\n');  // Enter

// Input was sent to agent
try testing.expectEqualStrings("Hello", last_agent_input);
// Input buffer cleared
try testing.expectEqual(@as(usize, 0), ui.input_buffer.items.len);
```

---

### Requirement: UI shall exit gracefully on Ctrl+C

**Priority**: High
**Rationale**: User expects Ctrl+C to exit

Signal handling SHALL:
- Catch SIGINT (Ctrl+C)
- Stop event loop
- Clean up termbox2
- Exit with code 0 (not a crash)

#### Scenario: Handle Ctrl+C

```zig
// Simulate Ctrl+C signal
try ui.handleSignal(std.os.linux.SIG.INT);

// Event loop stops
try testing.expect(!ui.loop.is_running);

// termbox2 cleaned up
// Process exits cleanly
```

---

### Requirement: UI shall use scrolling for output overflow

**Priority**: Medium
**Rationale**: Long outputs exceed terminal height

When output exceeds terminal height, the UI SHALL:
- Keep most recent lines visible
- Scroll older lines out of view
- Show scroll indicator if needed

#### Scenario: Render 100 lines in 20-line terminal

```zig
const term_height = 20;
ui.setTerminalSize(80, term_height);

// Add 100 lines
for (0..100) |i| {
    try ui.appendOutput(try std.fmt.allocPrint(allocator, "Line {}", .{i}));
}

ui.render();

// Only lines 80-99 visible (most recent 20)
const visible = ui.getVisibleLines();
try testing.expectEqual(@as(usize, 20), visible.len);
try testing.expectEqualStrings("Line 80", visible[0]);
try testing.expectEqualStrings("Line 99", visible[19]);
```

---

### Requirement: UI shall distinguish event types in rendering

**Priority**: Medium
**Rationale**: Different events need different visual treatment

Rendering SHALL:
- Show .message_chunk as normal text
- Show .tool_call with "Running: tool_name..."
- Show .tool_result with "✓ tool_name (duration)"
- Show .completion with separator line
- Show .error in red/highlighted

#### Scenario: Render different event types

```zig
ui.handleAgentUpdate(.{ .tool_call = .{ .name = "read_file", .args = .{} } });
// Shows: "⏳ Running read_file..."

ui.handleAgentUpdate(.{ .tool_result = .{
    .name = "read_file",
    .success = true,
    .output = "...",
    .duration_ms = 15,
} });
// Shows: "✓ read_file (15ms)"

ui.handleAgentUpdate(.{ .completion = .stop });
// Shows: "───────────────────"
```

---

## Non-Requirements (Out of Scope)

- Color/styling (v1: monochrome)
- Mouse support (v1: keyboard only)
- Multi-window layout (v1: single pane)
- Command history (v2)
- Syntax highlighting (v2)
- Custom keybindings (v1: hardcoded)

## Dependencies

- **Requires**: `project-structure` (termbox2, libxev deps), `agent-core` (event source)
- **Provides**: User interface

## Testing Strategy

**Unit Tests**:
- Input buffer management
- Event handling logic
- Scroll calculation

**Integration Tests**:
- termbox2 initialization
- libxev loop operation
- Agent event rendering

**Manual Tests**:
- Visual appearance
- Responsiveness during streaming
- Ctrl+C exit

## Related Specs

- `agent-core` - Event producer
- `project-structure` - Dependency setup

## References

- [terminal-ui.md](../../../../docs/concepts/terminal-ui.md)
- [interface-design.md](../../../../docs/concepts/interface-design.md#terminal-ui)
- [concurrency-model.md](../../../../docs/concepts/concurrency-model.md)

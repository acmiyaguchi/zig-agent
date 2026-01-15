# Terminal UI

## Overview

The terminal UI must be responsive and efficient on constrained hardware. A poorly designed TUI can waste CPU cycles and memory, making the agent feel sluggish even if the underlying operations are fast.

## Design Goals

1. **Minimal CPU usage**: <1% CPU for idle UI, <5% during streaming
2. **Low memory footprint**: <2MB for UI state and buffers
3. **Fast updates**: <16ms per frame (60 FPS) for smooth animations
4. **Efficient rendering**: Only redraw what changed (differential updates)
5. **No flicker**: Double buffering or smart invalidation

## Library Evaluation

### ncurses

**What it is**: Terminal control library, standard on Unix systems since 1980s.

**Pros**:
- Battle-tested, available everywhere
- Handles terminal capabilities automatically (terminfo database)
- Window management, panels, forms
- Wide character support

**Cons**:
- **Large footprint**: ~500KB-1MB library
- **Heavy dependencies**: terminfo database, shared libraries
- **C API**: Requires FFI bindings, manual memory management
- **Feature bloat**: We need <10% of its features
- **Dynamic linking overhead**: Slower startup on embedded

**Verdict for N900**: Too heavy. We'd be loading 1MB of code to output ANSI escape sequences.

### libuv

**What it is**: Cross-platform async I/O library (powers Node.js).

**Pros**:
- Event loop for non-blocking I/O
- Cross-platform (Windows, Unix, BSD)
- TTY handling utilities
- Signal handling

**Cons**:
- **Not a TUI library**: Handles I/O, not rendering
- **~500KB library**: Significant overhead
- **Async complexity**: Overkill for simple stdout writes
- **Memory overhead**: Event loop, handles, queues

**Verdict for N900**: Wrong tool. We need TUI, not async I/O. Our I/O is inherently sequential (stream from API → display → user input → send).

### termbox / termbox2

**What it is**: Minimalist TUI library, cell-based rendering.

**Pros**:
- Lightweight: ~100KB binary, ~100KB memory
- Simple API: clear(), set_cell(), present()
- Double buffering built-in
- Pure C, easy to bind

**Cons**:
- Cell-based model requires full-screen management
- Still adds ~100KB vs raw ANSI (~0KB)
- Another dependency to cross-compile for ARM

**Verdict for N900**: Viable option if we need structured rendering (split panes, status bars).

### Clay (Layout Engine)

**What it is**: High-performance flex-box style layout library in C.

**Pros**:
- **Tiny**: ~15KB binary, single header file
- **Zero dependencies**: No stdlib
- **Low memory**: ~1-2MB for simple layouts
- **Declarative**: Flex-box style layout definitions
- **Renderer-agnostic**: Works with any rendering backend

**Cons**:
- Not a renderer (need termbox2 or similar)
- Adds complexity (layout calculation layer)
- Overkill for simple linear output

**Combination: termbox2 + Clay**
- Clay calculates layout (where things go)
- termbox2 renders to terminal (draws cells)
- **Total overhead**: ~115KB binary + 1-2MB memory
- **Use case**: Split panes, complex layouts, resizable panels

**Verdict for N900**: Excellent for v3+ if we want advanced UI (split panes, panels). Overkill for v1.

### notcurses

**What it is**: Modern TUI library with multimedia support.

**Pros**:
- Rich features: images, video, plots
- Efficient rendering engine
- Good Unicode handling

**Cons**:
- **Large**: Several MB with dependencies
- **Overkill**: We're displaying text, not rendering images
- **Heavy dependencies**: libavformat, libswscale

**Verdict for N900**: Way too heavy for our use case.

### vaxis (Zig native)

**What it is**: Pure Zig TUI library, inspired by libvaxis (Rust).

**Pros**:
- **Native Zig**: No FFI, comptime optimizations
- Event-driven architecture
- Modern design
- Compiles into binary (no runtime deps)

**Cons**:
- Young project (less mature)
- Still growing API
- ~50-100KB code size impact

**Verdict for N900**: Interesting option. Worth benchmarking against raw ANSI.

### Raw ANSI Escape Codes

**What it is**: Write escape sequences directly to stdout.

**Pros**:
- **Zero dependencies**: Just write to stdout
- **Zero overhead**: No library to load
- **Full control**: Exactly what we need, nothing more
- **Tiny code**: <1KB for basic ANSI utilities
- **Maximum efficiency**: Direct syscalls

**Cons**:
- Manual cursor management
- Must handle terminal detection ourselves
- More code to write and maintain
- No built-in double buffering

**Verdict for N900**: **Recommended for v1**. We control every byte, optimize for exactly our use case.

## Recommended Approach: Raw ANSI

### Why Raw ANSI Wins on Constrained Devices

1. **Binary Size**: 0KB vs 100KB-1MB for libraries
2. **Memory**: No library state, just our buffers
3. **Startup Time**: No dynamic linking, no initialization
4. **Control**: Optimize for streaming text (our core use case)
5. **Simplicity**: 200 lines of Zig vs learning library API

### What We Actually Need

For a coding agent, the UI is simple:
- Display streaming text as it arrives
- Show progress indicators (spinner, status)
- Basic formatting (bold, colors for syntax)
- Handle user input (prompts, confirmations)

**We don't need**:
- Full-screen apps with windows/panels
- Complex widgets (menus, forms, dialogs)
- Mouse support (nice-to-have, not essential)
- Advanced layouts (split panes, tabs)

### Core Efficiency Strategies

#### 1. Output Buffering
Accumulate output in memory, write once. Reduces syscalls from N to 1 (syscalls are expensive on ARM).

#### 2. Differential Rendering
Track previous frame, only redraw changed lines. 10-100x less output on incremental updates.

#### 3. Rate Limiting
Cap at 60 FPS (16ms between frames). Humans can't perceive faster updates. Prevents wasted CPU.

#### 4. Lazy Rendering
Don't render if terminal is backgrounded or not a TTY. Zero CPU when not visible.

#### 5. Single Write Buffer
Build entire frame in memory, single `write()` syscall. Better than multiple small writes.

## Preventing Flicker

### The Flicker Problem

Flickering occurs when:
1. Screen is cleared
2. Content is redrawn
3. Delay between clear and redraw creates visible blank frames

This is especially noticeable in long conversations or over slow connections.

### Solution: Never Clear

**Append-only mode** (recommended for v1):
- New content just flows to bottom
- Never redraw old content
- Old content scrolls off naturally
- **Zero flicker** (nothing is redrawn)

```zig
// Just append, never clear
fn displayChunk(chunk: []const u8) !void {
    try stdout.writeAll(chunk);
}
```

### Differential Updates

If you must update existing content:
- Track what changed
- Only rewrite changed lines
- Use cursor positioning, not clear screen

```zig
// Update specific line without clearing
fn updateLine(row: usize, content: []const u8) !void {
    try stdout.print("\x1B[{d};0H", .{row});  // Move to row
    try stdout.writeAll("\x1B[2K");            // Clear line
    try stdout.writeAll(content);              // Write new content
}
```

### Double Buffering

Accumulate entire frame, write once:

```zig
var buffer = std.ArrayList(u8).init(allocator);
// Build entire frame in buffer
try buffer.appendSlice(...);
// Single write
try stdout.writeAll(buffer.items);
```

### Hide Cursor During Updates

```zig
try stdout.writeAll("\x1B[?25l");  // Hide
// ... do updates ...
try stdout.writeAll("\x1B[?25h");  // Show
```

### Alternate Screen Buffer

For full-screen apps (like vim):

```zig
// Enter alternate screen
try stdout.writeAll("\x1B[?1049h");
// ... render ...
// Exit (restores original content)
try stdout.writeAll("\x1B[?1049l");
```

**Trade-off**: Can't scroll back, but no flicker.

## Display Patterns

### For Streaming Text (Primary Use Case)

**Challenge**: Display Claude's response as it streams, handling word wrap and colors.

**Strategy for long conversations**:
- **Append-only mode**: Never redraw, just stream to bottom
- Optional status line (updated independently with cursor save/restore)
- No clearing = no flickering
- Works great for scrolling conversations

**Memory**: <1KB for streaming buffer

### For Progress Indicators

**Challenge**: Show spinner or progress during long operations without blocking.

**Strategy**:
- Simple spinner: 10 Unicode frames, rotate on update
- Update every ~100ms (10 FPS is fine for spinner)
- Use `\r` to overwrite same line

**Memory**: <100 bytes

### For Status Lines

**Challenge**: Show persistent status (token count, time, etc.) without disrupting output.

**Strategy**:
- Reserve bottom line for status
- Use ANSI save/restore cursor position
- Update independently of main output

**Memory**: <500 bytes for status state

## Color Strategy

### Basic 8 Colors (Recommended)

Standard ANSI: Black, Red, Green, Yellow, Blue, Magenta, Cyan, White + bright variants.

**Pros**: Universal support, zero parsing overhead
**Cons**: Limited palette

**Use for**: Tool output (green=success, red=error, blue=info), syntax hints

### 256 Colors (Optional)

Extended palette via `\x1B[38;5;Nm`.

**Pros**: More colors for syntax highlighting
**Cons**: Not all terminals support, slightly more parsing

**Decision**: Detect terminal capability, fallback to 8-color

### True Color RGB (Avoid)

24-bit color via `\x1B[38;2;R;G;Bm`.

**Verdict**: Unnecessary for coding agent, adds parsing overhead

## Terminal Compatibility

### Detection Strategy

Check `$TERM` environment variable:
- `dumb`: No ANSI, plain text only
- `xterm`, `linux`: Basic ANSI support
- `xterm-256color`: 256 color support
- `screen`, `tmux`: Special handling for multiplexers

### Fallback Behavior

If terminal doesn't support ANSI:
- No colors (still functional)
- No cursor manipulation
- Simple line-by-line output

**Principle**: Degrade gracefully, never break.

## Input Handling

### Raw Mode

Disable line buffering (canonical mode) to read character-by-character. Required for interactive features (Ctrl+C to cancel, arrow keys, etc.).

**Trade-off**: More complex input handling, but better UX.

### Escape Sequence Parsing

Arrow keys, function keys send multi-byte sequences. Must parse `\x1B[A` (up), `\x1B[B` (down), etc.

**Implementation**: Small state machine (~50 lines).

## Memory Budget

For entire UI subsystem on N900:

- **Screen buffer**: ~60KB (100 rows × 200 cols × 3 bytes per cell)
- **Output buffer**: ~16KB (accumulate frame before write)
- **Input buffer**: ~1KB (escape sequence parsing)
- **State tracking**: ~10KB (cursor position, colors, etc.)

**Total**: <100KB for full-featured TUI

For minimal v1:

- **Output buffer**: ~4KB
- **State**: ~1KB

**Total**: <10KB

## Performance Targets

On Nokia N900:

- **Idle CPU**: 0% (no rendering when static)
- **Streaming CPU**: <3% (at 1000 tokens/sec)
- **Memory**: <2MB for UI state
- **Latency**: <10ms from text received to displayed
- **Throughput**: Handle 10,000+ characters/sec without lag

## Implementation Phases

### Phase 1: Minimal (v0)
- Raw stdout, no ANSI
- Line-by-line output
- Prove agent loop works

### Phase 2: Basic ANSI (v1)
- Colors for different message types
- Simple spinner for progress
- Raw mode input for Ctrl+C

### Phase 3: Polished (v2)
- Differential rendering
- Status line with token count
- Better word wrapping

### Phase 4: Advanced (v3+)
- Syntax highlighting (if CPU allows)
- Mouse support for file paths
- Scrollback buffer

## Recommendation

### Phase 1: Start with raw ANSI escape codes (v0-v1)
1. Zero dependencies = faster compile, smaller binary
2. Full control for optimization
3. ~200 lines of Zig code
4. Easy to understand and debug
5. Can always add library later if needed

**Goal**: Prove agent loop works, get streaming output functional.

### Phase 2: Evaluate structured rendering (v2)

**If sticking with simple UI**:
- Continue with raw ANSI
- Add differential rendering for efficiency
- Keep it minimal

**If wanting split panes or status bars**:
- **Option A**: Try **vaxis** (pure Zig, ~50-100KB)
- **Option B**: Try **termbox2** (battle-tested, ~100KB + 100KB memory)
- Benchmark both, pick what works best on N900

### Phase 3: Advanced layouts (v3+)

**If needing complex layouts**:
- Add **Clay** on top of termbox2
- Total overhead: ~115KB binary + 1-2MB memory
- Flex-box layouts, resizable panels, professional UI

**Use cases for Clay**:
- Split pane with code context sidebar
- Multi-panel tool output display
- Resizable panels that reflow on terminal resize
- Complex status bars with sections

### Progression Summary

```
v0-v1:  Raw ANSI          (0KB binary, <10KB memory)
v2:     termbox2 OR vaxis (~100KB binary, ~100KB memory)
v3+:    termbox2 + Clay   (~115KB binary, 1-2MB memory)
```

### Avoid
- **ncurses**: Too heavy (500KB-1MB)
- **libuv**: Wrong tool (async I/O, not TUI)
- **notcurses**: Overkill (multimedia support we don't need)

## Testing Strategy

- Test on actual N900 hardware (or ARM QEMU)
- Test with `TERM=dumb` for fallback behavior
- Benchmark: `time yes "test" | head -10000 | zig-agent`
- Profile CPU: Ensure <5% during streaming
- Memory: Ensure <2MB RSS for UI

## References

See [REFERENCES.md](../REFERENCES.md#terminal-ui) for:
- vaxis (Zig TUI library)
- termbox2 (minimal C library)
- ANSI escape code standards
- Terminal capability databases

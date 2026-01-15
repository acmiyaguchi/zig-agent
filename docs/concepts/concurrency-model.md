# Concurrency Model

## Overview

The agent needs to handle concurrent I/O operations:
1. **Reading user input** from stdin (typing, Ctrl+C)
2. **Streaming API responses** from network socket
3. **Rendering output** to terminal

This requires non-blocking I/O or multi-threading. On constrained devices like Nokia N900, the concurrency strategy significantly impacts memory and CPU usage.

## Use Case: Interactive Streaming

**Requirement**: User can type while agent streams output.

**Scenario**:
```
Terminal Output (streaming):
> "Let me analyze your code..."
> [analyzing files...]
> "Found 3 issues..."

User Input (concurrent):
[User types: "stop" + Enter]
→ Agent cancels current operation
```

Without concurrency, the agent blocks on API response and can't process user input until streaming completes.

## Concurrency Options

### Option 1: Event Loop (libxev) ✓ Recommended

**How it works**:
- Single-threaded event loop
- Register multiple I/O sources (stdin, socket, timers)
- Loop processes events as they arrive
- Callbacks handle completions

**Implementation**:
```zig
const xev = @import("xev");

const Agent = struct {
    loop: xev.Loop,
    stdin_watcher: xev.Completion,
    socket_watcher: xev.Completion,

    fn run(self: *Agent) !void {
        // Register stdin for input
        try self.loop.read(
            std.io.getStdIn().handle,
            &self.stdin_buffer,
            &self.stdin_watcher,
            Agent.onStdinRead,
            self
        );

        // Register socket for streaming
        try self.loop.read(
            self.api_socket.handle,
            &self.stream_buffer,
            &self.socket_watcher,
            Agent.onStreamChunk,
            self
        );

        // Run event loop
        try self.loop.run(.until_done);
    }

    fn onStdinRead(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        c: *xev.Completion,
        result: xev.ReadError!usize
    ) void {
        const self = @ptrCast(*Agent, userdata);
        const n = result catch return;

        // Process user input
        self.handleInput(self.stdin_buffer[0..n]);

        // Re-register for next input
        loop.read(/* ... */);
    }

    fn onStreamChunk(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        c: *xev.Completion,
        result: xev.ReadError!usize
    ) void {
        const self = @ptrCast(*Agent, userdata);
        const n = result catch return;

        // Parse and display chunk
        self.parseSSE(self.stream_buffer[0..n]);

        // Continue reading
        loop.read(/* ... */);
    }
};
```

**Pros**:
- **Single-threaded**: No context switching overhead
- **Zero runtime allocations**: libxev pre-allocates everything
- **Efficient on ARM**: Event loop is just a syscall (epoll on N900)
- **Built for this**: Designed specifically for concurrent I/O

**Cons**:
- **Callback-based**: More complex than linear code
- **Library dependency**: Adds ~50-100KB to binary
- **Learning curve**: Event loop mental model

**Memory overhead**: ~50-100KB (acceptable)

**CPU overhead**: Minimal (event loop is kernel notification)

### Option 2: Multi-Threading

**How it works**:
- Thread 1: Read stdin, handle user input
- Thread 2: Read API socket, parse streaming
- Thread 3: Main agent logic

**Implementation**:
```zig
const Agent = struct {
    input_thread: std.Thread,
    stream_thread: std.Thread,

    fn start(self: *Agent) !void {
        self.input_thread = try std.Thread.spawn(.{}, inputLoop, .{self});
        self.stream_thread = try std.Thread.spawn(.{}, streamLoop, .{self});

        // Main thread handles agent logic
        try self.agentLoop();
    }

    fn inputLoop(self: *Agent) void {
        while (self.running) {
            const input = std.io.getStdIn().reader().readUntilDelimiter(&buffer, '\n') catch continue;
            self.input_queue.push(input);
        }
    }

    fn streamLoop(self: *Agent) void {
        while (self.running) {
            const n = self.socket.read(&buffer) catch continue;
            self.stream_queue.push(buffer[0..n]);
        }
    }
};
```

**Pros**:
- **Simple mental model**: Each thread is linear code
- **No callbacks**: Direct imperative programming
- **No external deps**: std.Thread is built-in

**Cons**:
- **High memory cost**: Each thread = separate stack (~1-2MB default)
  - 3 threads = **3-6MB just for stacks** (12% of N900 RAM!)
- **Context switching overhead**: CPU time switching between threads
- **Synchronization needed**: Mutexes for shared state (complexity + overhead)
- **Cache thrashing**: Multiple threads = worse cache locality on single-core ARM

**Memory overhead**: 3-6MB for thread stacks + sync primitives

**CPU overhead**: Context switching on single-core N900 is expensive

**Verdict**: Too heavy for constrained device

### Option 3: Non-Blocking I/O with poll()

**How it works**:
- Set stdin and socket to non-blocking
- Use poll() to wait for activity on multiple FDs
- Process whichever is ready

**Implementation**:
```zig
const Agent = struct {
    fn run(self: *Agent) !void {
        // Set non-blocking
        try setNonBlocking(std.io.getStdIn().handle);
        try setNonBlocking(self.socket.handle);

        var pollfds = [_]std.posix.pollfd{
            .{ .fd = std.io.getStdIn().handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        while (self.running) {
            // Wait for activity (blocks until something ready)
            const ready = try std.posix.poll(&pollfds, -1);

            // Check stdin
            if (pollfds[0].revents & std.posix.POLL.IN != 0) {
                const n = try std.io.getStdIn().read(&self.stdin_buffer);
                try self.handleInput(self.stdin_buffer[0..n]);
            }

            // Check socket
            if (pollfds[1].revents & std.posix.POLL.IN != 0) {
                const n = try self.socket.read(&self.stream_buffer);
                try self.parseChunk(self.stream_buffer[0..n]);
            }
        }
    }
};
```

**Pros**:
- **Zero dependencies**: Uses POSIX poll() directly
- **Minimal memory**: No thread stacks, no library overhead
- **Simple**: poll() + switch statement
- **Portable**: POSIX standard (works on N900)

**Cons**:
- **Manual state management**: Have to track partial reads yourself
- **Less abstraction**: More boilerplate than libxev
- **Edge cases**: Handling EAGAIN, partial writes, etc.

**Memory overhead**: ~0KB (just local variables)

**CPU overhead**: Minimal (poll() is a syscall)

### Option 4: Coroutines / Async-Await

**Status**: Zig async/await is being redesigned, not stable yet.

**Verdict**: Not viable for production use in 2025.

## Recommendation for zig-agent

### v1-v2: **libxev** (Option 1)

**Why**:
1. **Purpose-built for concurrent I/O**: Exactly your use case
2. **Efficient on single-core ARM**: Event loop is one epoll() call
3. **Zero runtime allocations**: Pre-allocated, predictable memory
4. **Production-ready**: Used by Mitchell Hashimoto's projects

**Trade-offs**:
- Binary size: +50-100KB (acceptable, still <2MB total)
- Callback style: More complex than linear code
- Learning curve: Event loop concepts

**Memory budget update**:
```
Base runtime:         ~5MB
libxev library:       ~100KB
API client:           ~2MB
Streaming parser:     ~1MB
Tool execution:       ~10MB
Conversation state:   ~5MB
Terminal UI:          ~2MB
Total:                ~26MB (still well under 50MB)
```

### Alternative v1: **poll()** (Option 3)

If you want to minimize dependencies and binary size:

**Why**:
- Zero dependencies
- Minimal overhead
- Full control

**Trade-offs**:
- More manual work (state machines for partial reads)
- More edge cases to handle
- Less abstraction than libxev

**Recommendation**: Start with poll() if you want to prove the concept, migrate to libxev when complexity grows.

## Implementation Strategy

### Phase 1: Blocking I/O (Prove Core Loop)

Start simple, prove the agent works:
```zig
while (true) {
    const user_input = try stdin.readUntilDelimiter(&buffer, '\n');
    const response = try callAPI(user_input);
    try stdout.writeAll(response);
}
```

**No concurrency, but validates all other components.**

### Phase 2: Non-Blocking with poll()

Add concurrent input/output:
```zig
var pollfds = [_]pollfd{stdin_fd, socket_fd};
while (true) {
    try poll(&pollfds, -1);
    if (stdin_ready) try handleInput();
    if (socket_ready) try handleStream();
}
```

**Proves concurrent I/O works, minimal dependencies.**

### Phase 3: Migrate to libxev

Replace poll() with libxev:
```zig
loop.read(stdin, onInput);
loop.read(socket, onStream);
loop.run();
```

**Production-ready, cleaner code, better abstractions.**

## Specific Use Cases

### Cancellation (Ctrl+C during streaming)

**With libxev**:
```zig
fn onStdinRead(self: *Agent, result: !usize) void {
    const input = self.stdin_buffer[0..result];
    if (std.mem.eql(u8, input, "\x03")) { // Ctrl+C
        self.cancelCurrentTask();
    }
}

fn cancelCurrentTask(self: *Agent) void {
    // Close API socket (triggers completion)
    self.socket.close();
    // Event loop will invoke socket's completion handler with error
}
```

### Progress Updates

**With libxev**:
```zig
fn onTimer(self: *Agent) void {
    // Show spinner every 100ms
    try stdout.writeAll(SPINNER[self.frame % SPINNER.len]);
    self.frame += 1;

    // Re-arm timer
    self.loop.timer_add(...);
}
```

### Simultaneous Type & Display

**With libxev**:
```zig
// Both registered simultaneously
loop.read(stdin, onInput);    // User typing
loop.read(socket, onStream);  // API streaming

// Whichever has data first gets processed
// Terminal stays responsive!
```

## Performance on Nokia N900

### Event Loop Efficiency

**epoll() on ARM Cortex-A8**:
- Single syscall to check multiple FDs
- Kernel returns only ready FDs (no scanning)
- ~10-20μs overhead per iteration (negligible)

**vs Threading**:
- Context switch: ~5-10μs per switch
- With 3 threads on single core: constant switching
- ~50-100μs overhead per iteration
- **5-10x slower than event loop**

### Memory Comparison

| Approach | Memory | Notes |
|----------|--------|-------|
| Blocking I/O | ~26MB | No concurrency |
| poll() | ~26MB | Manual state management |
| libxev | ~26MB | +100KB for library |
| Threads | ~32-35MB | +3-6MB for stacks |

**Verdict**: libxev and poll() are equivalent in memory, both beat threads.

## Testing Interactive Features

```bash
# Test concurrent input while streaming
echo "Explain this codebase" | zig-agent &
PID=$!

# Send Ctrl+C after 2 seconds
sleep 2
kill -INT $PID

# Verify cancellation worked
```

## Integration with Terminal UI

### Raw ANSI (v1)

```zig
// Just append, no redraw needed
fn displayChunk(chunk: []const u8) !void {
    try stdout.writeAll(chunk);
}
```

libxev compatible: `loop.write(stdout, chunk, onWriteComplete)`

### termbox2 (v2)

```zig
// Update buffer, then present
fn displayChunk(chunk: []const u8) !void {
    tb.print(row, col, chunk);
    tb.present();
}
```

libxev compatible: Do updates in completion handler, present once per event loop iteration.

### termbox2 + Clay (v3)

Same as termbox2, but layout calculated by Clay.

## Summary

**For interactive zig-agent, use libxev**:

✅ **Pros**:
- Purpose-built for concurrent I/O (your exact use case)
- Efficient on single-core ARM (event loop beats threads)
- Zero runtime allocations (predictable memory)
- +100KB binary (acceptable, still <2MB total)

❌ **Cons**:
- Callback-based programming (learning curve)
- External dependency (but stable, well-maintained)

**Alternative**: Start with poll() for v1 (zero deps, prove concept), migrate to libxev for v2 (cleaner code, better abstractions).

**Memory impact**: Negligible (~100KB)
**CPU impact**: Negligible (~10-20μs per event loop iteration)
**Complexity**: Moderate (callbacks vs linear code)

**Verdict**: libxev is the right tool for interactive concurrent I/O on constrained devices.

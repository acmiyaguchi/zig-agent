# Testing and Debugging

## Overview

On constrained devices like Nokia N900, we must verify that memory usage, CPU performance, and behavior match our design assumptions. This document covers tools and strategies for testing, debugging, and profiling zig-agent.

## Memory Analysis

### Zig's Built-in Memory Tracking

Zig provides compile-time and runtime memory leak detection.

#### GeneralPurposeAllocator with Leak Detection

```zig
const std = @import("std");

pub fn main() !void {
    // GPA tracks all allocations in debug mode
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,           // Enable safety checks
        .thread_safe = true,      // Safe for multi-threaded (if used)
        .verbose_log = false,     // Set true for detailed logs
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leaked!", .{});
        }
    }

    const allocator = gpa.allocator();

    // Your agent code here
    try runAgent(allocator);
}
```

**Output on leak**:
```
error: Memory leaked!
```

**Use for**: Development, catching leaks in unit tests.

#### Detailed Leak Reports

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .retain_metadata = true,   // Keep stack traces
    .verbose_log = true,       // Print allocation details
}){};
```

**Output**:
```
[gpa] alloc 0x7ffd12340000..0x7ffd12340400 (1024 bytes)
[gpa] free 0x7ffd12340000
[gpa] alloc 0x7ffd12341000..0x7ffd12341100 (256 bytes)
error: [gpa] Memory leak detected: 0x7ffd12341100 (256 bytes)
Stack trace:
  allocMessage at src/agent.zig:123
  handleTurn at src/agent.zig:456
```

**Use for**: Tracking down specific leak sources.

### RSS (Resident Set Size) Monitoring

Track actual RAM usage by the process.

#### Simple RSS Checker

```zig
const std = @import("std");
const linux = std.os.linux;

pub fn getCurrentRSS() !usize {
    const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = buf[0..n];

    // statm format: size resident shared text lib data dt
    var iter = std.mem.tokenize(u8, content, " ");
    _ = iter.next(); // skip size
    const rss_pages = try std.fmt.parseInt(usize, iter.next().?, 10);

    const page_size = std.mem.page_size;
    return rss_pages * page_size;
}

pub fn formatBytes(bytes: usize) ![]const u8 {
    if (bytes < 1024) return try std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    if (bytes < 1024 * 1024) return try std.fmt.allocPrint(allocator, "{d}KB", .{bytes / 1024});
    return try std.fmt.allocPrint(allocator, "{d}MB", .{bytes / 1024 / 1024});
}

// Usage
const rss = try getCurrentRSS();
std.debug.print("Current RSS: {s}\n", .{try formatBytes(rss)});
```

#### Continuous Monitoring

```zig
const MemoryMonitor = struct {
    samples: std.ArrayList(Sample),
    start_time: i64,

    const Sample = struct {
        timestamp_ms: i64,
        rss_bytes: usize,
        label: []const u8,
    };

    pub fn init(allocator: Allocator) MemoryMonitor {
        return .{
            .samples = std.ArrayList(Sample).init(allocator),
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn sample(self: *MemoryMonitor, label: []const u8) !void {
        const rss = try getCurrentRSS();
        try self.samples.append(.{
            .timestamp_ms = std.time.milliTimestamp() - self.start_time,
            .rss_bytes = rss,
            .label = label,
        });
    }

    pub fn report(self: *MemoryMonitor) !void {
        std.debug.print("\n=== Memory Report ===\n", .{});
        std.debug.print("Samples: {d}\n", .{self.samples.items.len});

        var max_rss: usize = 0;
        var min_rss: usize = std.math.maxInt(usize);
        var sum: usize = 0;

        for (self.samples.items) |s| {
            max_rss = @max(max_rss, s.rss_bytes);
            min_rss = @min(min_rss, s.rss_bytes);
            sum += s.rss_bytes;
            std.debug.print("[{d}ms] {s}: {d}MB\n", .{
                s.timestamp_ms,
                s.label,
                s.rss_bytes / 1024 / 1024,
            });
        }

        const avg = sum / self.samples.items.len;
        std.debug.print("\nPeak: {d}MB\n", .{max_rss / 1024 / 1024});
        std.debug.print("Min: {d}MB\n", .{min_rss / 1024 / 1024});
        std.debug.print("Avg: {d}MB\n", .{avg / 1024 / 1024});
    }
};

// Usage in agent
pub fn main() !void {
    var monitor = MemoryMonitor.init(allocator);

    try monitor.sample("startup");
    try runAgent();
    try monitor.sample("after agent loop");

    for (0..10) |i| {
        try executeTurn();
        try monitor.sample(try std.fmt.allocPrint(allocator, "turn {d}", .{i}));
    }

    try monitor.report();
}
```

**Output**:
```
=== Memory Report ===
Samples: 12
[0ms] startup: 5MB
[100ms] after agent loop: 8MB
[200ms] turn 0: 15MB
[400ms] turn 1: 16MB
[600ms] turn 2: 15MB
...

Peak: 22MB
Min: 5MB
Avg: 14MB
```

### External Memory Profiling Tools

#### Valgrind (Memcheck)

Detects memory leaks, use-after-free, buffer overflows.

**On development machine** (not N900 - Valgrind is heavy):
```bash
# Build with debug symbols
zig build -Doptimize=Debug

# Run under Valgrind
valgrind --leak-check=full --show-leak-kinds=all ./zig-agent

# Suppress Zig runtime allocations
valgrind --leak-check=full --suppressions=zig.supp ./zig-agent
```

**Output**:
```
==12345== HEAP SUMMARY:
==12345==     in use at exit: 256 bytes in 1 blocks
==12345==   total heap usage: 1,234 allocs, 1,233 frees, 5,678,900 bytes allocated
==12345==
==12345== 256 bytes in 1 blocks are definitely lost in loss record 1 of 1
==12345==    at 0x4C2BBAF: malloc (vg_replace_malloc.c:299)
==12345==    by 0x10A1B3: allocMessage (agent.zig:123)
==12345==    by 0x10A456: handleTurn (agent.zig:456)
```

**Use for**: Pre-deployment testing on x86_64.

#### Massif (Heap Profiler)

Tracks heap usage over time.

```bash
# Run with Massif
valgrind --tool=massif --massif-out-file=massif.out ./zig-agent

# Visualize
ms_print massif.out > massif.txt
cat massif.txt
```

**Output**:
```
    MB
25.0 |                                              @@@@@@::::::
     |                                         @@@@@      ::::::
     |                                    @@@@@           ::::::
     |                               @@@@@                ::::::
     |                          @@@@@                     ::::::
20.0 |                     @@@@@                          ::::::
     |                @@@@@                               ::::::
     |           @@@@@                                    ::::::
     |      @@@@@                                         ::::::
15.0 | @@@@@                                              ::::::
   0 +----------------------------------------------------------------------->Ms
     0                                                                   1000

Peak: 24.5MB at turn 8
```

**Use for**: Identifying memory growth patterns.

#### heaptrack

Modern heap profiler (easier than Massif).

```bash
# Record
heaptrack ./zig-agent

# Analyze
heaptrack_gui heaptrack.zig-agent.12345.gz
```

**Shows**:
- Peak memory usage
- Allocation hotspots
- Memory leaks
- Flamegraphs of allocation call stacks

**Use for**: Finding which functions allocate the most.

### Testing Arena Allocator Reuse

Verify arena allocators are properly reset between turns.

```zig
test "arena allocator reuse" {
    var parent_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = parent_gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(parent_gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    // Turn 1
    const turn1_before = try getCurrentRSS();
    const data1 = try allocator.alloc(u8, 1024 * 1024); // 1MB
    _ = data1;
    const turn1_after = try getCurrentRSS();

    // Reset arena
    _ = arena.reset(.retain_capacity);

    // Turn 2 (should reuse memory)
    const turn2_before = try getCurrentRSS();
    const data2 = try allocator.alloc(u8, 1024 * 1024); // 1MB
    _ = data2;
    const turn2_after = try getCurrentRSS();

    // RSS should not grow significantly on turn 2
    const turn1_growth = turn1_after - turn1_before;
    const turn2_growth = turn2_after - turn2_before;

    std.debug.print("Turn 1 growth: {d}KB\n", .{turn1_growth / 1024});
    std.debug.print("Turn 2 growth: {d}KB\n", .{turn2_growth / 1024});

    // Turn 2 should reuse arena memory (minimal growth)
    try std.testing.expect(turn2_growth < turn1_growth / 2);
}
```

**Expected output**:
```
Turn 1 growth: 1024KB
Turn 2 growth: 4KB  ✓ Reused arena memory
```

## Performance Profiling

### CPU Profiling with perf (Linux)

Profile CPU usage on N900 or development machine.

```bash
# Record
perf record -g ./zig-agent

# Report
perf report

# Flamegraph
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

**Shows**:
- Which functions consume CPU
- Call stacks (with `-g`)
- Hotspots for optimization

**On N900**: `perf` works but may have limited features (older kernel).

### Benchmarking with std.time

```zig
pub fn benchmark(comptime name: []const u8, func: anytype) !void {
    const start = std.time.nanoTimestamp();
    try func();
    const end = std.time.nanoTimestamp();

    const duration_ns = end - start;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    std.debug.print("{s}: {d:.2}ms\n", .{ name, duration_ms });
}

// Usage
try benchmark("parse SSE event", parseSSEEvent);
try benchmark("serialize conversation", serializeConversation);
try benchmark("execute bash tool", executeBashTool);
```

**Output**:
```
parse SSE event: 0.15ms
serialize conversation: 8.23ms
execute bash tool: 125.45ms
```

### Microbenchmarks

```zig
test "serialization performance" {
    const allocator = std.testing.allocator;

    var conversation = try createTestConversation(allocator, 100); // 100 messages
    defer conversation.deinit();

    const iterations = 1000;
    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        const json = try std.json.stringifyAlloc(allocator, conversation.messages.items, .{});
        allocator.free(json);
    }

    const end = std.time.nanoTimestamp();
    const avg_ns = @divTrunc(end - start, iterations);
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;

    std.debug.print("Avg serialization time: {d:.2}ms\n", .{avg_ms});

    // Assert performance target
    try std.testing.expect(avg_ms < 10.0); // Target: <10ms per serialization
}
```

## Debugging Strategies

### Debug Builds vs Release Builds

```bash
# Debug: Full symbols, safety checks, no optimization
zig build -Doptimize=Debug

# ReleaseSafe: Optimized but keep safety checks
zig build -Doptimize=ReleaseSafe

# ReleaseFast: Maximum speed, no safety checks
zig build -Doptimize=ReleaseFast

# ReleaseSmall: Optimize for binary size
zig build -Doptimize=ReleaseSmall
```

**For development**: Use Debug (easier debugging) or ReleaseSafe (test optimizations with safety).

**For deployment**: ReleaseFast (N900 needs speed) or ReleaseSmall (if binary size matters).

### GDB on N900

Remote debugging over SSH.

**On N900**:
```bash
# Install gdbserver (if not already installed)
apt-get install gdbserver

# Run agent under gdbserver
gdbserver :1234 ./zig-agent
```

**On development machine**:
```bash
# Cross-compile for ARM with debug symbols
zig build -Dtarget=arm-linux-musleabi -Doptimize=Debug

# Connect GDB
gdb-multiarch ./zig-agent
(gdb) target remote n900:1234
(gdb) break main
(gdb) continue
```

**Commands**:
```
(gdb) backtrace         # Stack trace
(gdb) print variable    # Inspect variable
(gdb) info locals       # Show local variables
(gdb) watch ptr         # Break when ptr changes
```

### Printf Debugging (Simplest)

```zig
const DEBUG = true;

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
    }
}

// Usage
debugPrint("Allocating message: {d} bytes", .{size});
debugPrint("Arena reset: {d} bytes retained", .{arena.queryCapacity()});
debugPrint("RSS before: {d}MB, after: {d}MB", .{before / 1024 / 1024, after / 1024 / 1024});
```

**Output**:
```
[DEBUG] Allocating message: 1024 bytes
[DEBUG] Arena reset: 2048 bytes retained
[DEBUG] RSS before: 15MB, after: 16MB
```

**Use for**: Quick iteration on N900 (GDB can be slow over SSH).

### Logging Framework

```zig
const std = @import("std");

pub const Logger = struct {
    level: Level,
    allocator: Allocator,

    pub const Level = enum {
        debug,
        info,
        warn,
        err,
    };

    pub fn init(allocator: Allocator, level: Level) Logger {
        return .{ .allocator = allocator, .level = level };
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.debug)) {
            self.log("DEBUG", fmt, args);
        }
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(Level.info)) {
            self.log("INFO", fmt, args);
        }
    }

    fn log(self: Logger, comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
        const timestamp = std.time.milliTimestamp();
        std.debug.print("[{d}] [{s}] " ++ fmt ++ "\n", .{timestamp} ++ args);
    }
};

// Usage
var logger = Logger.init(allocator, .info);
logger.debug("This won't print (level too low)", .{});
logger.info("Agent started", .{});
logger.warn("Memory usage high: {d}MB", .{rss / 1024 / 1024});
```

## Testing on QEMU (Emulated N900)

Test ARM binaries without physical hardware.

### Setup QEMU User Mode

```bash
# Install QEMU user mode (on development machine)
sudo apt-get install qemu-user-static

# Cross-compile for ARM
zig build -Dtarget=arm-linux-musleabi

# Run binary
qemu-arm-static ./zig-out/bin/zig-agent
```

**Limitations**:
- Performance not representative (emulated)
- Some syscalls may not work
- No real hardware constraints

**Use for**: Quick testing before deploying to N900.

### QEMU System Mode (Full Emulation)

Emulate entire N900 system.

```bash
# Download Maemo image (or build custom)
# Run QEMU with N900-like specs
qemu-system-arm \
  -M n900 \
  -kernel zImage \
  -drive file=rootfs.img,format=raw \
  -m 256M \
  -net nic -net user \
  -serial stdio
```

**Use for**: Testing full system behavior before physical device.

## Integration Testing

### Test Scenarios

```zig
test "memory usage stays under budget" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var agent = try Agent.init(gpa.allocator());
    defer agent.deinit();

    // Simulate 10 turns
    for (0..10) |i| {
        const rss = try getCurrentRSS();
        try agent.executeTurn("Test query");

        // Assert memory budget
        try std.testing.expect(rss < 50 * 1024 * 1024); // <50MB
    }
}

test "arena allocator doesn't leak between turns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        try std.testing.expect(leaked == .ok); // No leaks!
    }

    var agent = try Agent.init(gpa.allocator());
    defer agent.deinit();

    for (0..100) |_| {
        try agent.executeTurn("Test query");
    }
}

test "conversation serialization performance" {
    var conversation = try createTestConversation(100); // 100 messages
    defer conversation.deinit();

    const start = std.time.nanoTimestamp();
    const json = try conversation.serialize();
    const end = std.time.nanoTimestamp();

    const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    // Assert performance target: <10ms
    try std.testing.expect(duration_ms < 10.0);
}
```

### On-Device Testing

Deploy to N900 and monitor:

```bash
# Copy binary to N900
scp zig-out/bin/zig-agent user@n900:/home/user/

# SSH to N900
ssh user@n900

# Run with monitoring
while true; do
    ps aux | grep zig-agent | grep -v grep | awk '{print $6}' # RSS in KB
    sleep 1
done &
./zig-agent
```

**Watch for**:
- Memory growth over time (leaks)
- Peak memory usage (exceeds budget?)
- CPU usage (`top` or `htop`)

## Continuous Monitoring

### Built-in Monitoring

```zig
const Agent = struct {
    allocator: Allocator,
    monitor: MemoryMonitor,
    metrics: Metrics,

    const Metrics = struct {
        turns: usize = 0,
        peak_rss: usize = 0,
        avg_turn_ms: f64 = 0,
    };

    pub fn executeTurn(self: *Agent) !void {
        const start = std.time.nanoTimestamp();
        const rss_before = try getCurrentRSS();

        // Execute turn
        // ...

        const end = std.time.nanoTimestamp();
        const rss_after = try getCurrentRSS();

        // Update metrics
        self.metrics.turns += 1;
        self.metrics.peak_rss = @max(self.metrics.peak_rss, rss_after);

        const duration_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        self.metrics.avg_turn_ms = (self.metrics.avg_turn_ms * @as(f64, @floatFromInt(self.metrics.turns - 1)) + duration_ms) / @as(f64, @floatFromInt(self.metrics.turns));

        // Log every 10 turns
        if (self.metrics.turns % 10 == 0) {
            std.debug.print("Turns: {d}, Peak: {d}MB, Avg: {d:.2}ms\n", .{
                self.metrics.turns,
                self.metrics.peak_rss / 1024 / 1024,
                self.metrics.avg_turn_ms,
            });
        }
    }
};
```

## Summary

### Memory Verification

1. **Development**: Zig GPA with leak detection
2. **Pre-deployment**: Valgrind, Massif, heaptrack
3. **On-device**: RSS monitoring with `/proc/self/statm`
4. **Continuous**: Built-in MemoryMonitor

### Performance Validation

1. **Microbenchmarks**: Test individual functions
2. **Integration tests**: Full agent workflows
3. **On-device profiling**: `perf` on N900

### Debugging

1. **Quick iteration**: Printf debugging
2. **Deep dives**: GDB remote debugging
3. **Cross-platform**: QEMU for pre-deployment testing

### Acceptance Criteria

Before declaring success on N900:

- ✓ Peak RSS < 50MB during 100-turn session
- ✓ No memory leaks (GPA leak detection passes)
- ✓ Serialization < 10ms per turn
- ✓ Arena allocator reuses memory (RSS stable across turns)
- ✓ CPU < 50% average during streaming (single-core)

**Test early, test often, especially on real hardware!**

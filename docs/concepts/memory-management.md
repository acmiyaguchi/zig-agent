# Memory Management

## Strategy

Efficient memory management is critical for running on constrained devices. Zig's explicit control over memory allocation allows us to optimize for minimal overhead.

## Allocator Hierarchy

### General Purpose Allocator (GPA)
- Used for long-lived allocations
- Application state, configuration
- Connection pools

### Arena Allocator
- Used for request-scoped allocations
- Entire conversation turn allocated in arena
- Freed all at once when turn completes
- Prevents fragmentation

### Fixed Buffer Allocator
- Used for streaming buffers
- Pre-allocated fixed-size buffers
- Reused across requests

### Stack Allocation
- Used for small, short-lived data
- Function-local buffers
- Temporary computations

## Memory Budgets

Target memory usage on Nokia N900 (256MB RAM):

- Base runtime: ~5MB
- libxev event loop: ~100KB
- API client buffers: ~2MB
- Streaming parser: ~1MB
- Tool execution: ~10MB
- Conversation state: ~5MB per turn
- User interface: ~2MB

**Total target**: <50MB peak usage (libxev adds negligible ~100KB)

## Subagent Memory Budget

When implementing subagents (v2+), each agent instance requires its own memory allocation. This significantly impacts the total memory budget.

### Memory Per Agent Instance

Each agent (parent or child) requires:

```
Core agent state:        ~5MB
Conversation history:    ~5MB (100 messages)
Tool execution context:  ~10MB
Streaming buffers:       ~2MB
Subtotal per agent:      ~22MB
```

### Multi-Agent Scenarios

#### Scenario 1: Single Agent (v1)
```
Main agent:              ~22MB
API client (shared):     ~2MB
UI (shared):             ~2MB
Total:                   ~26MB ✓ Well under 50MB budget
```

#### Scenario 2: Parent + 1 Child (Sequential)
```
Parent agent:            ~22MB
Child agent:             ~22MB
Shared infrastructure:   ~4MB
Total:                   ~48MB ✓ Just under 50MB budget
```

#### Scenario 3: Parent + 2 Children (Parallel)
```
Parent agent:            ~22MB
Child agent 1:           ~22MB
Child agent 2:           ~22MB
Shared infrastructure:   ~4MB
Total:                   ~70MB ✗ Exceeds 50MB budget!
```

### Strategies for Constrained Devices

#### Option 1: Sequential Subagents (Recommended)

Spawn subagents one at a time, reusing memory:

```zig
const AgentPool = struct {
    gpa: *Allocator,
    subagent_arena: std.heap.ArenaAllocator,

    fn runSubagent(self: *Self, task: SubagentTask) ![]const u8 {
        // Reset arena for new subagent (frees previous)
        _ = self.subagent_arena.reset(.retain_capacity);

        // Run subagent in arena
        const result = try executeSubagent(
            task,
            self.subagent_arena.allocator()
        );

        // Duplicate result to GPA (subagent memory will be freed)
        return try self.gpa.dupe(u8, result);
    }
};
```

**Memory profile**:
- Peak: ~48MB (parent + 1 child)
- After subagent completes: ~26MB (parent only)
- Arena reset is instant (no deallocation overhead)

**Trade-off**: Can't run subagents in parallel, but acceptable for v2.

#### Option 2: Agent Pooling

Pre-allocate fixed number of agent slots:

```zig
const AgentPool = struct {
    slots: [2]AgentSlot,

    const AgentSlot = struct {
        arena: std.heap.ArenaAllocator,
        in_use: bool,
    };

    fn acquireSlot(self: *Self) ?*AgentSlot {
        for (&self.slots) |*slot| {
            if (!slot.in_use) {
                slot.in_use = true;
                _ = slot.arena.reset(.retain_capacity);
                return slot;
            }
        }
        return null; // All slots busy
    }

    fn releaseSlot(self: *Self, slot: *AgentSlot) void {
        slot.in_use = false;
        // Arena memory retained for reuse
    }
};
```

**Memory profile**:
- Peak: ~70MB (parent + 2 children) - **Exceeds budget!**
- Solution: Use only 1 slot, or wait for memory profiling on real device

**Trade-off**: Can run 2 parallel subagents, but exceeds N900 budget.

#### Option 3: Defer Subagents (v1 Approach)

Don't implement subagents until v2+:

```zig
// v1: Single agent only
const Agent = struct {
    arena: std.heap.ArenaAllocator,
    // No subagent support
};
```

**Memory profile**:
- Peak: ~26MB (single agent)
- Simplest, proven to work

**Trade-off**: No context isolation, but sufficient for many tasks.

### Recommended Approach

**v1**: No subagents (Option 3)
- Validate memory assumptions on real N900 hardware
- Prove single agent works reliably
- Measure actual RSS vs theoretical budget

**v2**: Sequential subagents (Option 1)
- Add subagent spawning with arena reuse
- Max 1 subagent at a time (sequential execution)
- Stay within 50MB budget

**v3+**: Consider parallel subagents (Option 2)
- Only if real-world measurements show headroom
- May need to increase budget to 75MB or use aggressive memory reclamation

### Arena Allocator Reuse Pattern

Critical for sequential subagents:

```zig
fn executeTask(pool: *AgentPool, task: Task) !Result {
    // Get subagent arena
    var arena = &pool.subagent_arena;

    // Reset (fast, retains capacity)
    _ = arena.reset(.retain_capacity);

    // Execute subagent (all allocations in arena)
    const result = try runSubagent(task, arena.allocator());

    // Copy result to parent's memory
    const owned_result = try pool.parent_allocator.dupe(u8, result);

    // Arena will be reset on next task (no explicit free needed)
    return owned_result;
}
```

**Why this works**:
- Arena allocator: O(1) reset vs O(n) individual frees
- Capacity retained: No reallocation on next use
- Memory reuse: Same 22MB block for each subagent

### Memory Monitoring

For development and debugging:

```zig
const MemoryMonitor = struct {
    samples: std.ArrayList(Sample),

    const Sample = struct {
        timestamp: i64,
        rss: usize,           // Resident Set Size
        agent_count: usize,   // Active agents
        peak_turn: usize,     // Peak turn memory
    };

    fn sample(self: *Self) !void {
        const rss = try getCurrentRSS();
        try self.samples.append(.{
            .timestamp = std.time.milliTimestamp(),
            .rss = rss,
            .agent_count = countActiveAgents(),
            .peak_turn = getPeakTurnMemory(),
        });
    }

    fn report(self: *Self) !void {
        const max_rss = self.getMaxRSS();
        std.debug.print("Peak RSS: {d}MB\n", .{max_rss / 1024 / 1024});
        std.debug.print("Avg RSS: {d}MB\n", .{self.getAvgRSS() / 1024 / 1024});
    }
};
```

### Testing on Target Hardware

Before enabling subagents on N900:

1. **Single agent baseline**: Measure RSS with various workloads
2. **Synthetic subagent test**: Spawn subagent, measure peak RSS
3. **Real workload test**: Run complex multi-agent tasks
4. **Stress test**: Spawn subagents rapidly (simulate worst case)

**Acceptance criteria**: Peak RSS < 48MB on N900 during normal use.

## Memory Safety

- No use-after-free: Zig's compile-time checks
- No double-free: Clear ownership semantics
- Bounds checking: Array access is always checked
- Leak detection: Test mode tracks all allocations

## Optimization Techniques

1. **Lazy Initialization**: Only allocate when needed
2. **Object Pooling**: Reuse frequently allocated objects
3. **Comptime Allocation**: Move allocations to compile time where possible
4. **Zero-Copy Parsing**: Parse JSON/responses in-place
5. **Buffer Reuse**: Recycle buffers across requests

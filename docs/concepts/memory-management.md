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
- API client buffers: ~2MB
- Streaming parser: ~1MB
- Tool execution: ~10MB
- Conversation state: ~5MB per turn
- User interface: ~2MB

**Total target**: <50MB peak usage

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

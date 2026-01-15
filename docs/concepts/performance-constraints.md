# Performance Constraints

## Target Hardware: Nokia N900

### Specifications
- **CPU**: ARM Cortex-A8 (ARMv7l) @ 600 MHz (single core)
- **RAM**: 256 MB
- **Storage**: 32 GB eMMC
- **OS**: Maemo 5 (Debian-based Linux)
- **Network**: WiFi 802.11b/g/n

### Constraints
- Limited CPU power (10+ year old single-core ARM)
- Constrained memory (shared with OS and other apps)
- No swap (or very slow swap to flash)
- Battery-powered (efficiency matters)

## Performance Targets

### Startup Time
- **Cold start**: <500ms
- **Warm start**: <100ms
- Minimize dynamic linking and initialization

### Memory Usage
- **Idle**: <10MB
- **Active conversation**: <50MB peak
- **Large file operations**: <100MB peak

### Latency
- **Tool execution overhead**: <10ms
- **File read (10KB)**: <5ms
- **Grep (1000 files)**: <1000ms
- **UI responsiveness**: <16ms per frame

### Throughput
- **API streaming**: Process 1000 tokens/sec
- **File I/O**: Limited by storage (20-30 MB/s)
- **JSON parsing**: >10 MB/s

## Optimization Strategies

### Compile-Time Optimization
- Release builds with `-O ReleaseFast` or `-O ReleaseSmall`
- Link-Time Optimization (LTO)
- Strip debug symbols
- Static linking to reduce startup overhead

### Runtime Optimization
- Lazy initialization (defer work until needed)
- Caching frequently accessed data
- Memory pools to reduce allocation overhead
- Zero-copy operations where possible

### ARM-Specific Optimizations
- Use NEON SIMD instructions where available
- Align data structures for efficient access
- Minimize branch mispredictions
- Cache-friendly data layouts

## Benchmarking

Key metrics to track:
1. Binary size (target: <2MB)
2. RSS memory usage over time
3. Startup time (both cold and warm)
4. API response processing latency
5. Tool execution overhead
6. Battery impact (energy per operation)

## Comparison to Claude Code

Official Claude Code (electron-based):
- Binary: ~200MB
- Memory: ~300-500MB
- Startup: 2-5 seconds
- Architecture: x86_64 and arm64 only

Zig-agent targets:
- Binary: <2MB
- Memory: <50MB
- Startup: <500ms
- Architecture: ARMv7l, ARMv8, x86_64

**50-100x improvement in resource efficiency**

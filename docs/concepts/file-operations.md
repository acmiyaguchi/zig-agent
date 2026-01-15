# File Operations

## Overview

Efficient file I/O is critical for tool execution performance. Most agent operations involve reading, writing, or searching files.

## Core Operations

### Read
Read file contents with optional range:
- Full file read
- Line-based ranges (lines N to M)
- Byte-based ranges (bytes N to M)
- Streaming for large files

### Write
Create or overwrite files:
- Atomic writes (write to temp, then rename)
- Create parent directories if needed
- Preserve file permissions where possible

### Edit
Surgical edits to existing files:
- Line-based replacement
- Regex-based search and replace
- Multiple edits in single pass
- Preserve formatting and line endings

### Glob
Pattern-based file discovery:
- Standard glob patterns (*, **, ?, [])
- Recursive directory traversal
- Ignore patterns (.gitignore support)
- Sorted results

### Grep
Content search:
- Line-based matching
- Regex support
- Context lines (before/after)
- Multiple files

## Implementation Details

### Memory-Mapped I/O
For large files (>1MB), use mmap:
- Zero-copy access
- OS handles paging
- Efficient for read-only access

### Buffered I/O
For small files and writes:
- 4KB read buffers
- 16KB write buffers
- Flush on close or explicit sync

### Directory Walking
For glob and grep:
- Depth-first traversal
- Skip hidden directories by default
- Respect .gitignore patterns
- Limit depth to prevent resource exhaustion

## Error Handling

### Common Errors
- File not found
- Permission denied
- Disk full
- Too many open files
- I/O errors (bad sectors, network mounts)

### Recovery Strategies
- Clear error messages with suggested fixes
- Graceful degradation (partial results)
- Automatic retry for transient errors
- User confirmation for destructive operations

## Optimization Techniques

### Parallel I/O
- Read multiple files concurrently
- Use thread pool for CPU-bound operations (parsing)
- Async I/O for network filesystems

### Caching
- Cache directory listings
- Cache file metadata (stat)
- Invalidate on write operations
- LRU eviction for memory pressure

### Zero-Copy Operations
- Pass slices instead of copying
- Use memory-mapped files
- Avoid buffering entire files

## Path Handling

### Path Resolution
- Resolve relative to workspace root
- Normalize paths (remove . and ..)
- Validate no directory traversal (../..)

### Cross-Platform
- Handle both Unix (/) and Windows (\) separators
- Case sensitivity (preserve on case-sensitive FS)
- Long path support

## Safety

### Workspace Isolation
- All paths relative to workspace
- Reject absolute paths outside workspace
- Follow symlinks with caution

### Resource Limits
- Max file size: 10MB for full read
- Max open files: 100
- Max grep results: 1000 files
- Timeout for long operations

# Spec: Tool System

**Capability**: `tool-system`
**Change**: `implement-minimal-viable-agent`
**Status**: Draft

## Purpose

Define tool interface and implement read_file tool. Establishes the pattern for tool execution that v2 will expand upon.

## ADDED Requirements

### Requirement: Tool interface shall define standard contract

**Priority**: Critical

All tools MUST implement:
```zig
const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,  // JSON schema
    execute: *const fn(Allocator, std.json.Value) anyerror!ToolResult,
};

const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,
};
```

#### Scenario: Define a tool

```zig
const read_file_tool = Tool{
    .name = "read_file",
    .description = "Read contents of a file",
    .parameters = .{
        .type = "object",
        .properties = .{
            .path = .{ .type = "string", .description = "Absolute path" },
        },
        .required = &[_][]const u8{"path"},
    },
    .execute = executeReadFile,
};
```

---

### Requirement: read_file tool shall enforce absolute paths

**Priority**: High
**Rationale**: ACP pattern for security

The read_file tool MUST reject any path that is not absolute.

```zig
try executeReadFile(allocator, .{ .object = .{
    .{ "path", .{ .string = "relative/path.txt" } },
}});
// Returns error.RelativePathNotAllowed
```

#### Scenario: Reject relative path

```zig
const result = try executeReadFile(allocator, args);
try testing.expect(!result.success);
try testing.expect(std.mem.indexOf(u8, result.error_message.?, "absolute") != null);
```

---

### Requirement: read_file shall limit file size to 1MB

**Priority**: High
**Rationale**: Memory constraints

The read_file tool MUST reject files larger than 1MB to prevent memory exhaustion on constrained devices.

#### Scenario: Reject oversized file

```zig
// File > 1MB
const result = try executeReadFile(allocator, args);
try testing.expect(!result.success);
try testing.expect(std.mem.indexOf(u8, result.error_message.?, "too large") != null);
```

---

### Requirement: ToolRegistry shall provide lookup by name

**Priority**: Critical

The ToolRegistry MUST allow tools to be registered and retrieved by their string name.

#### Scenario: Register and retrieve tool

```zig
var registry = ToolRegistry.init(allocator);
try registry.register(read_file_tool);

const tool = try registry.get("read_file");
try testing.expectEqualStrings("read_file", tool.name);
```

---

## Non-Requirements

- write_file, edit_file tools (v2)
- bash tool (v2)
- Permission prompts (v2)
- Tool result caching (v2)

## Dependencies

- **Requires**: `project-structure`
- **Provides**: Tools for `agent-core`

## References

- [tool-execution.md](../../../../docs/concepts/tool-execution.md)
- [acp-patterns.md](../../../../docs/concepts/acp-patterns.md#pattern-2-absolute-paths-only)

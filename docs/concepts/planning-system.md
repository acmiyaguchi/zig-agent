# Planning System

## Overview

For complex multi-step tasks, the agent needs explicit task tracking to prevent "context fade" - losing track of what it's doing after many tool calls. A planning system makes the agent's plan visible to both the model and the user.

## The Problem: Context Fade

**Without explicit planning**:
```
Agent: "I'll refactor auth, add tests, and update docs"
... 15 tool calls later ...
Agent: "Wait, what was I working on?"
```

The model's plan exists only in its "head". After filling context with tool results, it forgets the original plan.

**With explicit planning**:
```
[x] Refactor auth module
[>] Add unit tests         <- Currently working on this
[ ] Update documentation
```

Both the model AND user can see progress. The model can update status as it works.

## Design: TodoWrite Tool

Inspired by learn-claude-code v2, the planning system is implemented as a single tool: **TodoWrite**.

### Tool Interface

```zig
const TodoWrite = struct {
    items: []TodoItem,

    const TodoItem = struct {
        content: []const u8,      // "Add unit tests"
        status: Status,            // pending | in_progress | completed
        activeForm: []const u8,    // "Adding unit tests..." (present tense)
    };

    const Status = enum {
        pending,
        in_progress,
        completed,
    };
};
```

### Constraints (Not Arbitrary - These Are Guardrails)

| Rule | Why |
|------|-----|
| Max 20 items | Prevents infinite task lists, forces prioritization |
| Only ONE in_progress | Forces focus on one thing at a time |
| Required fields | Ensures structured, parseable output |

**Key insight**: "Structure constrains AND enables."

These constraints ENABLE complex task completion by forcing focus and preventing the model from getting overwhelmed.

## Memory Budget

For 20-item task list on Nokia N900:

```
Struct overhead:     ~400 bytes (20 × 20 bytes)
String storage:      ~2KB (content + activeForm)
Rendered output:     ~1KB (cached display string)
Total:               ~3.5KB
```

**Negligible** in the context of 50MB budget. Planning system pays for itself by preventing wasted work.

## Implementation Strategy

### Storage

```zig
const TodoManager = struct {
    allocator: Allocator,
    items: std.ArrayList(TodoItem),
    max_items: usize = 20,

    fn update(self: *Self, new_items: []const TodoItem) ![]const u8 {
        // Validate
        try self.validate(new_items);

        // Clear and replace
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(new_items);

        // Return rendered view
        return try self.render();
    }

    fn validate(self: *Self, items: []const TodoItem) !void {
        if (items.len > self.max_items) {
            return error.TooManyTodos;
        }

        var in_progress_count: usize = 0;
        for (items) |item| {
            if (item.status == .in_progress) {
                in_progress_count += 1;
            }
            if (item.content.len == 0 or item.activeForm.len == 0) {
                return error.InvalidTodoItem;
            }
        }

        if (in_progress_count > 1) {
            return error.MultipleInProgress;
        }
    }

    fn render(self: *Self) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);

        for (self.items.items) |item| {
            const mark = switch (item.status) {
                .completed => "[x]",
                .in_progress => "[>]",
                .pending => "[ ]",
            };

            try buffer.writer().print("{s} {s}", .{mark, item.content});

            if (item.status == .in_progress) {
                try buffer.writer().print(" <- {s}", .{item.activeForm});
            }

            try buffer.append('\n');
        }

        const completed = self.countCompleted();
        try buffer.writer().print("\n({d}/{d} completed)", .{completed, self.items.items.len});

        return buffer.toOwnedSlice();
    }
};
```

### Tool Registration

```zig
const TODO_TOOL = Tool{
    .name = "TodoWrite",
    .description = "Update task list. Use to plan and track multi-step work.",
    .input_schema = .{
        .type = "object",
        .properties = .{
            .items = .{
                .type = "array",
                .description = "Complete list of tasks (replaces existing)",
                .items = .{
                    .type = "object",
                    .properties = .{
                        .content = .{ .type = "string" },
                        .status = .{ .type = "string", .enum = &[_][]const u8{"pending", "in_progress", "completed"} },
                        .activeForm = .{ .type = "string" },
                    },
                    .required = &[_][]const u8{"content", "status", "activeForm"},
                },
            },
        },
        .required = &[_][]const u8{"items"},
    },
};
```

## Usage Patterns

### Initial Planning

User: "Refactor authentication to use JWT"

Model calls TodoWrite:
```json
{
  "items": [
    {"content": "Explore auth codebase", "status": "in_progress", "activeForm": "Exploring auth files"},
    {"content": "Design JWT migration plan", "status": "pending", "activeForm": "Designing JWT migration"},
    {"content": "Implement JWT utilities", "status": "pending", "activeForm": "Implementing JWT utilities"},
    {"content": "Update login endpoints", "status": "pending", "activeForm": "Updating login endpoints"},
    {"content": "Add tests", "status": "pending", "activeForm": "Adding JWT tests"}
  ]
}
```

### Progress Updates

After completing exploration:
```json
{
  "items": [
    {"content": "Explore auth codebase", "status": "completed", "activeForm": "Explored auth files"},
    {"content": "Design JWT migration plan", "status": "in_progress", "activeForm": "Designing JWT migration"},
    ...
  ]
}
```

### Dynamic Planning

Model can ADD tasks as it discovers work:
```json
{
  "items": [
    ...existing tasks...,
    {"content": "Add JWT dependency to build", "status": "pending", "activeForm": "Adding JWT dependency"}
  ]
}
```

## System Prompt Integration

Add planning guidance to system prompt:

```zig
const SYSTEM_PROMPT =
    \\You are a coding agent. For multi-step tasks, use TodoWrite to:
    \\1. Plan work upfront
    \\2. Mark tasks in_progress before starting
    \\3. Mark completed when done
    \\4. Add new tasks as you discover them
    \\
    \\Constraints: Max 20 items, only ONE in_progress at a time.
;
```

## Soft Reminders

If model hasn't used TodoWrite in a while (10+ turns), inject reminder:

```zig
fn maybeSendReminder(turns_since_todo: usize) ?[]const u8 {
    if (turns_since_todo > 10) {
        return "<reminder>Consider using TodoWrite to track progress.</reminder>";
    }
    return null;
}
```

Reminders are injected as part of user message (not system prompt), preserving cache.

## Benefits

### For the Model
- **Prevents forgetting**: Plan is externalized, not just in model's context
- **Maintains focus**: One in_progress constraint prevents task-switching
- **Shows progress**: Completed items provide sense of accomplishment

### For the User
- **Visibility**: See what agent is doing and what's left
- **Debugging**: If agent gets stuck, check todos to see where
- **Trust**: Explicit plan shows agent has a strategy

### For Constrained Devices
- **Minimal overhead**: ~3.5KB memory
- **Reduces wasted work**: Prevents repeating completed tasks
- **Better error recovery**: Agent can resume from last completed task

## When to Use

**Use TodoWrite when**:
- Task has 3+ distinct steps
- Task will take >5 tool calls
- User explicitly lists multiple things to do

**Don't use TodoWrite when**:
- Single simple task ("read this file")
- Exploratory query ("what does this code do?")
- Task is trivial (<3 steps)

## Alternative: Simpler Tracking

For v1, even simpler approach:

```zig
// Just track current task in agent state
const AgentState = struct {
    current_task: ?[]const u8 = null,
};

// Model sets via special text marker
// Parser: Look for "TASK: doing something" in model output
```

**Trade-off**: Less structured, but zero API/tool complexity.

**Recommendation**: Start with TodoWrite. Only simplify if model struggles to use it correctly.

## Relationship to Subagents

Planning system and subagents are complementary:

```
Main Agent Todo:
  [x] Explore codebase
  [>] Implement feature
  [ ] Add tests

The "Explore codebase" step might spawn an explore subagent.
The subagent has its own (optional) todos for exploration subtasks.
```

Each subagent can have its own planning, but it's optional for short-lived tasks.

## Testing Strategy

Test that TodoWrite:
- Rejects >20 items
- Rejects multiple in_progress
- Rejects missing fields
- Renders correctly
- Handles updates (add/remove items)

Memory test:
- Create 20-item list, measure RSS
- Verify <5KB overhead

## Future Enhancements

### v2: Persistent Todos

Save/load from disk for session resumption:

```zig
fn saveTodos(path: []const u8, todos: TodoManager) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try std.json.stringify(todos.items.items, .{}, file.writer());
}
```

### v3: Todo Dependencies

Allow marking dependencies:
```json
{"content": "Run tests", "status": "pending", "depends_on": ["Build project"]}
```

**Verdict**: Defer until proven necessary. Keep v1 simple.

## Summary

**Planning system = TodoWrite tool with constraints**:
- Max 20 items
- One in_progress
- Required fields (content, status, activeForm)

**Memory**: ~3.5KB (negligible)

**Benefit**: Prevents context fade, maintains focus, provides visibility

**When**: Multi-step tasks with 3+ steps

**Philosophy**: Structure constrains AND enables. Good constraints are scaffolding, not limitations.

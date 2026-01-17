# Spec Delta: Context Tracking - Basic Token Counter

**Capability**: `context-tracking`
**Change**: `implement-agent-v2`
**Status**: Draft

## Purpose

Track and display cumulative token usage in the status line. This gives users rough visibility into resource consumption without the complexity of percentage tracking or context warnings.

## Context

V1 had no token tracking. V2 adds basic token counting:
- Request usage via `stream_options: { include_usage: true }` in API calls
- Parse token counts from OpenRouter's `usage` field in streaming responses
- Accumulate across turns
- Display in status line

**Deferred to v2.1**:
- Percentage of context used (requires knowing model limits)
- Warning at 80%/95% context
- Model-specific context capacities
- Conservative multipliers for estimation

The goal is simple visibility: users see "Tokens: 12.3K" and can track their usage.

## ADDED Requirements

### Requirement: Agent shall track cumulative token usage

**Priority**: High
**Rationale**: Users need basic visibility into resource consumption

The Agent SHALL:
- Maintain `total_input_tokens: u32` counter
- Maintain `total_output_tokens: u32` counter
- Update counters after each API call from response usage field
- Preserve counts across multiple turns (cumulative)

#### Scenario: Token accumulation across turns

```zig
var agent = try Agent.init(allocator, &api_client, &tools, event_handler);
defer agent.deinit();

// Turn 1: API response includes usage
// usage: { input_tokens: 100, completion_tokens: 50 }
try agent.executeTurn("Hello");
// Agent state: total_input=100, total_output=50

// Turn 2: More tokens
// usage: { input_tokens: 200, completion_tokens: 100 }
try agent.executeTurn("Explain quantum computing");
// Agent state: total_input=300, total_output=150

// Total tokens for display: 450
```

---

### Requirement: API client shall request and extract usage from responses

**Priority**: High
**Rationale**: Usage data comes from OpenRouter API responses

The APIClient SHALL:
- Include `stream_options: { include_usage: true }` in request body
- Parse `usage.prompt_tokens` and `usage.completion_tokens` from streaming response
- Handle missing usage field gracefully (use 0)
- Emit usage via callback for tracking

#### Scenario: Request includes stream_options

```json
{
  "model": "anthropic/claude-sonnet-4",
  "messages": [...],
  "stream": true,
  "stream_options": { "include_usage": true }
}
```

#### Scenario: Extract usage from streaming response

```zig
// OpenRouter returns chunk with usage field:
// data: {"choices":[...], "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}}

// APIClient parses and emits via callback:
callback(.{ .usage = .{
    .prompt_tokens = 100,
    .completion_tokens = 50,
} }, context);
```

#### Scenario: Handle missing usage field

```zig
// Some API responses might not include usage
// APIClient returns default:
const usage = ApiUsage{
    .input_tokens = 0,
    .completion_tokens = 0,
};
```

---

### Requirement: Terminal UI status line shall display token count

**Priority**: High
**Rationale**: Users need visible feedback on token consumption

The Terminal UI SHALL:
- Display status line at bottom of screen (y = height - 1)
- Show format: `Tokens: X.XK` (e.g., "Tokens: 12.3K")
- Update after each turn
- Use distinct visual styling (optional: dim colors)

#### Scenario: Status line display

```
Interactive agent session:

> Read the README and explain what this project does
... model response ...

Tokens: 2.3K
         ↑ status line shows cumulative token count

> Next question
...

Tokens: 4.7K
         ↑ status line updated
```

---

### Requirement: Token display shall format large numbers readably

**Priority**: Medium
**Rationale**: "12345" is harder to read than "12.3K"

Token display SHALL:
- Show counts < 1000 as raw numbers (e.g., "Tokens: 456")
- Show counts >= 1000 as K format with one decimal (e.g., "Tokens: 12.3K")
- Show counts >= 1000000 as M format (e.g., "Tokens: 1.2M")

#### Scenario: Formatting examples

```
Tokens: 456      // raw count < 1K
Tokens: 1.2K     // 1200 tokens
Tokens: 12.3K    // 12300 tokens
Tokens: 123.4K   // 123400 tokens
Tokens: 1.2M     // 1200000 tokens (rare)
```

---

## Non-Requirements (Out of Scope for v2)

- Percentage of context used (requires model-specific limits)
- Warning when approaching context limit (80%/95%)
- Model-specific context capacities
- Conservative token estimation multipliers
- Per-function token tracking
- Context window pruning
- Token limit enforcement
- Cost estimation

## Dependencies

- **Requires**: `api-client` (for usage parsing), `agent-core`, `terminal-ui`
- **Provides**: Token count for UI display

## Testing Strategy

**Unit Tests**:
- Token accumulation across turns
- API response parsing with/without usage field
- Number formatting (raw, K, M)

**Integration Tests**:
- Multi-turn tracking
- Status line updates after each turn

**Manual Tests**:
- Run 10-turn conversation, verify token count increases
- Verify status line displays correctly

## Related Specs

- `api-client` - Parse usage from responses
- `agent-core` - Maintain token counters
- `terminal-ui` - Display status line

## References

- [Design: Token Tracking](../../design.md#decision-6-token-tracking---use-openrouters-usage-field)

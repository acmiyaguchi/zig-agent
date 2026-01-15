# Streaming Response Handling

## Overview

Claude API returns responses as Server-Sent Events (SSE). Efficient streaming is essential for responsiveness and memory efficiency.

## SSE Protocol

```
data: {"type":"message_start",...}

data: {"type":"content_block_delta","delta":{"text":"Hello"}}

data: {"type":"message_delta",...}

data: [DONE]
```

## Parser Design

### Requirements
- Incremental parsing (no buffering entire response)
- Handle partial events across buffer boundaries
- Decode JSON events on-the-fly
- Memory bounded (fixed-size buffers)

### State Machine

```
READING_FIELD → READING_VALUE → PARSING_JSON → EMIT_EVENT
     ↓              ↓                              ↑
     └──────────────┴──────────────────────────────┘
```

## Buffer Management

- Read buffer: 4KB (receive from network)
- Parse buffer: 16KB (accumulate partial events)
- Event buffer: Pool of pre-allocated event objects

When parse buffer is full and no complete event:
- Grow buffer (up to max 64KB)
- If still no event, report error (malformed response)

## Event Types

### Message Start
- Initialize new message context
- Reset tool execution state

### Content Block Delta
- Accumulate text deltas
- Render incrementally to UI
- No need to buffer entire response

### Tool Use
- Parse tool name and parameters
- Dispatch to tool execution engine
- Stream tool output back to API

### Message Stop
- Finalize message
- Clean up arena allocator
- Report token usage

## Backpressure

If downstream consumers (UI, tools) can't keep up:
- Pause reading from network socket
- TCP flow control naturally slows API
- Resume when buffers drain

## Error Recovery

- Malformed SSE: Log and skip event
- Invalid JSON: Attempt partial recovery
- Connection loss: Reconnect and resume if possible
- Timeout: Cancel gracefully

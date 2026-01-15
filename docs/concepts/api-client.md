# API Client

## Overview

The API client handles communication with the Claude API, optimized for low resource usage and efficient streaming.

## HTTP Client Design

### Requirements
- HTTP/2 support for multiplexing
- TLS 1.3 for security
- Streaming response handling
- Connection keep-alive
- Automatic retry with backoff

### Implementation Options

1. **Custom HTTP/2 Client**: Full control, minimal dependencies
2. **Zig std.http**: Built-in, good for simple cases
3. **Binding to libcurl**: Battle-tested, more dependencies

**Decision**: Start with zig std.http, benchmark and optimize as needed.

## Request Lifecycle

```
1. Prepare request body (JSON)
2. Acquire connection from pool
3. Send request headers
4. Stream request body
5. Receive response headers
6. Stream response body → Parser
7. Release connection to pool
```

## Connection Management

- Keep-alive connections (reuse TCP/TLS)
- Pool size: 1-2 connections (constrained devices)
- Idle timeout: 30 seconds
- Request timeout: 300 seconds (long-running generations)

## Error Handling

- Network errors: Retry with exponential backoff
- Rate limits: Respect Retry-After headers
- Parse errors: Fail fast with clear error messages
- Timeout: Cancel and report to user

## Streaming Optimization

- Incremental JSON parsing (don't buffer entire response)
- Yield parsed chunks to UI as they arrive
- Backpressure: Slow down if UI can't keep up
- Cancel support: Allow user to interrupt long requests

## Authentication

- API key stored securely (environment variable or config file)
- Added to all requests via Authorization header
- No caching of credentials in memory beyond request scope

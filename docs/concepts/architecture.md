# Architecture

## Overview

Zig-agent is a high-performance, resource-efficient coding agent designed to run on constrained devices (e.g., Nokia N900 with ARMv7l architecture). It provides Claude-powered assistance in environments where the official Claude Code CLI is too resource-intensive.

## Design Goals

1. **Low Memory Footprint**: Target <50MB RAM usage during operation
2. **Fast Startup**: Cold start in <500ms
3. **Efficient Streaming**: Handle API responses with minimal buffering
4. **Static Linking**: Single binary deployment with no runtime dependencies
5. **Cross-Architecture Support**: ARM (armv7l, aarch64) and x86_64

## System Components

### Core Agent
- Main event loop and request orchestrator
- Conversation state management
- Tool dispatch system

### API Client
- HTTP/2 client for Claude API
- Streaming response parser
- Connection pooling and retry logic

### Tool Execution Engine
- Sandboxed command execution
- File system operations
- Code editing and analysis tools

### User Interface
- Terminal UI with minimal dependencies
- Streaming output rendering
- Interactive prompts and confirmations

## Data Flow

```
User Input → Agent Core → API Client → Claude API
                ↓              ↓
           Tool Execution   ← Streaming Response
                ↓
           File System / Shell
                ↓
           Response → User
```

## Memory Management Strategy

- Arena allocators for request-scoped memory
- Pool allocators for frequently allocated small objects
- Streaming parsers to avoid loading entire responses in memory
- Zero-copy operations where possible

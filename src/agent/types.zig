const std = @import("std");
const api_types = @import("../api/types.zig");

pub const AgentUpdate = union(enum) {
    thought: []const u8,
    message_chunk: []const u8,
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    tool_result: struct {
        id: []const u8,
        output: []const u8,
        success: bool,
    },
    completion: ?[]const u8,
    @"error": []const u8,
    memory_warning: struct {
        rss_kb: u64,
        threshold_kb: u64,
    },
};

pub const AgentEventHandler = *const fn (update: AgentUpdate, context: *anyopaque) void;

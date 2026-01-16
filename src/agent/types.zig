// Agent Types
const std = @import("std");

pub const AgentUpdate = union(enum) {
    thought: []const u8,
    // Add other variants later
};

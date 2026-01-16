// Agent Core logic
const std = @import("std");

pub const Agent = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Agent {
        return Agent{ .allocator = allocator };
    }
};

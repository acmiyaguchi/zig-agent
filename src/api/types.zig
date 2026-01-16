// API Types
const std = @import("std");

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

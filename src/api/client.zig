// API Client
const std = @import("std");

pub const APIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !APIClient {
        return APIClient{
            .allocator = allocator,
            .api_key = api_key,
        };
    }
};

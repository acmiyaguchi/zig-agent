// Agent Core logic
const std = @import("std");
const api = @import("api");
const utils = @import("utils");
const logging = utils.logging;
const system = utils.system;
const api_types = api.types;
const agent_types = @import("types.zig");
const client = api.client;
const registry = api.registry;

pub const ConversationState = struct {
    messages: std.ArrayList(api_types.Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConversationState {
        return ConversationState{
            .messages = std.ArrayList(api_types.Message){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConversationState) void {
        for (self.messages.items) |msg| {
            if (msg.content) |c| self.allocator.free(c);
            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.function.name);
                    self.allocator.free(tc.function.arguments);
                }
                self.allocator.free(tcs);
            }
            if (msg.tool_call_id) |id| self.allocator.free(id);
            if (msg.name) |n| self.allocator.free(n);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn addMessage(self: *ConversationState, message: api_types.Message) !void {
        try self.messages.append(self.allocator, message);
    }

    pub fn getHistory(self: *ConversationState) []const api_types.Message {
        return self.messages.items;
    }

    pub fn clear(self: *ConversationState) void {
        self.messages.clearRetainingCapacity();
    }
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    api_client: *client.APIClient,
    tools: *registry.ToolRegistry,
    conversation: ConversationState,
    eventHandler: agent_types.AgentEventHandler,
    context: *anyopaque,
    confirmationHandler: ?agent_types.ConfirmationHandler = null,
    confirmation_context: ?*anyopaque = null,
    total_input_tokens: u32 = 0,
    total_output_tokens: u32 = 0,

    const memory_warning_threshold: usize = 40 * 1024 * 1024; // 40MB
    const memory_refuse_threshold: usize = 45 * 1024 * 1024; // 45MB

    pub fn init(
        allocator: std.mem.Allocator,
        api_client: *client.APIClient,
        tools: *registry.ToolRegistry,
        eventHandler: agent_types.AgentEventHandler,
        context: *anyopaque,
    ) Agent {
        return Agent{
            .allocator = allocator,
            .api_client = api_client,
            .tools = tools,
            .conversation = ConversationState.init(allocator),
            .eventHandler = eventHandler,
            .context = context,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.conversation.deinit();
    }

    pub fn executeTurn(self: *Agent, user_input: []const u8) !void {
        logging.debugLog("[agent] executeTurn called with input: {s}", .{user_input});

        // Check memory usage
        if (system.getCurrentRSS(self.allocator)) |rss| {
            if (rss >= Agent.memory_refuse_threshold) {
                self.emit(.{ .@"error" = "Memory limit exceeded (45MB). Please restart." });
                return;
            }
            if (rss >= Agent.memory_warning_threshold) {
                self.emit(.{ .memory_warning = .{
                    .rss_kb = rss / 1024,
                    .threshold_kb = Agent.memory_warning_threshold / 1024,
                } });
            }
        }

        // Add user message
        try self.conversation.addMessage(.{
            .role = .user,
            .content = try self.allocator.dupe(u8, user_input),
        });

        self.emit(.{ .thought = "Thinking..." });

        const max_turns = 10;

        var turn: usize = 0;
        while (turn < max_turns) : (turn += 1) {
            const messages = self.conversation.getHistory();
            const tool_defs = try self.tools.toApiDefinitions(self.allocator);
            defer self.allocator.free(tool_defs);

            var current_content = std.ArrayList(u8){};
            defer current_content.deinit(self.allocator);

            var current_tool_calls = std.ArrayList(api_types.ToolCall){};
            defer {
                for (current_tool_calls.items) |tc| {
                    self.allocator.free(tc.id);
                    self.allocator.free(tc.function.name);
                    self.allocator.free(tc.function.arguments);
                }
                current_tool_calls.deinit(self.allocator);
            }

            // Helper struct to track partial tool calls during streaming
            const PartialToolCall = struct {
                index: usize,

                // zlinter-disable-next-line field_naming - Required by external JSON API
                id: ?std.ArrayList(u8) = null,
                name: ?std.ArrayList(u8) = null,
                arguments: ?std.ArrayList(u8) = null,
            };
            var partial_tool_calls = std.AutoHashMap(usize, PartialToolCall).init(self.allocator);
            defer {
                var it = partial_tool_calls.valueIterator();
                while (it.next()) |ptc| {
                    if (ptc.id) |*x| x.deinit(self.allocator);
                    if (ptc.name) |*x| x.deinit(self.allocator);
                    if (ptc.arguments) |*x| x.deinit(self.allocator);
                }
                partial_tool_calls.deinit();
            }

            const CallbackCtx = struct {
                agent: *Agent,
                content: *std.ArrayList(u8),
                partials: *std.AutoHashMap(usize, PartialToolCall),
            };
            var ctx = CallbackCtx{
                .agent = self,
                .content = &current_content,
                .partials = &partial_tool_calls,
            };

            // Stream handler
            const callback = struct {
                fn call(chunk: api_types.StreamChunk, c: *anyopaque) void {
                    const context_ptr: *CallbackCtx = @ptrCast(@alignCast(c));
                    const agent = context_ptr.agent;

                    switch (chunk) {
                        .content => |text| {
                            context_ptr.content.appendSlice(agent.allocator, text) catch |err| {
                                logging.debugLog("Failed to append content chunk: {any}", .{err});
                            };
                            agent.emit(.{ .message_chunk = text });
                        },
                        .tool_call_start => |tc| {
                            var ptc = PartialToolCall{ .index = tc.index };
                            ptc.id = std.ArrayList(u8){};
                            ptc.id.?.appendSlice(agent.allocator, tc.id) catch |err| {
                                logging.debugLog("Failed to append tool call id: {any}", .{err});
                            };
                            ptc.name = std.ArrayList(u8){};
                            ptc.name.?.appendSlice(agent.allocator, tc.name) catch |err| {
                                logging.debugLog("Failed to append tool call name: {any}", .{err});
                            };
                            ptc.arguments = std.ArrayList(u8){};

                            context_ptr.partials.put(tc.index, ptc) catch |err| {
                                logging.debugLog("Failed to store partial tool call: {any}", .{err});
                            };
                        },
                        .tool_call_delta => |tc| {
                            if (context_ptr.partials.getPtr(tc.index)) |ptc| {
                                if (ptc.arguments) |*args| {
                                    args.appendSlice(agent.allocator, tc.arguments) catch |err| {
                                        logging.debugLog("Failed to append tool call arguments: {any}", .{err});
                                    };
                                }
                            }
                        },
                        .finish => |reason| {
                            _ = reason;
                            // agent.emit(.{ .completion = reason });
                        },
                        .usage => |usage| {
                            agent.total_input_tokens += usage.prompt_tokens;
                            agent.total_output_tokens += usage.completion_tokens;
                            agent.emit(.{ .usage_update = .{
                                .total_input_tokens = agent.total_input_tokens,
                                .total_output_tokens = agent.total_output_tokens,
                            } });
                        },
                    }
                }
            }.call;

            logging.debugLog("[agent] calling streamChatCompletion...", .{});
            try self.api_client.streamChatCompletion(messages, tool_defs, callback, &ctx);
            logging.debugLog("[agent] streamChatCompletion returned", .{});

            // Post-stream processing

            // 1. Reconstruct tool calls from partials
            // Simple approach: Iterate map and build tool calls
            var it = partial_tool_calls.iterator();
            while (it.next()) |entry| {
                const ptc = entry.value_ptr;
                if (ptc.id != null and ptc.name != null and ptc.arguments != null) {
                    const tool_id = try ptc.id.?.toOwnedSlice(self.allocator);
                    const name = try ptc.name.?.toOwnedSlice(self.allocator);
                    const args = try ptc.arguments.?.toOwnedSlice(self.allocator);

                    try current_tool_calls.append(self.allocator, .{
                        .id = tool_id,
                        .type = "function",
                        .function = .{
                            .name = name,
                            .arguments = args,
                        },
                    });

                    // Prevent deinit of these fields in the defer block for partials
                    ptc.id = null;
                    ptc.name = null;
                    ptc.arguments = null;
                }
            }

            // 2. Add assistant message to history
            const content = if (current_content.items.len > 0) try current_content.toOwnedSlice(self.allocator) else null;

            var tcs: ?[]api_types.ToolCall = null;
            if (current_tool_calls.items.len > 0) {
                tcs = try self.allocator.alloc(api_types.ToolCall, current_tool_calls.items.len);
                for (current_tool_calls.items, 0..) |src, i| {
                    tcs.?[i] = .{
                        .id = try self.allocator.dupe(u8, src.id),
                        .type = "function",
                        .function = .{
                            .name = try self.allocator.dupe(u8, src.function.name),
                            .arguments = try self.allocator.dupe(u8, src.function.arguments),
                        },
                    };
                }
            }

            const assistant_msg = api_types.Message{
                .role = .assistant,
                .content = content,
                .tool_calls = tcs,
            };

            try self.conversation.addMessage(assistant_msg);

            // If we have tool calls, execute them
            if (tcs) |calls| {
                // Notify UI
                for (calls) |tc| {
                    self.emit(.{ .tool_call = .{
                        .id = tc.id,
                        .name = tc.function.name,
                        .arguments = tc.function.arguments,
                    } });
                }

                // Execute tools
                for (calls) |tc| {
                    logging.debugLog("[agent] executing tool: {s}", .{tc.function.name});
                    if (self.tools.find(tc.function.name)) |tool| {
                        // Check if confirmation is required
                        if (tool.requires_confirmation) {
                            logging.debugLog("[agent] tool requires confirmation", .{});
                            if (self.confirmationHandler) |handler| {
                                const confirmed = handler(
                                    tc.function.name,
                                    tc.function.arguments,
                                    self.confirmation_context.?,
                                );
                                if (!confirmed) {
                                    // User denied - add cancellation message
                                    const cancel_msg = try std.fmt.allocPrint(
                                        self.allocator,
                                        "Tool execution cancelled by user.",
                                        .{},
                                    );

                                    try self.conversation.addMessage(.{
                                        .role = .tool,
                                        .content = cancel_msg,
                                        .tool_call_id = try self.allocator.dupe(u8, tc.id),
                                        .name = try self.allocator.dupe(u8, tool.name),
                                    });

                                    self.emit(.{ .tool_result = .{
                                        .id = tc.id,
                                        .output = "Tool execution cancelled by user.",
                                        .success = false,
                                    } });
                                    continue;
                                }
                            }
                        }

                        logging.debugLog("[agent] calling tool.execute for {s}", .{tc.function.name});
                        const result = tool.execute(self.allocator, tc.function.arguments) catch |err| blk: {
                            // Handle unexpected error (e.g. OOM) during execution wrapper
                            // (Actual tool errors are returned as ToolResult with success=false)
                            // Create a synthetic result for the crash
                            const err_msg = try std.fmt.allocPrint(self.allocator, "Error executing tool: {any}", .{err});
                            break :blk registry.ToolResult{
                                .success = false,
                                .output = err_msg,
                            };
                        };

                        logging.debugLog("[agent] tool.execute returned, success={}", .{result.success});
                        const output_copy = try self.allocator.dupe(u8, result.output);

                        try self.conversation.addMessage(.{
                            .role = .tool,
                            .content = output_copy,
                            .tool_call_id = try self.allocator.dupe(u8, tc.id),
                            .name = try self.allocator.dupe(u8, tool.name),
                        });

                        self.emit(.{ .tool_result = .{
                            .id = tc.id,
                            .output = result.output,
                            .success = result.success,
                        } });

                        result.deinit(self.allocator);
                    } else {
                        // Tool not found
                        try self.conversation.addMessage(.{
                            .role = .tool,
                            .content = try self.allocator.dupe(u8, "Error: Tool not found"),
                            .tool_call_id = try self.allocator.dupe(u8, tc.id),
                        });
                    }
                }
            } else {
                self.emit(.{ .completion = null });
                return; // Stop if no tool calls
            }
        }
    }

    fn emit(self: *Agent, update: agent_types.AgentUpdate) void {
        self.eventHandler(update, self.context);
    }
};

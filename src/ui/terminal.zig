// Terminal UI using termbox2
const std = @import("std");
const tb = @import("termbox.zig");
const agent_types = @import("../agent/types.zig");

/// Line type for coloring different kinds of output
const LineType = enum {
    normal,
    user_input,
    assistant,
    thinking,
    tool_call,
    tool_result,
    tool_error,
    error_msg,
    warning,
    system,
};

/// A line of output with its type for coloring
const OutputLine = struct {
    text: []const u8,
    line_type: LineType,
};

/// A segment of text for rendering (split by newlines and width wrapping)
const TextSegment = struct {
    text: []const u8,
    is_continuation: bool, // true if wrapped due to width, false if from newline
};

/// Terminal UI state and rendering
pub const TerminalUI = struct {
    allocator: std.mem.Allocator,
    output_lines: std.ArrayList(OutputLine),
    input_buffer: std.ArrayList(u8),
    scroll_offset: usize,
    cursor_pos: usize,
    initialized: bool,
    width: usize,
    height: usize,
    total_input_tokens: u32 = 0,
    total_output_tokens: u32 = 0,

    // Color definitions (using basic 8 colors for compatibility)
    const COLOR_DEFAULT: u64 = tb.TB_DEFAULT;
    const COLOR_USER: u64 = 0x04; // Blue
    const COLOR_ASSISTANT: u64 = 0x02; // Green
    const COLOR_THINKING: u64 = 0x06; // Cyan
    const COLOR_TOOL: u64 = 0x05; // Magenta
    const COLOR_ERROR: u64 = 0x01; // Red
    const COLOR_WARNING: u64 = 0x03; // Yellow
    const COLOR_SYSTEM: u64 = 0x07; // White (dim)

    // Maximum number of screen lines for user input display
    const MAX_INPUT_WRAP_LINES: usize = 4;
    // Maximum characters for user input (reasonable limit for LLM messages)
    const MAX_INPUT_CHARS: usize = 2000;

    pub fn init(allocator: std.mem.Allocator) TerminalUI {
        return TerminalUI{
            .allocator = allocator,
            .output_lines = std.ArrayList(OutputLine){},
            .input_buffer = std.ArrayList(u8){},
            .scroll_offset = 0,
            .cursor_pos = 0,
            .initialized = false,
            .width = 80,
            .height = 24,
        };
    }

    pub fn deinit(self: *TerminalUI) void {
        // Free all stored line texts
        for (self.output_lines.items) |line| {
            self.allocator.free(line.text);
        }
        self.output_lines.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);

        if (self.initialized) {
            tb.shutdown();
        }
    }

    /// Initialize termbox2 - call this before rendering
    pub fn initTermbox(self: *TerminalUI) !void {
        try tb.init();
        self.initialized = true;
        self.width = @intCast(tb.width());
        self.height = @intCast(tb.height());
    }

    /// Add a line to the output buffer
    pub fn addLine(self: *TerminalUI, text: []const u8, line_type: LineType) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        try self.output_lines.append(self.allocator, .{
            .text = text_copy,
            .line_type = line_type,
        });

        // Auto-scroll to bottom when new content arrives
        self.scrollToBottom();
    }

    /// Append text to the last line (for streaming chunks)
    pub fn appendToLastLine(self: *TerminalUI, text: []const u8) !void {
        if (self.output_lines.items.len == 0) {
            try self.addLine(text, .assistant);
            return;
        }

        const last_idx = self.output_lines.items.len - 1;
        const old_line = self.output_lines.items[last_idx];

        // Allocate new combined text
        const new_text = try self.allocator.alloc(u8, old_line.text.len + text.len);
        @memcpy(new_text[0..old_line.text.len], old_line.text);
        @memcpy(new_text[old_line.text.len..], text);

        // Free old and update
        self.allocator.free(old_line.text);
        self.output_lines.items[last_idx].text = new_text;

        self.scrollToBottom();
    }

    /// Scroll to show the bottom of output
    fn scrollToBottom(self: *TerminalUI) void {
        const visible_lines = self.getVisibleLineCount();
        const total_wrapped = self.countWrappedLines();

        if (total_wrapped > visible_lines) {
            self.scroll_offset = total_wrapped - visible_lines;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Count total lines after word wrapping
    fn countWrappedLines(self: *TerminalUI) usize {
        var count: usize = 0;
        for (self.output_lines.items) |line| {
            count += self.countLineWraps(line.text);
        }
        return count;
    }

    /// Count how many screen lines a single output line takes (newline-aware)
    fn countLineWraps(self: *TerminalUI, text: []const u8) usize {
        if (text.len == 0) return 1;
        const w = if (self.width > 0) self.width else 80;

        var count: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;

        while (i <= text.len) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line_len = i - line_start;
                if (line_len == 0) {
                    count += 1;
                } else {
                    count += (line_len + w - 1) / w;
                }
                line_start = i + 1;
            }
            i += 1;
        }

        return if (count == 0) 1 else count;
    }

    /// Count input wrap lines (capped for display)
    fn countInputWrapLines(self: *TerminalUI) usize {
        const input_len = self.input_buffer.items.len;
        if (input_len == 0) return 1;
        const prompt_len: usize = 2; // "> "
        const available_width = if (self.width > prompt_len) self.width - prompt_len else 1;
        const raw_wraps = (input_len + available_width - 1) / available_width;
        return @min(raw_wraps, MAX_INPUT_WRAP_LINES);
    }

    /// Split text into segments by newlines and width wrapping
    /// Caller must deinit the returned ArrayList
    fn splitTextIntoSegments(self: *TerminalUI, text: []const u8) std.ArrayList(TextSegment) {
        var segments = std.ArrayList(TextSegment){};
        const w = if (self.width > 0) self.width else 80;

        if (text.len == 0) {
            segments.append(self.allocator, .{ .text = "", .is_continuation = false }) catch {};
            return segments;
        }

        var line_start: usize = 0;
        var i: usize = 0;

        while (i <= text.len) {
            const is_newline = i < text.len and text[i] == '\n';
            const is_end = i == text.len;

            if (is_newline or is_end) {
                const line = text[line_start..i];

                // Width-wrap this logical line
                if (line.len == 0) {
                    segments.append(self.allocator, .{ .text = "", .is_continuation = false }) catch {};
                } else {
                    var offset: usize = 0;
                    var first_segment = true;
                    while (offset < line.len) {
                        const end = @min(offset + w, line.len);
                        segments.append(self.allocator, .{
                            .text = line[offset..end],
                            .is_continuation = !first_segment,
                        }) catch {};
                        offset = end;
                        first_segment = false;
                    }
                }

                line_start = i + 1;
            }
            i += 1;
        }

        return segments;
    }

    /// Get number of lines available for output (excluding input area)
    fn getVisibleLineCount(self: *TerminalUI) usize {
        const input_lines = self.countInputWrapLines();
        if (self.height <= input_lines + 1) return 1;
        return self.height - input_lines - 1; // Reserve space for input + 1 line buffer
    }

    /// Get color for a line type
    fn getColor(line_type: LineType) u64 {
        return switch (line_type) {
            .normal => COLOR_DEFAULT,
            .user_input => COLOR_USER,
            .assistant => COLOR_ASSISTANT,
            .thinking => COLOR_THINKING,
            .tool_call => COLOR_TOOL,
            .tool_result => COLOR_TOOL,
            .tool_error => COLOR_ERROR,
            .error_msg => COLOR_ERROR,
            .warning => COLOR_WARNING,
            .system => COLOR_SYSTEM,
        };
    }

    /// Render all output lines with scrolling
    pub fn renderOutput(self: *TerminalUI) !void {
        if (!self.initialized) return;

        try tb.clear();

        const visible_lines = self.getVisibleLineCount();
        var screen_row: usize = 0;
        var lines_skipped: usize = 0;

        // Render each output line with wrapping and newline support
        for (self.output_lines.items) |line| {
            var segments = self.splitTextIntoSegments(line.text);
            defer segments.deinit(self.allocator);

            const color = getColor(line.line_type);

            // Handle scrolling - skip segments before scroll_offset
            if (lines_skipped + segments.items.len <= self.scroll_offset) {
                lines_skipped += segments.items.len;
                continue;
            }

            // Render segments
            for (segments.items) |segment| {
                // Skip segments before scroll offset
                if (lines_skipped < self.scroll_offset) {
                    lines_skipped += 1;
                    continue;
                }

                // Stop if we've filled the visible area
                if (screen_row >= visible_lines) break;

                // Draw this segment
                try self.drawText(0, screen_row, segment.text, color);

                screen_row += 1;
                lines_skipped += 1;
            }

            if (screen_row >= visible_lines) break;
        }
    }

    /// Render the input area at the bottom (supports multi-line wrapping)
    pub fn renderInputLine(self: *TerminalUI) !void {
        if (!self.initialized) return;

        const prompt = "> ";
        const prompt_len: usize = prompt.len;
        const input_text = self.input_buffer.items;
        const available_width = if (self.width > prompt_len) self.width - prompt_len else 1;

        // Calculate how many lines the input takes (capped)
        const input_lines = self.countInputWrapLines();

        // Calculate starting row for input area
        const input_start_row = if (self.height > input_lines) self.height - input_lines else 0;

        // Check if input is truncated (exceeds display limit)
        const total_input_lines = if (input_text.len == 0) 1 else (input_text.len + available_width - 1) / available_width;
        const is_truncated = total_input_lines > MAX_INPUT_WRAP_LINES;

        // If truncated, show from the end so user sees what they're typing
        var text_start: usize = 0;
        if (is_truncated) {
            // Show the last MAX_INPUT_WRAP_LINES worth of text
            const chars_to_show = available_width * MAX_INPUT_WRAP_LINES;
            if (input_text.len > chars_to_show) {
                text_start = input_text.len - chars_to_show;
            }
        }

        // Draw each line of input
        var line_idx: usize = 0;
        var text_offset: usize = text_start;

        while (line_idx < input_lines and (input_start_row + line_idx) < self.height) {
            const row = input_start_row + line_idx;

            if (line_idx == 0) {
                // First line gets prompt, possibly with "..." if truncated
                if (is_truncated) {
                    try self.drawText(0, row, "...", COLOR_SYSTEM);
                } else {
                    try self.drawText(0, row, prompt, COLOR_USER);
                }
            }

            // Draw text segment
            const col_start: usize = if (line_idx == 0) prompt_len else 0;
            const line_width = if (line_idx == 0) available_width else self.width;
            const segment_end = @min(text_offset + line_width, input_text.len);

            if (text_offset < input_text.len) {
                const segment = input_text[text_offset..segment_end];
                try self.drawText(col_start, row, segment, COLOR_DEFAULT);
            }

            text_offset = segment_end;
            line_idx += 1;
        }
    }

    /// Draw a status line (above input)
    pub fn renderStatusLine(self: *TerminalUI, status: []const u8) !void {
        if (!self.initialized) return;
        if (self.height < 2) return;

        const status_row = self.height - 2;

        // Draw separator and status
        try self.drawText(0, status_row, status, COLOR_SYSTEM);
    }

    /// Format token count for display (raw if <1K, K for 1K-999K, M for 1M+)
    fn formatTokenCount(count: u32, buf: []u8) []const u8 {
        if (count < 1000) {
            return std.fmt.bufPrint(buf, "{d}", .{count}) catch "?";
        } else if (count < 1_000_000) {
            const k = @as(f64, @floatFromInt(count)) / 1000.0;
            return std.fmt.bufPrint(buf, "{d:.1}K", .{k}) catch "?K";
        } else {
            const m = @as(f64, @floatFromInt(count)) / 1_000_000.0;
            return std.fmt.bufPrint(buf, "{d:.1}M", .{m}) catch "?M";
        }
    }

    /// Render token usage in status area
    pub fn renderTokenStatus(self: *TerminalUI) !void {
        if (!self.initialized) return;
        if (self.height < 3) return;

        const total = self.total_input_tokens + self.total_output_tokens;
        if (total == 0) return;

        var buf: [32]u8 = undefined;
        const formatted = formatTokenCount(total, &buf);

        var status_buf: [64]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "Tokens: {s}", .{formatted}) catch "Tokens: ?";

        // Draw at the right side of the status row
        const status_row = self.height - 2;
        const x = if (self.width > status.len) self.width - status.len - 1 else 0;
        try self.drawText(x, status_row, status, COLOR_SYSTEM);
    }

    /// Draw text at a position
    fn drawText(self: *TerminalUI, x: usize, y: usize, text: []const u8, fg: u64) !void {
        _ = self;
        var col: c_int = @intCast(x);
        const row: c_int = @intCast(y);

        for (text) |char| {
            if (char == '\n' or char == '\r') continue; // Skip newlines in single-line drawing
            try tb.setCell(col, row, char, fg, tb.TB_DEFAULT);
            col += 1;
        }
    }

    /// Full render cycle
    pub fn render(self: *TerminalUI) !void {
        if (!self.initialized) return;

        try self.renderOutput();
        try self.renderTokenStatus();
        try self.renderInputLine();
        try tb.present();
    }

    /// Handle terminal resize
    pub fn handleResize(self: *TerminalUI) void {
        if (!self.initialized) return;
        self.width = @intCast(tb.width());
        self.height = @intCast(tb.height());
        self.scrollToBottom();
    }

    /// Add a character to input buffer (enforces MAX_INPUT_CHARS limit)
    pub fn addInputChar(self: *TerminalUI, char: u8) !void {
        if (self.input_buffer.items.len >= MAX_INPUT_CHARS) {
            return; // At limit, ignore additional input
        }
        try self.input_buffer.append(self.allocator, char);
        self.cursor_pos = self.input_buffer.items.len;
    }

    /// Delete last character from input buffer
    pub fn deleteInputChar(self: *TerminalUI) void {
        if (self.input_buffer.items.len > 0) {
            _ = self.input_buffer.pop();
            self.cursor_pos = self.input_buffer.items.len;
        }
    }

    /// Get and clear input buffer
    pub fn getAndClearInput(self: *TerminalUI) ![]const u8 {
        const input = try self.allocator.dupe(u8, self.input_buffer.items);
        self.input_buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
        return input;
    }

    /// Clear input buffer without returning
    pub fn clearInput(self: *TerminalUI) void {
        self.input_buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    /// Scroll up by one page
    pub fn scrollUp(self: *TerminalUI) void {
        const page_size = self.getVisibleLineCount();
        if (self.scroll_offset >= page_size) {
            self.scroll_offset -= page_size;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Scroll down by one page
    pub fn scrollDown(self: *TerminalUI) void {
        const page_size = self.getVisibleLineCount();
        const total_wrapped = self.countWrappedLines();
        const max_offset = if (total_wrapped > page_size) total_wrapped - page_size else 0;

        self.scroll_offset = @min(self.scroll_offset + page_size, max_offset);
    }

    /// Handle an agent update event - this is the callback for Agent
    pub fn handleAgentUpdate(update: agent_types.AgentUpdate, context: *anyopaque) void {
        const self: *TerminalUI = @ptrCast(@alignCast(context));

        switch (update) {
            .thought => |t| {
                self.addLine(t, .thinking) catch {};
            },
            .message_chunk => |chunk| {
                // For streaming, append to last assistant line
                if (self.output_lines.items.len > 0) {
                    const last = self.output_lines.items[self.output_lines.items.len - 1];
                    if (last.line_type == .assistant) {
                        self.appendToLastLine(chunk) catch {};
                    } else {
                        self.addLine(chunk, .assistant) catch {};
                    }
                } else {
                    self.addLine(chunk, .assistant) catch {};
                }
            },
            .tool_call => |tc| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[Tool: {s}]", .{tc.name}) catch "[Tool call]";
                self.addLine(msg, .tool_call) catch {};
            },
            .tool_result => |tr| {
                const line_type: LineType = if (tr.success) .tool_result else .tool_error;
                // Truncate long results
                const max_len: usize = 200;
                if (tr.output.len > max_len) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "[Result: {s}...]", .{tr.output[0..max_len]}) catch "[Result]";
                    self.addLine(msg, line_type) catch {};
                } else {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "[Result: {s}]", .{tr.output}) catch "[Result]";
                    self.addLine(msg, line_type) catch {};
                }
            },
            .completion => {
                // Add blank line after completion for readability
                self.addLine("", .normal) catch {};
            },
            .@"error" => |e| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{e}) catch "Error occurred";
                self.addLine(msg, .error_msg) catch {};
            },
            .memory_warning => |mw| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Warning: Memory usage {d}KB (threshold: {d}KB)", .{ mw.rss_kb, mw.threshold_kb }) catch "Memory warning";
                self.addLine(msg, .warning) catch {};
            },
            .usage_update => |usage| {
                self.total_input_tokens = usage.total_input_tokens;
                self.total_output_tokens = usage.total_output_tokens;
            },
        }

        // Re-render after update
        self.render() catch {};
    }

    /// Add user input as a line (for display after Enter)
    pub fn addUserInput(self: *TerminalUI, input: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "> {s}", .{input}) catch input;
        try self.addLine(msg, .user_input);
    }

    /// Request confirmation from user for a tool execution
    /// Returns true if confirmed (Y/y), false if denied (N/n/Enter)
    pub fn requestConfirmation(self: *TerminalUI, tool_name: []const u8, arguments: []const u8) bool {
        // Build confirmation message
        var msg_buf: [512]u8 = undefined;

        // Truncate arguments for display
        const max_args_display: usize = 80;
        const args_display = if (arguments.len > max_args_display)
            arguments[0..max_args_display]
        else
            arguments;

        const suffix = if (arguments.len > max_args_display) "..." else "";
        const msg = std.fmt.bufPrint(&msg_buf, "Execute {s}({s}{s})? [Y/n] ", .{
            tool_name,
            args_display,
            suffix,
        }) catch "Execute tool? [Y/n] ";

        // Add the confirmation line
        self.addLine(msg, .warning) catch {};
        self.render() catch {};

        // Wait for user input
        var event: tb.TbEvent = undefined;
        while (true) {
            // Block until we get an event
            if (tb.peekEvent(&event, 100) catch false) {
                if (event.type == tb.TB_EVENT_KEY) {
                    // Y/y = confirm
                    if (event.ch == 'Y' or event.ch == 'y') {
                        self.addLine("[Confirmed]", .system) catch {};
                        self.render() catch {};
                        return true;
                    }
                    // N/n/Enter = deny
                    if (event.ch == 'N' or event.ch == 'n' or event.key == tb.TB_KEY_ENTER) {
                        self.addLine("[Cancelled]", .warning) catch {};
                        self.render() catch {};
                        return false;
                    }
                    // Ctrl+C = deny and potentially signal quit (handled by caller)
                    if (event.key == tb.TB_KEY_CTRL_C) {
                        self.addLine("[Cancelled]", .warning) catch {};
                        self.render() catch {};
                        return false;
                    }
                } else if (event.type == tb.TB_EVENT_RESIZE) {
                    self.handleResize();
                    self.render() catch {};
                }
            }
        }
    }
};

// Tests
test "terminal ui init and deinit" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    try std.testing.expect(!ui.initialized);
    try std.testing.expectEqual(@as(usize, 0), ui.output_lines.items.len);
}

test "terminal ui add lines" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    try ui.addLine("Hello", .normal);
    try ui.addLine("World", .assistant);

    try std.testing.expectEqual(@as(usize, 2), ui.output_lines.items.len);
    try std.testing.expectEqualStrings("Hello", ui.output_lines.items[0].text);
    try std.testing.expectEqualStrings("World", ui.output_lines.items[1].text);
}

test "terminal ui append to last line" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    try ui.addLine("Hello", .assistant);
    try ui.appendToLastLine(" World");

    try std.testing.expectEqual(@as(usize, 1), ui.output_lines.items.len);
    try std.testing.expectEqualStrings("Hello World", ui.output_lines.items[0].text);
}

test "terminal ui input buffer" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    try ui.addInputChar('h');
    try ui.addInputChar('i');

    try std.testing.expectEqualStrings("hi", ui.input_buffer.items);

    ui.deleteInputChar();
    try std.testing.expectEqualStrings("h", ui.input_buffer.items);

    const input = try ui.getAndClearInput();
    defer allocator.free(input);

    try std.testing.expectEqualStrings("h", input);
    try std.testing.expectEqual(@as(usize, 0), ui.input_buffer.items.len);
}

test "terminal ui line wrapping count" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    ui.width = 10; // Small width for testing

    // Empty line = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), ui.countLineWraps(""));

    // Short line = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), ui.countLineWraps("hello"));

    // Exactly width = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), ui.countLineWraps("0123456789"));

    // Just over width = 2 screen lines
    try std.testing.expectEqual(@as(usize, 2), ui.countLineWraps("01234567890"));

    // Long line = 3 screen lines (output lines are NOT capped)
    try std.testing.expectEqual(@as(usize, 3), ui.countLineWraps("012345678901234567890123456789"));

    // Very long output line wraps fully (no cap on output)
    try std.testing.expectEqual(@as(usize, 7), ui.countLineWraps("0123456789012345678901234567890123456789012345678901234567890"));
}

test "terminal ui input character limit" {
    const allocator = std.testing.allocator;
    var ui = TerminalUI.init(allocator);
    defer ui.deinit();

    // Add characters up to limit
    var i: usize = 0;
    while (i < TerminalUI.MAX_INPUT_CHARS + 10) : (i += 1) {
        ui.addInputChar('x') catch {};
    }

    // Should be capped at MAX_INPUT_CHARS
    try std.testing.expectEqual(TerminalUI.MAX_INPUT_CHARS, ui.input_buffer.items.len);
}

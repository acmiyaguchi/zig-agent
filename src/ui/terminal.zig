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

    // Color definitions (using basic 8 colors for compatibility)
    const COLOR_DEFAULT: u64 = tb.TB_DEFAULT;
    const COLOR_USER: u64 = 0x04; // Blue
    const COLOR_ASSISTANT: u64 = 0x02; // Green
    const COLOR_THINKING: u64 = 0x06; // Cyan
    const COLOR_TOOL: u64 = 0x05; // Magenta
    const COLOR_ERROR: u64 = 0x01; // Red
    const COLOR_WARNING: u64 = 0x03; // Yellow
    const COLOR_SYSTEM: u64 = 0x07; // White (dim)

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

    /// Count how many screen lines a single output line takes
    fn countLineWraps(self: *TerminalUI, text: []const u8) usize {
        if (text.len == 0) return 1;
        const w = if (self.width > 0) self.width else 80;
        return (text.len + w - 1) / w;
    }

    /// Get number of lines available for output (excluding input line)
    fn getVisibleLineCount(self: *TerminalUI) usize {
        if (self.height <= 2) return 1;
        return self.height - 2; // Reserve 2 lines for input area
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

        // Render each output line with wrapping
        for (self.output_lines.items) |line| {
            const wraps = self.countLineWraps(line.text);
            const color = getColor(line.line_type);

            // Handle scrolling - skip lines before scroll_offset
            if (lines_skipped + wraps <= self.scroll_offset) {
                lines_skipped += wraps;
                continue;
            }

            // Render this line (possibly partially if at scroll boundary)
            var text_offset: usize = 0;
            var wrap_idx: usize = 0;

            while (text_offset < line.text.len or (text_offset == 0 and line.text.len == 0)) {
                // Skip wrapped segments before scroll offset
                if (lines_skipped < self.scroll_offset) {
                    lines_skipped += 1;
                    text_offset += self.width;
                    wrap_idx += 1;
                    if (line.text.len == 0) break;
                    continue;
                }

                // Stop if we've filled the visible area
                if (screen_row >= visible_lines) break;

                // Draw this segment
                const segment_end = @min(text_offset + self.width, line.text.len);
                const segment = if (text_offset < line.text.len) line.text[text_offset..segment_end] else "";

                try self.drawText(0, screen_row, segment, color);

                screen_row += 1;
                lines_skipped += 1;
                text_offset += self.width;
                wrap_idx += 1;

                if (line.text.len == 0) break;
            }

            if (screen_row >= visible_lines) break;
        }
    }

    /// Render the input line at the bottom
    pub fn renderInputLine(self: *TerminalUI) !void {
        if (!self.initialized) return;

        const input_row = self.height - 1;
        const prompt = "> ";

        // Draw prompt
        try self.drawText(0, input_row, prompt, COLOR_USER);

        // Draw input buffer
        const input_start = prompt.len;
        const max_input_width = self.width - prompt.len;
        const input_text = self.input_buffer.items;

        if (input_text.len <= max_input_width) {
            try self.drawText(input_start, input_row, input_text, COLOR_DEFAULT);
        } else {
            // Show end of input if it's too long
            const start = input_text.len - max_input_width;
            try self.drawText(input_start, input_row, input_text[start..], COLOR_DEFAULT);
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

    /// Add a character to input buffer
    pub fn addInputChar(self: *TerminalUI, char: u8) !void {
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

    // Long line = multiple screen lines
    try std.testing.expectEqual(@as(usize, 3), ui.countLineWraps("012345678901234567890123456789"));
}

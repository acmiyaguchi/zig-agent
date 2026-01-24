// Terminal UI using termbox2
const std = @import("std");
const tb = @import("termbox");
const agent_types = @import("agent").types;
const utils = @import("utils");
const logging = utils.logging;

pub const key = struct {
    // zlinter-disable declaration_naming - C FFI constants use SCREAMING_SNAKE_CASE
    pub const CTRL_C = tb.TB_KEY_CTRL_C;
    pub const ENTER = tb.TB_KEY_ENTER;
    pub const BACKSPACE = tb.TB_KEY_BACKSPACE;
    pub const BACKSPACE2 = tb.TB_KEY_BACKSPACE2;
    pub const ARROW_UP = tb.TB_KEY_ARROW_UP;
    pub const ARROW_DOWN = tb.TB_KEY_ARROW_DOWN;
    // zlinter-enable declaration_naming
};

pub const EventType = enum {
    key,
    resize,
    mouse,
    other,
};

pub const Event = struct {
    type: EventType,
    key: u16 = 0,
    // zlinter-disable field_naming - FFI mirror fields match C struct TbEvent
    ch: u32 = 0,
    mod: u8 = 0,
    w: i32 = 0,
    h: i32 = 0,
    // zlinter-enable field_naming
};

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
    mutex: std.Thread.Mutex,

    // Timer state for animations
    session_start_ns: i128 = 0,
    thinking_start_ns: i128 = 0,
    is_thinking: bool = false,
    thinking_dots_phase: u2 = 0, // 0, 1, 2 for ".", "..", "..."
    thinking_line_index: ?usize = null,

    // Confirmation state (for cross-thread coordination)
    waiting_for_confirmation: std.atomic.Value(bool),
    confirmation_result: std.atomic.Value(bool),
    confirmation_done: std.atomic.Value(bool),

    // Color definitions (using basic 8 colors for compatibility)
    const color_default: u64 = tb.TB_DEFAULT;
    const color_user: u64 = 0x04; // Blue
    const color_assistant: u64 = 0x02; // Green
    const color_thinking: u64 = 0x06; // Cyan
    const color_tool: u64 = 0x05; // Magenta
    const color_error: u64 = 0x01; // Red
    const color_warning: u64 = 0x03; // Yellow
    const color_system: u64 = 0x07; // White (dim)

    // Maximum number of screen lines for user input display
    const max_input_wrap_lines: usize = 4;
    // Maximum characters for user input (reasonable limit for LLM messages)
    const max_input_chars: usize = 2000;

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
            .mutex = std.Thread.Mutex{},
            .waiting_for_confirmation = std.atomic.Value(bool).init(false),
            .confirmation_result = std.atomic.Value(bool).init(false),
            .confirmation_done = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();
        try tb.init();
        self.initialized = true;
        self.width = @intCast(tb.width());
        self.height = @intCast(tb.height());
        self.session_start_ns = std.time.nanoTimestamp();
    }

    /// Get TTY file descriptor for polling
    pub fn getTtyFd(self: *TerminalUI) !i32 {
        _ = self;
        const fds = try tb.getFds();
        if (fds.len == 0) return error.NoTtyFd;
        return fds[0];
    }

    /// Poll for an event (non-blocking)
    /// Returns null if no event is available
    pub fn pollEvent(self: *TerminalUI) !?Event {
        _ = self;
        var tb_event: tb.TbEvent = undefined;
        // 0 timeout means non-blocking
        const has_event = tb.peekEvent(&tb_event, 0) catch return null;
        if (!has_event) return null;

        return switch (tb_event.type) {
            tb.TB_EVENT_KEY => Event{
                .type = .key,
                .key = tb_event.key,
                .ch = tb_event.ch,
                .mod = tb_event.mod,
            },
            tb.TB_EVENT_RESIZE => Event{
                .type = .resize,
                .w = tb_event.w,
                .h = tb_event.h,
            },
            tb.TB_EVENT_MOUSE => Event{
                .type = .mouse,
                .key = tb_event.key, // Mouse key/button
                .w = tb_event.x, // x position
                .h = tb_event.y, // y position
            },
            else => Event{ .type = .other },
        };
    }

    /// Add a line to the output buffer
    pub fn addLine(self: *TerminalUI, text: []const u8, line_type: LineType) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.addLineLocked(text, line_type);
    }

    // Internal version without lock
    fn addLineLocked(self: *TerminalUI, text: []const u8, line_type: LineType) !void {
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
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.appendToLastLineLocked(text);
    }

    // Internal version without lock
    fn appendToLastLineLocked(self: *TerminalUI, text: []const u8) !void {
        if (self.output_lines.items.len == 0) {
            try self.addLineLocked(text, .assistant);
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
        const width = if (self.width > 0) self.width else 80;

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
                    count += (line_len + width - 1) / width;
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
        return @min(raw_wraps, max_input_wrap_lines);
    }

    /// Split text into segments by newlines and width wrapping
    /// Caller must deinit the returned ArrayList
    fn splitTextIntoSegments(self: *TerminalUI, text: []const u8) std.ArrayList(TextSegment) {
        var segments = std.ArrayList(TextSegment){};
        const width = if (self.width > 0) self.width else 80;

        if (text.len == 0) {
            segments.append(self.allocator, .{ .text = "", .is_continuation = false }) catch |err| {
                logging.debugLog("Failed to append empty segment: {any}", .{err});
            };
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
                    segments.append(self.allocator, .{ .text = "", .is_continuation = false }) catch |err| {
                        logging.debugLog("Failed to append empty line segment: {any}", .{err});
                    };
                } else {
                    var offset: usize = 0;
                    var first_segment = true;
                    while (offset < line.len) {
                        const end = @min(offset + width, line.len);
                        segments.append(self.allocator, .{
                            .text = line[offset..end],
                            .is_continuation = !first_segment,
                        }) catch |err| {
                            logging.debugLog("Failed to append line segment: {any}", .{err});
                        };
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
            .normal => color_default,
            .user_input => color_user,
            .assistant => color_assistant,
            .thinking => color_thinking,
            .tool_call => color_tool,
            .tool_result => color_tool,
            .tool_error => color_error,
            .error_msg => color_error,
            .warning => color_warning,
            .system => color_system,
        };
    }

    /// Render all output lines with scrolling
    pub fn renderOutput(self: *TerminalUI) !void {
        // Locked by caller (render)
        // ... implementation below ...
        return self.renderOutputLocked();
    }

    fn renderOutputLocked(self: *TerminalUI) !void {
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
        // Locked by caller (render)
        return self.renderInputLineLocked();
    }

    fn renderInputLineLocked(self: *TerminalUI) !void {
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
        const is_truncated = total_input_lines > max_input_wrap_lines;

        // If truncated, show from the end so user sees what they're typing
        var text_start: usize = 0;
        if (is_truncated) {
            // Show the last max_input_wrap_lines worth of text
            const chars_to_show = available_width * max_input_wrap_lines;
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
                    try self.drawText(0, row, "...", color_system);
                } else {
                    try self.drawText(0, row, prompt, color_user);
                }
            }

            // Draw text segment
            const col_start: usize = if (line_idx == 0) prompt_len else 0;
            const line_width = if (line_idx == 0) available_width else self.width;
            const segment_end = @min(text_offset + line_width, input_text.len);

            if (text_offset < input_text.len) {
                const segment = input_text[text_offset..segment_end];
                try self.drawText(col_start, row, segment, color_default);
            }

            text_offset = segment_end;
            line_idx += 1;
        }
    }

    /// Draw a status line (above input)
    pub fn renderStatusLine(self: *TerminalUI, status: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.renderStatusLineLocked(status);
    }

    fn renderStatusLineLocked(self: *TerminalUI, status: []const u8) !void {
        if (!self.initialized) return;
        if (self.height < 2) return;

        const status_row = self.height - 2;

        // Draw separator and status
        try self.drawText(0, status_row, status, color_system);
    }

    /// Format token count for display (raw if <1K, K for 1K-999K, M for 1M+)
    fn formatTokenCount(count: u32, buf: []u8) []const u8 {
        if (count < 1000) {
            return std.fmt.bufPrint(buf, "{d}", .{count}) catch "?";
        } else if (count < 1_000_000) {
            const kilo = @as(f64, @floatFromInt(count)) / 1000.0;
            return std.fmt.bufPrint(buf, "{d:.1}K", .{kilo}) catch "?K";
        } else {
            const mega = @as(f64, @floatFromInt(count)) / 1_000_000.0;
            return std.fmt.bufPrint(buf, "{d:.1}M", .{mega}) catch "?M";
        }
    }

    /// Format elapsed nanoseconds as M:SS or H:MM:SS
    fn formatElapsedTime(elapsed_ns: i128, buf: []u8) []const u8 {
        const elapsed_secs: u64 = @intCast(@max(0, @divFloor(elapsed_ns, std.time.ns_per_s)));
        const hours = elapsed_secs / 3600;
        const minutes = (elapsed_secs % 3600) / 60;
        const seconds = elapsed_secs % 60;

        if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "?:??:??";
        } else {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, seconds }) catch "?:??";
        }
    }

    /// Build thinking text with current dots phase and timer
    fn getThinkingText(self: *TerminalUI, buf: []u8) []const u8 {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.thinking_start_ns;

        var time_buf: [16]u8 = undefined;
        const time_str = formatElapsedTime(elapsed, &time_buf);

        const dots: []const u8 = switch (self.thinking_dots_phase) {
            0 => ".",
            1 => "..",
            2 => "...",
            3 => ".",
        };

        return std.fmt.bufPrint(buf, "Thinking{s} {s}", .{ dots, time_str }) catch "Thinking...";
    }

    /// Update the text of a line at the given index (for in-place updates)
    fn updateLineTextLocked(self: *TerminalUI, index: usize, new_text: []const u8) !void {
        if (index >= self.output_lines.items.len) return;

        const old_line = self.output_lines.items[index];
        const new_text_copy = try self.allocator.dupe(u8, new_text);
        self.allocator.free(old_line.text);
        self.output_lines.items[index].text = new_text_copy;
    }

    /// Update the thinking line with current animation state
    pub fn updateThinkingLine(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.is_thinking) return;
        if (self.thinking_line_index) |idx| {
            var buf: [64]u8 = undefined;
            const new_text = self.getThinkingText(&buf);
            self.updateLineTextLocked(idx, new_text) catch |err| {
                logging.debugLog("updateLineTextLocked error: {any}", .{err});
            };
        }
    }

    /// Advance the thinking animation dots phase
    pub fn advanceThinkingPhase(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.thinking_dots_phase = @addWithOverflow(self.thinking_dots_phase, 1)[0];
    }

    /// Render token usage in status area
    pub fn renderTokenStatus(self: *TerminalUI) !void {
        // Locked by caller (render)
        return self.renderTokenStatusLocked();
    }

    fn renderTokenStatusLocked(self: *TerminalUI) !void {
        if (!self.initialized) return;
        if (self.height < 3) return;

        const status_row = self.height - 2;

        // Build session timer
        var session_time_buf: [16]u8 = undefined;
        const now = std.time.nanoTimestamp();
        const session_elapsed = now - self.session_start_ns;
        const session_time = formatElapsedTime(session_elapsed, &session_time_buf);

        // Build status string: "Session: M:SS | Tokens: X.XK" or just "Session: M:SS"
        var status_buf: [80]u8 = undefined;
        const total = self.total_input_tokens + self.total_output_tokens;

        const status = if (total > 0) blk: {
            var token_buf: [32]u8 = undefined;
            const formatted = formatTokenCount(total, &token_buf);
            break :blk std.fmt.bufPrint(&status_buf, "Session: {s} | Tokens: {s}", .{ session_time, formatted }) catch "Session: ?";
        } else blk: {
            break :blk std.fmt.bufPrint(&status_buf, "Session: {s}", .{session_time}) catch "Session: ?";
        };

        // Draw at the right side of the status row
        const x = if (self.width > status.len) self.width - status.len - 1 else 0;
        try self.drawText(x, status_row, status, color_system);
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
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.renderLocked();
    }

    fn renderLocked(self: *TerminalUI) !void {
        if (!self.initialized) return;

        try self.renderOutputLocked();
        try self.renderTokenStatusLocked();
        try self.renderInputLineLocked();
        try tb.present();
    }

    /// Handle terminal resize
    pub fn handleResize(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized) return;
        self.width = @intCast(tb.width());
        self.height = @intCast(tb.height());
        self.scrollToBottom();
    }

    /// Add a character to input buffer (enforces max_input_chars limit)
    pub fn addInputChar(self: *TerminalUI, char: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.input_buffer.items.len >= max_input_chars) {
            return; // At limit, ignore additional input
        }
        try self.input_buffer.append(self.allocator, char);
        self.cursor_pos = self.input_buffer.items.len;
    }

    /// Delete last character from input buffer
    pub fn deleteInputChar(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.input_buffer.items.len > 0) {
            _ = self.input_buffer.pop();
            self.cursor_pos = self.input_buffer.items.len;
        }
    }

    /// Get and clear input buffer
    pub fn getAndClearInput(self: *TerminalUI) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const input = try self.allocator.dupe(u8, self.input_buffer.items);
        self.input_buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
        return input;
    }

    /// Clear input buffer without returning
    pub fn clearInput(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    /// Scroll up by one page
    pub fn scrollUp(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const page_size = self.getVisibleLineCount();
        if (self.scroll_offset >= page_size) {
            self.scroll_offset -= page_size;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Scroll down by one page
    pub fn scrollDown(self: *TerminalUI) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const page_size = self.getVisibleLineCount();
        const total_wrapped = self.countWrappedLines();
        const max_offset = if (total_wrapped > page_size) total_wrapped - page_size else 0;

        self.scroll_offset = @min(self.scroll_offset + page_size, max_offset);
    }

    /// Handle an agent update event - this is the callback for Agent
    pub fn handleAgentUpdate(update: agent_types.AgentUpdate, context: *anyopaque) void {
        const self: *TerminalUI = @ptrCast(@alignCast(context));

        // zlinter-disable no_swallow_error - UI event handling intentionally ignores errors to keep UI functional
        // This function acquires lock multiple times (addLine -> render)
        // Since std.Thread.Mutex is not recursive, we must be careful.
        // But here we're calling public methods that handle locking themselves.
        // As long as we don't hold the lock while calling them, it's fine.
        // We do NOT hold the lock here.

        switch (update) {
            .thought => |t| {
                self.addLine(t, .thinking) catch |err| {
                    logging.debugLog("addLine thought error: {any}", .{err});
                };
            },
            .thinking_state => |state| {
                self.mutex.lock();
                switch (state) {
                    .start => {
                        self.is_thinking = true;
                        self.thinking_start_ns = std.time.nanoTimestamp();
                        self.thinking_dots_phase = 0;
                        // Add initial thinking line and store its index
                        var buf: [64]u8 = undefined;
                        const text = self.getThinkingText(&buf);
                        self.addLineLocked(text, .thinking) catch |err| {
                            logging.debugLog("addLine thinking start error: {any}", .{err});
                        };
                        self.thinking_line_index = if (self.output_lines.items.len > 0)
                            self.output_lines.items.len - 1
                        else
                            null;
                    },
                    .stop => {
                        self.is_thinking = false;
                        self.thinking_line_index = null;
                    },
                }
                self.mutex.unlock();
            },
            .message_chunk => |chunk| {
                // For streaming, append to last assistant line
                // We need to peek at last line, so we need a lock-safe way to do this logic
                self.appendStreamingChunk(chunk) catch |err| {
                    logging.debugLog("appendStreamingChunk error: {any}", .{err});
                };
            },
            .tool_call => |tc| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[Tool: {s}]", .{tc.name}) catch "[Tool call]";
                self.addLine(msg, .tool_call) catch |err| {
                    logging.debugLog("addLine tool_call error: {any}", .{err});
                };
            },
            .tool_result => |tr| {
                const line_type: LineType = if (tr.success) .tool_result else .tool_error;
                // Truncate long results
                const max_len: usize = 200;
                if (tr.output.len > max_len) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "[Result: {s}...]", .{tr.output[0..max_len]}) catch "[Result]";
                    self.addLine(msg, line_type) catch |err| {
                        logging.debugLog("addLine tool_result error: {any}", .{err});
                    };
                } else {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "[Result: {s}]", .{tr.output}) catch "[Result]";
                    self.addLine(msg, line_type) catch |err| {
                        logging.debugLog("addLine tool_result error: {any}", .{err});
                    };
                }
            },
            .completion => {
                // Add blank line after completion for readability
                self.addLine("", .normal) catch |err| {
                    logging.debugLog("addLine completion error: {any}", .{err});
                };
            },
            .@"error" => |e| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: {s}", .{e}) catch "Error occurred";
                self.addLine(msg, .error_msg) catch |err| {
                    logging.debugLog("addLine error_msg error: {any}", .{err});
                };
            },
            .memory_warning => |mw| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Warning: Memory usage {d}KB (threshold: {d}KB)", .{ mw.rss_kb, mw.threshold_kb }) catch "Memory warning";
                self.addLine(msg, .warning) catch |err| {
                    logging.debugLog("addLine memory_warning error: {any}", .{err});
                };
            },
            .usage_update => |usage| {
                self.mutex.lock();
                self.total_input_tokens = usage.total_input_tokens;
                self.total_output_tokens = usage.total_output_tokens;
                self.mutex.unlock();
            },
        }

        // Re-render after update
        self.render() catch |err| {
            logging.debugLog("render error in handleAgentUpdate: {any}", .{err});
        };
        // zlinter-enable no_swallow_error
    }

    // Helper to handle streaming chunk appending logic safely
    fn appendStreamingChunk(self: *TerminalUI, chunk: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.output_lines.items.len > 0) {
            const last = self.output_lines.items[self.output_lines.items.len - 1];
            if (last.line_type == .assistant) {
                try self.appendToLastLineLocked(chunk);
                return;
            }
        }
        try self.addLineLocked(chunk, .assistant);
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
        // zlinter-disable no_swallow_error - UI confirmation flow intentionally ignores errors
        var buf: [1024]u8 = undefined;
        const suffix = std.fmt.bufPrint(&buf, " [Y/n] (Tool: {s}, Args: {s})", .{
            tool_name,
            arguments,
        }) catch "";

        const msg = std.fmt.bufPrint(&buf, "Execute tool? {s}", .{
            suffix,
        }) catch "Execute tool? [Y/n] ";

        // Add the confirmation line
        self.addLine(msg, .warning) catch |err| {
            logging.debugLog("addLine confirmation error: {any}", .{err});
        };
        self.render() catch |err| {
            logging.debugLog("render confirmation error: {any}", .{err});
        };

        // Signal main thread we are waiting
        self.confirmation_done.store(false, .release);
        self.waiting_for_confirmation.store(true, .release);

        // Wait for result
        while (!self.confirmation_done.load(.acquire)) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        const confirmed = self.confirmation_result.load(.acquire);

        if (confirmed) {
            self.addLine("[Confirmed]", .system) catch |err| {
                logging.debugLog("addLine confirmed error: {any}", .{err});
            };
        } else {
            self.addLine("[Cancelled]", .warning) catch |err| {
                logging.debugLog("addLine cancelled error: {any}", .{err});
            };
        }
        self.render() catch |err| {
            logging.debugLog("render confirmation result error: {any}", .{err});
        };

        return confirmed;
        // zlinter-enable no_swallow_error
    }
};

// Tests
test "terminal ui init and deinit" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    try std.testing.expect(!terminal_ui.initialized);
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.output_lines.items.len);
}

test "terminal ui add lines" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    try terminal_ui.addLine("Hello", .normal);
    try terminal_ui.addLine("World", .assistant);

    try std.testing.expectEqual(@as(usize, 2), terminal_ui.output_lines.items.len);
    try std.testing.expectEqualStrings("Hello", terminal_ui.output_lines.items[0].text);
    try std.testing.expectEqualStrings("World", terminal_ui.output_lines.items[1].text);
}

test "terminal ui append to last line" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    try terminal_ui.addLine("Hello", .assistant);
    try terminal_ui.appendToLastLine(" World");

    try std.testing.expectEqual(@as(usize, 1), terminal_ui.output_lines.items.len);
    try std.testing.expectEqualStrings("Hello World", terminal_ui.output_lines.items[0].text);
}

test "terminal ui input buffer" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    try terminal_ui.addInputChar('h');
    try terminal_ui.addInputChar('i');

    try std.testing.expectEqualStrings("hi", terminal_ui.input_buffer.items);

    terminal_ui.deleteInputChar();
    try std.testing.expectEqualStrings("h", terminal_ui.input_buffer.items);

    const input = try terminal_ui.getAndClearInput();
    defer allocator.free(input);

    try std.testing.expectEqualStrings("h", input);
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.input_buffer.items.len);
}

test "terminal ui line wrapping count" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 10; // Small width for testing

    // Empty line = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), terminal_ui.countLineWraps(""));

    // Short line = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), terminal_ui.countLineWraps("hello"));

    // Exactly width = 1 screen line
    try std.testing.expectEqual(@as(usize, 1), terminal_ui.countLineWraps("0123456789"));

    // Just over width = 2 screen lines
    try std.testing.expectEqual(@as(usize, 2), terminal_ui.countLineWraps("01234567890"));

    // Long line = 3 screen lines (output lines are NOT capped)
    try std.testing.expectEqual(@as(usize, 3), terminal_ui.countLineWraps("012345678901234567890123456789"));

    // Very long output line wraps fully (no cap on output)
    try std.testing.expectEqual(@as(usize, 7), terminal_ui.countLineWraps("0123456789012345678901234567890123456789012345678901234567890"));
}

test "terminal ui input character limit" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    // Add characters up to limit
    var i: usize = 0;
    while (i < TerminalUI.max_input_chars + 10) : (i += 1) {
        terminal_ui.addInputChar('x') catch {};
    }

    // Should be capped at max_input_chars
    try std.testing.expectEqual(TerminalUI.max_input_chars, terminal_ui.input_buffer.items.len);
}

test "formatTokenCount below 1000 returns raw number" {
    var buf: [32]u8 = undefined;

    // Test 0
    const result_0 = TerminalUI.formatTokenCount(0, &buf);
    try std.testing.expectEqualStrings("0", result_0);

    // Test 500
    const result_500 = TerminalUI.formatTokenCount(500, &buf);
    try std.testing.expectEqualStrings("500", result_500);

    // Test 999
    const result_999 = TerminalUI.formatTokenCount(999, &buf);
    try std.testing.expectEqualStrings("999", result_999);
}

test "formatTokenCount at 1000 boundary returns K format" {
    var buf: [32]u8 = undefined;

    const result = TerminalUI.formatTokenCount(1000, &buf);
    try std.testing.expectEqualStrings("1.0K", result);
}

test "formatTokenCount at 1000000 boundary returns M format" {
    var buf: [32]u8 = undefined;

    const result = TerminalUI.formatTokenCount(1000000, &buf);
    try std.testing.expectEqualStrings("1.0M", result);
}

test "scrollUp from zero offset stays at zero" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 80;
    terminal_ui.height = 24;

    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);

    // Attempt to scroll up from zero
    terminal_ui.scrollUp();

    // Should remain at zero (no underflow)
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);
}

test "scrollDown with no content stays at zero" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 80;
    terminal_ui.height = 24;

    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);

    // Scroll down with empty content
    terminal_ui.scrollDown();

    // Should remain at zero
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);
}

test "scrollToBottom with empty content sets offset to zero" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 80;
    terminal_ui.height = 24;

    // Set scroll offset to non-zero (simulating previous scroll)
    terminal_ui.scroll_offset = 10;

    // Call scrollToBottom with no content
    terminal_ui.scrollToBottom();

    // Should reset to 0
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);
}

test "scrollToBottom with content less than screen sets offset to zero" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 80;
    terminal_ui.height = 24;

    // Add a short line
    try terminal_ui.addLine("Hello", .normal);

    // Set scroll offset to non-zero
    terminal_ui.scroll_offset = 5;

    // Call scrollToBottom
    terminal_ui.scrollToBottom();

    // Should reset to 0 since content fits on screen
    try std.testing.expectEqual(@as(usize, 0), terminal_ui.scroll_offset);
}

test "splitTextIntoSegments empty string returns single empty segment" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 80;

    var segments = terminal_ui.splitTextIntoSegments("");
    defer segments.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqualStrings("", segments.items[0].text);
    try std.testing.expectEqual(false, segments.items[0].is_continuation);
}

test "splitTextIntoSegments text exactly at width boundary" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 10;

    // Create text exactly 10 characters (at width boundary)
    var segments = terminal_ui.splitTextIntoSegments("0123456789");
    defer segments.deinit(allocator);

    // Should have 1 segment with no wrapping
    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqualStrings("0123456789", segments.items[0].text);
    try std.testing.expectEqual(false, segments.items[0].is_continuation);
}

test "splitTextIntoSegments text one over width boundary" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 10;

    // Create text 11 characters (one over width)
    var segments = terminal_ui.splitTextIntoSegments("01234567890");
    defer segments.deinit(allocator);

    // Should have 2 segments due to wrapping
    try std.testing.expectEqual(@as(usize, 2), segments.items.len);
    try std.testing.expectEqualStrings("0123456789", segments.items[0].text);
    try std.testing.expectEqual(false, segments.items[0].is_continuation);
    try std.testing.expectEqualStrings("0", segments.items[1].text);
    try std.testing.expectEqual(true, segments.items[1].is_continuation);
}

test "countLineWraps with newlines at various positions" {
    const allocator = std.testing.allocator;
    var terminal_ui = TerminalUI.init(allocator);
    defer terminal_ui.deinit();

    terminal_ui.width = 10;

    // Newline at start
    try std.testing.expectEqual(@as(usize, 2), terminal_ui.countLineWraps("\nhello"));

    // Newline in middle
    try std.testing.expectEqual(@as(usize, 2), terminal_ui.countLineWraps("hello\nworld"));

    // Newline at end
    try std.testing.expectEqual(@as(usize, 2), terminal_ui.countLineWraps("hello\n"));
}

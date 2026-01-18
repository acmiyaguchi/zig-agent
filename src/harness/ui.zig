//! Manual test harness for Terminal UI.
//!
//! This test renders the TUI components (via termbox2) to verifying layout,
//! input handling, and rendering correctness without connecting to a real agent.

const std = @import("std");
const app = @import("app");
const terminal = app.ui.terminal;
const agent_types = app.agent.types;
const tb = app.ui.termbox;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize UI
    var ui = terminal.TerminalUI.init(allocator);
    defer ui.deinit();

    // Initialize termbox
    ui.initTermbox() catch |err| {
        std.debug.print("Failed to initialize termbox: {}\n", .{err});
        std.debug.print("This test requires a real terminal (try running via tmux)\n", .{});
        return;
    };

    // Add some initial output
    try ui.addLine("=== Termbox UI Test ===", .system);
    try ui.addLine("", .normal);
    try ui.addLine("This is a test of the terminal UI rendering.", .normal);
    try ui.addLine("Press keys to add input, Enter to submit, Ctrl+C to exit.", .system);
    try ui.addLine("", .normal);

    // Simulate some agent updates
    try ui.addLine("User: Hello, agent!", .user_input);
    try ui.addLine("", .normal);

    // Simulate streaming response
    try ui.addLine("Hello! I'm here to help. ", .assistant);
    try ui.appendToLastLine("How can I assist you today?");
    try ui.addLine("", .normal);

    // Simulate tool call
    try ui.addLine("[Tool: read_file]", .tool_call);
    try ui.addLine("[Result: File contents here...]", .tool_result);
    try ui.addLine("", .normal);

    // Simulate error
    try ui.addLine("Error: Something went wrong!", .error_msg);
    try ui.addLine("Warning: Memory usage high", .warning);
    try ui.addLine("", .normal);

    // Test long line wrapping (output lines wrap fully with scroll)
    try ui.addLine("This is a long assistant response that will wrap to multiple lines. The output area supports full scrolling so you can see all content. Try using arrow keys to scroll up/down through the conversation history.", .assistant);
    try ui.addLine("", .normal);
    try ui.addLine("Type a long message to test input wrapping (max 4 lines displayed, 2000 char limit).", .system);

    // Render initial state
    try ui.render();

    // Event loop
    var running = true;
    while (running) {
        var event: tb.TbEvent = undefined;
        tb.pollEvent(&event) catch {
            continue;
        };

        switch (event.type) {
            tb.TB_EVENT_KEY => {
                // Handle key events
                if (event.key == tb.TB_KEY_CTRL_C) {
                    running = false;
                } else if (event.key == tb.TB_KEY_ENTER) {
                    // Submit input
                    const input = ui.getAndClearInput() catch continue;
                    defer allocator.free(input);

                    if (input.len > 0) {
                        ui.addUserInput(input) catch {};

                        // Check for quit command
                        if (std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "exit")) {
                            running = false;
                        } else {
                            // Echo back as assistant response
                            var buf: [256]u8 = undefined;
                            const response = std.fmt.bufPrint(&buf, "You said: {s}", .{input}) catch "Response";
                            ui.addLine(response, .assistant) catch {};
                            ui.addLine("", .normal) catch {};
                        }
                    }
                    try ui.render();
                } else if (event.key == tb.TB_KEY_BACKSPACE or event.key == tb.TB_KEY_BACKSPACE2) {
                    ui.deleteInputChar();
                    try ui.render();
                } else if (event.key == tb.TB_KEY_ARROW_UP) {
                    ui.scrollUp();
                    try ui.render();
                } else if (event.key == tb.TB_KEY_ARROW_DOWN) {
                    ui.scrollDown();
                    try ui.render();
                } else if (event.ch != 0) {
                    // Regular character
                    const char: u8 = @truncate(event.ch);
                    if (char >= 32 and char < 127) {
                        ui.addInputChar(char) catch {};
                        try ui.render();
                    }
                }
            },
            tb.TB_EVENT_RESIZE => {
                ui.handleResize();
                try ui.render();
            },
            else => {},
        }
    }
}

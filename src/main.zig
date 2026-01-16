// Entry point - Event-driven REPL mode with libxev
const std = @import("std");
const api_types = @import("api/types.zig");
const agent_types = @import("agent/types.zig");
const client = @import("api/client.zig");
const registry = @import("tools/registry.zig");
const read_file = @import("tools/read_file.zig");
const agent_lib = @import("agent/agent.zig");
const xev = @import("xev");
const TerminalUI = @import("ui/terminal.zig").TerminalUI;
const tb = @import("ui/termbox.zig");

/// InteractiveMode encapsulates the libxev event loop and termbox input handling
const InteractiveMode = struct {
    allocator: std.mem.Allocator,
    ui: *TerminalUI,
    agent: *agent_lib.Agent,
    loop: xev.Loop,
    should_quit: bool,

    // Completion for TTY polling
    tty_completion: xev.Completion,

    pub fn init(allocator: std.mem.Allocator, ui: *TerminalUI, agent: *agent_lib.Agent) !InteractiveMode {
        return InteractiveMode{
            .allocator = allocator,
            .ui = ui,
            .agent = agent,
            .loop = try xev.Loop.init(.{}),
            .should_quit = false,
            .tty_completion = undefined,
        };
    }

    pub fn deinit(self: *InteractiveMode) void {
        self.loop.deinit();
    }

    pub fn run(self: *InteractiveMode) !void {
        // Get termbox TTY fd for input watching
        const fds = try tb.getFds();
        const tty_fd = fds[0];

        // Set up TTY file watcher
        var tty_file = xev.File{ .fd = tty_fd };
        tty_file.poll(&self.loop, &self.tty_completion, xev.PollEvent.read, InteractiveMode, self, onTtyReady);

        // Initial render
        try self.ui.render();

        // Run event loop
        try self.loop.run(.until_done);
    }

    fn onTtyReady(
        self_opt: ?*InteractiveMode,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;
        _ = result catch return .disarm;

        // Process any available termbox events
        var event: tb.TbEvent = undefined;
        while (tb.peekEvent(&event, 0) catch false) {
            if (event.type == tb.TB_EVENT_KEY) {
                self.handleKeyEvent(&event);
            } else if (event.type == tb.TB_EVENT_RESIZE) {
                self.ui.handleResize();
            }

            if (self.should_quit) {
                return .disarm;
            }
        }

        // Re-render after processing events
        self.ui.render() catch {};

        return if (self.should_quit) .disarm else .rearm;
    }

    fn handleKeyEvent(self: *InteractiveMode, event: *tb.TbEvent) void {
        if (event.key == tb.TB_KEY_CTRL_C) {
            self.should_quit = true;
            return;
        }

        if (event.key == tb.TB_KEY_ENTER) {
            // Get input and process it
            const input = self.ui.getAndClearInput() catch return;
            defer self.allocator.free(input);

            if (input.len == 0) return;

            // Check for exit commands
            if (std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "exit")) {
                self.should_quit = true;
                return;
            }

            // Add user input to display
            self.ui.addUserInput(input) catch {};

            // Execute agent turn (blocks but streams via callback)
            self.agent.executeTurn(input) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: {any}", .{err}) catch "Error";
                self.ui.addLine(msg, .error_msg) catch {};
            };

            return;
        }

        if (event.key == tb.TB_KEY_BACKSPACE or event.key == tb.TB_KEY_BACKSPACE2) {
            self.ui.deleteInputChar();
            return;
        }

        if (event.key == tb.TB_KEY_ARROW_UP) {
            self.ui.scrollUp();
            return;
        }

        if (event.key == tb.TB_KEY_ARROW_DOWN) {
            self.ui.scrollDown();
            return;
        }

        // Regular character input
        if (event.ch != 0 and event.ch < 128) {
            self.ui.addInputChar(@intCast(event.ch)) catch {};
        }
    }

};

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get environment variables
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    // Read OPENROUTER_API_KEY from environment
    const api_key = env_map.get("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OPENROUTER_API_KEY environment variable not set.\n", .{});
        std.process.exit(1);
    };

    // Initialize API client
    var api_client = try client.APIClient.init(allocator, api_key, "anthropic/claude-3.5-sonnet");
    defer api_client.deinit();

    // Initialize tool registry
    var tool_registry = registry.ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    // Register read_file tool
    const rf_tool = try read_file.initTool(tool_registry.arena.allocator());
    try tool_registry.register(rf_tool);

    // Initialize terminal UI
    var ui = TerminalUI.init(allocator);
    try ui.initTermbox();
    defer ui.deinit();

    // Initialize agent with terminal UI as event handler
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, TerminalUI.handleAgentUpdate, &ui);
    defer agent.deinit();

    // Initialize interactive mode with event loop
    var interactive_mode = try InteractiveMode.init(allocator, &ui, &agent);
    defer interactive_mode.deinit();

    // Run the event loop
    try interactive_mode.run();
}

test {
    _ = @import("api/client.zig");
    _ = @import("api/types.zig");
    _ = @import("agent/agent.zig");
    _ = @import("agent/types.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/read_file.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/termbox.zig");
}

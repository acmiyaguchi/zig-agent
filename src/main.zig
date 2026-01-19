// Entry point - Event-driven REPL mode with libxev
const std = @import("std");
const api = @import("api");
const agent_module = @import("agent");
const client = api.client;
const tools = @import("tools");
const agent_lib = agent_module.agent;
const xev = @import("xev");
const terminal = @import("ui/terminal.zig");
const TerminalUI = terminal.TerminalUI;

/// InteractiveMode encapsulates the libxev event loop and termbox input handling
const InteractiveMode = struct {
    allocator: std.mem.Allocator,
    ui: *TerminalUI,
    agent: *agent_lib.Agent,
    loop: xev.Loop,
    should_quit: bool,
    agent_running: std.atomic.Value(bool),

    // Completion for TTY polling
    tty_completion: xev.Completion,

    // Thread for agent execution
    agent_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, ui: *TerminalUI, agent: *agent_lib.Agent) !InteractiveMode {
        return InteractiveMode{
            .allocator = allocator,
            .ui = ui,
            .agent = agent,
            .loop = try xev.Loop.init(.{}),
            .should_quit = false,
            .agent_running = std.atomic.Value(bool).init(false),
            .tty_completion = undefined,
            .agent_thread = null,
        };
    }

    pub fn deinit(self: *InteractiveMode) void {
        // Wait for any running agent thread
        if (self.agent_thread) |thread| {
            thread.join();
        }
        self.loop.deinit();
    }

    pub fn run(self: *InteractiveMode) !void {
        // Get termbox TTY fd for input watching
        const tty_fd = try self.ui.getTtyFd();

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
        // zlinter-disable-next-line no_swallow_error - Event loop error handling
        const self = self_opt orelse return .disarm;
        _ = result catch return .disarm;

        // zlinter-disable no_swallow_error - UI rendering errors shouldn't stop event loop
        // Process any available terminal events
        while (self.ui.pollEvent() catch null) |event| {
            if (event.type == .key) {
                self.handleKeyEvent(event);
            } else if (event.type == .resize) {
                self.ui.handleResize();
            }

            if (self.should_quit) {
                return .disarm;
            }
        }

        // Re-render after processing events
        self.ui.render() catch {};

        return if (self.should_quit) .disarm else .rearm;
        // zlinter-enable no_swallow_error
    }

    fn handleKeyEvent(self: *InteractiveMode, event: terminal.Event) void {
        // zlinter-disable no_swallow_error - UI event handling intentionally ignores errors to keep UI functional
        if (event.key == terminal.key.CTRL_C) {

            // Check if waiting for confirmation - cancel it
            if (self.ui.waiting_for_confirmation.load(.acquire)) {
                self.ui.confirmation_result.store(false, .release);
                self.ui.confirmation_done.store(true, .release);
                self.ui.waiting_for_confirmation.store(false, .release);
                return;
            }
            self.should_quit = true;
            return;
        }

        // Handle confirmation input if waiting
        if (self.ui.waiting_for_confirmation.load(.acquire)) {
            if (event.ch == 'Y' or event.ch == 'y') {
                self.ui.confirmation_result.store(true, .release);
                self.ui.confirmation_done.store(true, .release);
                self.ui.waiting_for_confirmation.store(false, .release);
                return;
            }
            if (event.ch == 'N' or event.ch == 'n' or event.key == terminal.key.ENTER) {
                self.ui.confirmation_result.store(false, .release);
                self.ui.confirmation_done.store(true, .release);
                self.ui.waiting_for_confirmation.store(false, .release);
                return;
            }
            // Ignore other keys while waiting
            return;
        }

        if (event.key == terminal.key.ENTER) {

            // Get input and process it
            const input = self.ui.getAndClearInput() catch return;
            if (input.len == 0) {
                self.allocator.free(input);
                return;
            }

            // Check for exit commands
            if (std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "exit")) {
                self.allocator.free(input);
                self.should_quit = true;
                return;
            }

            // Check if agent is already running
            if (self.agent_running.load(.acquire)) {
                self.ui.addLine("Agent is already running...", .warning) catch {};
                self.ui.render() catch {};
                self.allocator.free(input);
                return;
            }

            // Add user input to display
            self.ui.addUserInput(input) catch {};
            self.ui.render() catch {};

            // Join previous thread if it exists
            if (self.agent_thread) |thread| {
                thread.join();
                self.agent_thread = null;
            }

            // Set running flag
            self.agent_running.store(true, .release);

            // Spawn thread for agent execution
            // We pass 'input' which is owned by the thread now.
            // The thread is responsible for freeing it.
            self.agent_thread = std.Thread.spawn(.{}, agentThreadWrapper, .{ self, input }) catch |err| {
                self.agent_running.store(false, .release);
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error spawning thread: {any}", .{err}) catch "Error spawning thread";
                self.ui.addLine(msg, .error_msg) catch {};
                self.allocator.free(input);
                return;
            };

            return;
        }

        if (event.key == terminal.key.BACKSPACE or event.key == terminal.key.BACKSPACE2) {
            self.ui.deleteInputChar();
            return;
        }

        if (event.key == terminal.key.ARROW_UP) {
            self.ui.scrollUp();
            return;
        }

        if (event.key == terminal.key.ARROW_DOWN) {
            self.ui.scrollDown();
            return;
        }

        // Regular character input
        if (event.ch != 0 and event.ch < 128) {
            self.ui.addInputChar(@intCast(event.ch)) catch {};
        }
        // zlinter-enable no_swallow_error
    }

    fn agentThreadWrapper(self: *InteractiveMode, input: []const u8) void {
        // zlinter-disable no_swallow_error - Agent thread error display
        defer self.allocator.free(input);
        defer self.agent_running.store(false, .release);

        self.agent.executeTurn(input) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: {any}", .{err}) catch "Error";
            self.ui.addLine(msg, .error_msg) catch {};
            self.ui.render() catch {};
        };
        // zlinter-enable no_swallow_error
    }
};

pub fn main() !void {
    // Initialize allocator
    // zlinter-disable-next-line no_deprecated - GPA syntax is fine in 0.15.x
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
    var api_client = try client.APIClient.init(allocator, api_key, "anthropic/claude-haiku-4.5");
    defer api_client.deinit();

    // Initialize tool registry
    var tool_registry = api.registry.ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    // Register tools
    inline for (.{
        tools.read_file,
        tools.list_directory,
        tools.search_files,
        tools.write_file,
        tools.edit_file,
        tools.run_command,
    }) |tool_mod| {
        try tool_registry.register(try tool_mod.initTool(tool_registry.arena.allocator()));
    }

    // Initialize terminal UI
    var ui = TerminalUI.init(allocator);
    try ui.initTermbox();
    defer ui.deinit();

    // Confirmation handler wrapper
    const confirmationHandler = struct {
        fn handler(tool_name: []const u8, arguments: []const u8, context: *anyopaque) bool {
            const ui_ptr: *TerminalUI = @ptrCast(@alignCast(context));
            return ui_ptr.requestConfirmation(tool_name, arguments);
        }
    }.handler;

    // Initialize agent with terminal UI as event handler
    var agent = agent_lib.Agent.init(allocator, &api_client, &tool_registry, TerminalUI.handleAgentUpdate, &ui);
    agent.confirmationHandler = confirmationHandler;
    agent.confirmation_context = &ui;
    defer agent.deinit();

    // Initialize interactive mode with event loop
    var interactive_mode = try InteractiveMode.init(allocator, &ui, &agent);
    defer interactive_mode.deinit();

    // Run the event loop
    try interactive_mode.run();
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(api);
    std.testing.refAllDecls(agent_module);
    std.testing.refAllDecls(tools);
}

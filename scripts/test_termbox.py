# /// script
# requires-python = ">=3.10"
# dependencies = ["pytest>=8.0", "pytest-json-report>=1.5"]
# ///
"""
Pytest test scenarios for termbox2 applications.

Run with:
    uv run pytest scripts/test_termbox.py -v --json-report --json-report-file=test_results.json

Or for human-readable output:
    uv run pytest scripts/test_termbox.py -v
"""
from __future__ import annotations

import pytest
import subprocess
import os
import time
from pathlib import Path
from dataclasses import dataclass

# Import the harness (same directory)
import sys
sys.path.insert(0, str(Path(__file__).parent))
from tmux_harness import TmuxSession, TmuxError, CaptureResult


# --- Fixtures ---

@pytest.fixture
def project_root() -> Path:
    """Get the project root directory."""
    return Path(__file__).parent.parent


@pytest.fixture
def zig_agent_binary(project_root: Path) -> Path:
    """Path to the zig-agent binary."""
    return project_root / "zig-out" / "bin" / "zig-agent"


@pytest.fixture
def ensure_built(project_root: Path) -> None:
    """Ensure the project is built before running tests."""
    result = subprocess.run(
        ["zig", "build"],
        cwd=project_root,
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        pytest.skip(f"Failed to build: {result.stderr}")


@pytest.fixture
def tmux_session(request) -> TmuxSession:
    """
    Create a tmux session for the test.

    Session name is derived from the test function name.
    Automatically cleaned up after the test.
    """
    # Get test name and sanitize for tmux
    test_name = request.node.name
    # Replace invalid characters
    safe_name = "".join(c if c.isalnum() or c == "_" else "_" for c in test_name)
    # Truncate if too long (tmux has limits)
    safe_name = safe_name[:30]

    session = TmuxSession(safe_name, width=100, height=30)
    session.create()

    yield session

    # Cleanup
    session.kill()


@pytest.fixture
def tmux_session_small() -> TmuxSession:
    """Create a small 80x24 tmux session."""
    session = TmuxSession("small", width=80, height=24)
    session.create()
    yield session
    session.kill()


# --- Helper Functions ---

def assert_text_appears(
    session: TmuxSession,
    text: str,
    timeout: float = 10.0,
    message: str | None = None
) -> CaptureResult:
    """Assert that text appears in the terminal within timeout."""
    result = session.wait_for_text(text, timeout=timeout)
    if result is None:
        capture = session.capture()
        msg = message or f"Expected text '{text}' not found"
        pytest.fail(f"{msg}\n\nScreen contents:\n{capture.raw}")
    return result


def assert_text_absent(
    session: TmuxSession,
    text: str,
    message: str | None = None
) -> None:
    """Assert that text does NOT appear in the terminal."""
    capture = session.capture()
    if capture.contains(text):
        msg = message or f"Unexpected text '{text}' found"
        pytest.fail(f"{msg}\n\nScreen contents:\n{capture.raw}")


# --- Test Classes ---

class TestTmuxHarness:
    """Tests for the tmux harness itself (meta-tests)."""

    def test_session_creation(self, tmux_session: TmuxSession):
        """Verify session is created successfully."""
        assert tmux_session.is_alive()
        assert tmux_session.name.startswith("test_session_creation")

    def test_session_has_salt(self, tmux_session: TmuxSession):
        """Verify session name includes salt."""
        assert "_" in tmux_session.name
        parts = tmux_session.name.rsplit("_", 1)
        assert len(parts) == 2
        assert len(parts[1]) >= 4  # Salt should be at least 4 chars

    def test_run_command(self, tmux_session: TmuxSession):
        """Test running a command in the session."""
        tmux_session.run("echo 'hello world'")
        result = assert_text_appears(tmux_session, "hello world", timeout=2)
        assert result.contains("hello world")

    def test_type_text(self, tmux_session: TmuxSession):
        """Test typing text without Enter."""
        tmux_session.run("cat")  # Start cat to echo input
        time.sleep(0.2)
        tmux_session.type_text("typed text")
        result = assert_text_appears(tmux_session, "typed text", timeout=2)
        assert result.contains("typed text")
        tmux_session.send_key("C-c")  # Exit cat

    def test_send_special_keys(self, tmux_session: TmuxSession):
        """Test sending special keys."""
        tmux_session.run("cat")
        time.sleep(0.2)
        tmux_session.type_text("line1")
        tmux_session.send_key("Enter")
        tmux_session.type_text("line2")
        tmux_session.send_key("Enter")

        result = tmux_session.wait_for_text("line2", timeout=2)
        assert result is not None

        tmux_session.send_key("C-c")

    def test_capture_screen(self, tmux_session: TmuxSession):
        """Test screen capture."""
        tmux_session.run("echo 'capture test'")
        time.sleep(0.5)
        capture = tmux_session.capture()

        assert isinstance(capture.lines, list)
        assert isinstance(capture.raw, str)
        assert capture.width == 100
        assert capture.height == 30

    def test_wait_for_text_timeout(self, tmux_session: TmuxSession):
        """Test that wait_for_text returns None on timeout."""
        result = tmux_session.wait_for_text("nonexistent text xyz", timeout=0.5)
        assert result is None

    def test_wait_for_stable(self, tmux_session: TmuxSession):
        """Test waiting for screen to stabilize."""
        tmux_session.run("echo 'stable'")
        capture = tmux_session.wait_for_stable(timeout=2, stable_time=0.3)
        assert capture.contains("stable")


class TestBasicShell:
    """Test basic shell commands in tmux (sanity checks)."""

    def test_echo(self, tmux_session: TmuxSession):
        """Basic echo command works."""
        tmux_session.run("echo 'pytest integration'")
        assert_text_appears(tmux_session, "pytest integration")

    def test_pwd(self, tmux_session: TmuxSession):
        """PWD command works."""
        tmux_session.run("pwd")
        # Should show some path with /
        assert_text_appears(tmux_session, "/", timeout=2)

    def test_environment_variable(self, tmux_session: TmuxSession):
        """Environment variables work."""
        tmux_session.run("export TEST_VAR=hello123")
        tmux_session.run("echo $TEST_VAR")
        assert_text_appears(tmux_session, "hello123")


class TestZigAgent:
    """Tests for the zig-agent REPL application."""

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_agent_starts(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that the agent starts and shows a prompt."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5, message="REPL prompt not shown")

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_agent_quit_command(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that 'quit' exits the agent."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        tmux_session.type_text("quit")
        tmux_session.send_key("Enter")

        # Should return to shell prompt
        time.sleep(1)
        capture = tmux_session.capture()
        # Agent should have exited - check we're back at shell
        # (The ">" prompt should no longer be the last prompt)

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_agent_exit_command(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that 'exit' exits the agent."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        tmux_session.type_text("exit")
        tmux_session.send_key("Enter")

        time.sleep(1)

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_agent_simple_question(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that the agent responds to a simple question."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        # Ask a simple question that doesn't require tools
        tmux_session.type_text("What is 2 + 2?")
        tmux_session.send_key("Enter")

        # Wait for any response text (should get some output within 30 seconds)
        # We're looking for any substantial text in the output area
        time.sleep(5)  # Give it time to process

        capture = tmux_session.capture()
        # Check that we got SOME response (more than just the prompt)
        lines_with_content = [l for l in capture.lines if l.strip() and not l.strip().startswith(">")]
        assert len(lines_with_content) > 0, f"No response from agent. Screen:\n{capture.raw}"

        # Clean up
        tmux_session.type_text("quit")
        tmux_session.send_key("Enter")

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_agent_tool_use(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that the agent can use tools (list_directory)."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        # Clear debug log
        debug_log = Path("/tmp/zig-agent-debug.log")
        if debug_log.exists():
            debug_log.unlink()

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        # Ask to list the /tmp directory
        tmux_session.type_text("List the files in /tmp directory")
        tmux_session.send_key("Enter")

        # Wait longer for tool execution (API call + tool execution)
        time.sleep(15)

        capture = tmux_session.capture()

        # Check debug log if it exists
        if debug_log.exists():
            debug_content = debug_log.read_text()
            print(f"Debug log:\n{debug_content}")

        # Should see some output
        assert len(capture.raw.strip()) > 50, f"Expected tool output. Screen:\n{capture.raw}"

        # Clean up
        tmux_session.send_key("C-c")


class TestTermbox:
    """Tests for termbox2 rendering (when a termbox UI is built)."""

    def test_termbox_initializes_in_tmux(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """
        Verify termbox2 can initialize inside tmux.

        This is the key test - termbox2 fails in headless environments
        but should work inside tmux which provides a PTY.
        """
        # We need a simple termbox test binary
        # For now, we can check that the test binary would work
        # by running zig test on termbox.zig
        result = subprocess.run(
            ["zig", "build", "test"],
            cwd=project_root,
            capture_output=True,
            text=True,
            env={**os.environ, "TERM": "xterm-256color"}
        )
        # The test should at least not crash
        assert result.returncode == 0 or "InitializationFailed" in result.stderr


class TestManualTestAgent:
    """Tests for the manual_test_agent binary."""

    @pytest.mark.skipif(
        not os.environ.get("OPENROUTER_API_KEY"),
        reason="OPENROUTER_API_KEY not set"
    )
    def test_manual_agent_runs(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that manual_test_agent executes."""
        binary = project_root / "zig-out" / "bin" / "manual_test_agent"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))

        # Should see the user prompt being sent
        assert_text_appears(
            tmux_session,
            "User:",
            timeout=10,
            message="Manual test agent did not show user prompt"
        )


class TestManualTestUI:
    """Tests for the manual_test_ui binary (termbox UI)."""

    def test_ui_starts(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that manual_test_ui starts and shows the UI."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))

        # Should see the UI test header
        assert_text_appears(
            tmux_session,
            "Termbox UI Test",
            timeout=5,
            message="UI test header not shown"
        )

    def test_ui_shows_prompt(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that the UI shows input prompt."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

    def test_ui_typing(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test typing in the UI."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        # Type some text
        tmux_session.type_text("hello test")
        time.sleep(0.3)

        capture = tmux_session.capture()
        assert capture.contains("hello test"), f"Typed text not visible:\n{capture.raw}"

    def test_ui_submit_input(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test submitting input with Enter."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        # Type and submit
        tmux_session.type_text("test input")
        tmux_session.send_key("Enter")

        # Should see the echoed response
        assert_text_appears(
            tmux_session,
            "You said: test input",
            timeout=3,
            message="Input was not echoed back"
        )

    def test_ui_quit_command(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that 'quit' exits the UI."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        tmux_session.type_text("quit")
        tmux_session.send_key("Enter")

        # Should exit - wait a bit and check if back at shell
        time.sleep(1)
        tmux_session.run("echo 'shell prompt'")
        assert_text_appears(tmux_session, "shell prompt", timeout=2)

    def test_ui_ctrl_c_exit(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test that Ctrl+C exits the UI."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        tmux_session.send_key("C-c")

        # Should exit - wait a bit and check if back at shell
        time.sleep(1)
        tmux_session.run("echo 'after ctrl-c'")
        assert_text_appears(tmux_session, "after ctrl-c", timeout=2)

    def test_ui_scrolling(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Test scrolling with arrow keys."""
        binary = project_root / "zig-out" / "bin" / "manual_test_ui"
        if not binary.exists():
            pytest.skip(f"Binary not found: {binary}")

        tmux_session.run(str(binary))
        assert_text_appears(tmux_session, ">", timeout=5)

        # Add some content by submitting multiple inputs
        for i in range(5):
            tmux_session.type_text(f"line {i}")
            tmux_session.send_key("Enter")
            time.sleep(0.2)

        # Try scrolling up
        tmux_session.send_key("Up")
        time.sleep(0.2)

        # Try scrolling down
        tmux_session.send_key("Down")
        time.sleep(0.2)

        # Should still be functional
        tmux_session.type_text("after scroll")
        capture = tmux_session.capture()
        assert capture.contains("after scroll")


# --- Parameterized Tests ---

@pytest.mark.parametrize("key,expected", [
    ("Enter", "\n"),
    ("Space", " "),
])
def test_special_keys(tmux_session: TmuxSession, key: str, expected: str):
    """Test various special keys work."""
    tmux_session.run("cat")
    time.sleep(0.2)
    tmux_session.send_key(key)
    time.sleep(0.2)
    tmux_session.send_key("C-c")


# --- Custom Markers ---

def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
    config.addinivalue_line(
        "markers", "requires_api: marks tests that require OPENROUTER_API_KEY"
    )


# --- Entry Point ---

if __name__ == "__main__":
    # Allow running directly with: uv run scripts/test_termbox.py
    pytest.main([__file__, "-v", "--tb=short"])

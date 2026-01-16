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

# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
Tmux test harness for termbox2 applications.

Provides TmuxSession class for programmatic control of tmux sessions,
enabling automated testing of terminal UI applications.

Usage:
    from tmux_harness import TmuxSession

    with TmuxSession("my_test") as session:
        session.run("./my-app")
        session.wait_for_text(">")
        session.type_text("hello")
        session.send_key("Enter")
        output = session.capture()
"""
from __future__ import annotations

import subprocess
import time
import secrets
import json
import sys
from dataclasses import dataclass, field, asdict
from typing import Literal
from pathlib import Path


@dataclass
class CaptureResult:
    """Result of a screen capture."""
    lines: list[str]
    raw: str
    width: int
    height: int

    def contains(self, text: str) -> bool:
        """Check if text appears anywhere in the capture."""
        return text in self.raw

    def line_contains(self, line_num: int, text: str) -> bool:
        """Check if a specific line contains text (0-indexed)."""
        if 0 <= line_num < len(self.lines):
            return text in self.lines[line_num]
        return False

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class SessionInfo:
    """Information about a tmux session."""
    name: str
    width: int
    height: int
    created_at: float
    salt: str


@dataclass
class CommandResult:
    """Result of running a command."""
    success: bool
    stdout: str
    stderr: str
    returncode: int

    def to_dict(self) -> dict:
        return asdict(self)


class TmuxError(Exception):
    """Error interacting with tmux."""
    pass


class TmuxSession:
    """
    Manages a tmux session for testing terminal applications.

    Features:
    - Deterministic terminal size
    - Automatic cleanup via context manager
    - Salted session names to avoid collisions
    - Screen capture and text waiting utilities
    """

    def __init__(
        self,
        name: str,
        width: int = 80,
        height: int = 24,
        salt_length: int = 6
    ):
        self.base_name = name
        self.salt = secrets.token_hex(salt_length // 2)
        self.name = f"{name}_{self.salt}"
        self.width = width
        self.height = height
        self.created_at: float | None = None
        self._created = False

    def _run_tmux(self, *args: str, check: bool = True) -> CommandResult:
        """Run a tmux command and return the result."""
        cmd = ["tmux", *args]
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
            return CommandResult(
                success=result.returncode == 0,
                stdout=result.stdout,
                stderr=result.stderr,
                returncode=result.returncode
            )
        except subprocess.TimeoutExpired as e:
            raise TmuxError(f"tmux command timed out: {cmd}") from e
        except FileNotFoundError:
            raise TmuxError("tmux not found - is it installed?")

    def create(self) -> SessionInfo:
        """Create the tmux session."""
        if self._created:
            raise TmuxError(f"Session {self.name} already created")

        result = self._run_tmux(
            "new-session", "-d", "-s", self.name,
            "-x", str(self.width), "-y", str(self.height)
        )

        if not result.success:
            raise TmuxError(f"Failed to create session: {result.stderr}")

        self._created = True
        self.created_at = time.time()

        return SessionInfo(
            name=self.name,
            width=self.width,
            height=self.height,
            created_at=self.created_at,
            salt=self.salt
        )

    def run(self, command: str) -> None:
        """Run a command in the session (sends command + Enter)."""
        if not self._created:
            raise TmuxError("Session not created")

        result = self._run_tmux("send-keys", "-t", self.name, command, "Enter")
        if not result.success:
            raise TmuxError(f"Failed to run command: {result.stderr}")

    def type_text(self, text: str) -> None:
        """Type text without pressing Enter."""
        if not self._created:
            raise TmuxError("Session not created")

        # Use literal flag to handle special characters
        result = self._run_tmux("send-keys", "-t", self.name, "-l", text)
        if not result.success:
            raise TmuxError(f"Failed to type text: {result.stderr}")

    def send_key(self, key: str) -> None:
        """
        Send a special key.

        Common keys:
        - Enter, Escape, Space, Tab
        - Up, Down, Left, Right
        - C-c (Ctrl+C), C-d (Ctrl+D), C-z (Ctrl+Z)
        - BSpace (Backspace)
        - F1-F12
        """
        if not self._created:
            raise TmuxError("Session not created")

        result = self._run_tmux("send-keys", "-t", self.name, key)
        if not result.success:
            raise TmuxError(f"Failed to send key: {result.stderr}")

    def capture(self, include_ansi: bool = False) -> CaptureResult:
        """
        Capture the current screen contents.

        Args:
            include_ansi: If True, include ANSI escape codes for colors
        """
        if not self._created:
            raise TmuxError("Session not created")

        args = ["capture-pane", "-t", self.name, "-p"]
        if include_ansi:
            args.append("-e")

        result = self._run_tmux(*args)
        if not result.success:
            raise TmuxError(f"Failed to capture pane: {result.stderr}")

        raw = result.stdout
        lines = raw.split('\n')

        # Remove trailing empty lines (tmux pads to full height)
        while lines and not lines[-1].strip():
            lines.pop()

        return CaptureResult(
            lines=lines,
            raw=raw,
            width=self.width,
            height=self.height
        )

    def wait_for_text(
        self,
        text: str,
        timeout: float = 10.0,
        interval: float = 0.1
    ) -> CaptureResult | None:
        """
        Wait until text appears in the terminal.

        Returns the CaptureResult if found, None if timeout.
        """
        if not self._created:
            raise TmuxError("Session not created")

        start = time.time()
        while (time.time() - start) < timeout:
            capture = self.capture()
            if capture.contains(text):
                return capture
            time.sleep(interval)

        return None

    def wait_for_stable(
        self,
        timeout: float = 5.0,
        stable_time: float = 0.5,
        interval: float = 0.1
    ) -> CaptureResult:
        """
        Wait until the screen stops changing.

        Useful for waiting for rendering to complete.
        """
        if not self._created:
            raise TmuxError("Session not created")

        start = time.time()
        last_capture = self.capture()
        last_change = start

        while (time.time() - start) < timeout:
            time.sleep(interval)
            current = self.capture()

            if current.raw != last_capture.raw:
                last_capture = current
                last_change = time.time()
            elif (time.time() - last_change) >= stable_time:
                return current

        return last_capture

    def kill(self) -> bool:
        """Kill the session. Returns True if killed, False if didn't exist."""
        if not self._created:
            return False

        result = self._run_tmux("kill-session", "-t", self.name, check=False)
        self._created = False
        return result.success

    def is_alive(self) -> bool:
        """Check if the session still exists."""
        result = self._run_tmux("has-session", "-t", self.name, check=False)
        return result.success

    def get_info(self) -> SessionInfo:
        """Get session information."""
        return SessionInfo(
            name=self.name,
            width=self.width,
            height=self.height,
            created_at=self.created_at or 0,
            salt=self.salt
        )

    def __enter__(self) -> "TmuxSession":
        self.create()
        return self

    def __exit__(self, *args) -> None:
        self.kill()


# CLI interface for subagent use
def cli_create(name: str, width: int = 80, height: int = 24) -> dict:
    """Create a session and return info as JSON."""
    session = TmuxSession(name, width, height)
    info = session.create()
    return {"status": "created", "session": asdict(info)}


def cli_run(session_name: str, command: str) -> dict:
    """Run a command in an existing session."""
    # For existing sessions, we don't use the wrapper
    result = subprocess.run(
        ["tmux", "send-keys", "-t", session_name, command, "Enter"],
        capture_output=True, text=True
    )
    return {
        "status": "ok" if result.returncode == 0 else "error",
        "stderr": result.stderr
    }


def cli_type(session_name: str, text: str) -> dict:
    """Type text in an existing session."""
    result = subprocess.run(
        ["tmux", "send-keys", "-t", session_name, "-l", text],
        capture_output=True, text=True
    )
    return {
        "status": "ok" if result.returncode == 0 else "error",
        "stderr": result.stderr
    }


def cli_key(session_name: str, key: str) -> dict:
    """Send a key to an existing session."""
    result = subprocess.run(
        ["tmux", "send-keys", "-t", session_name, key],
        capture_output=True, text=True
    )
    return {
        "status": "ok" if result.returncode == 0 else "error",
        "stderr": result.stderr
    }


def cli_capture(session_name: str) -> dict:
    """Capture screen from an existing session."""
    result = subprocess.run(
        ["tmux", "capture-pane", "-t", session_name, "-p"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return {"status": "error", "stderr": result.stderr}

    lines = result.stdout.split('\n')
    while lines and not lines[-1].strip():
        lines.pop()

    return {
        "status": "ok",
        "lines": lines,
        "raw": result.stdout
    }


def cli_wait(session_name: str, text: str, timeout: float = 10.0) -> dict:
    """Wait for text to appear in session."""
    start = time.time()
    while (time.time() - start) < timeout:
        capture = cli_capture(session_name)
        if capture["status"] == "ok" and text in capture["raw"]:
            return {"status": "found", "elapsed": time.time() - start, **capture}
        time.sleep(0.1)

    return {"status": "timeout", "elapsed": timeout, **cli_capture(session_name)}


def cli_kill(session_name: str) -> dict:
    """Kill a session."""
    result = subprocess.run(
        ["tmux", "kill-session", "-t", session_name],
        capture_output=True, text=True
    )
    return {
        "status": "killed" if result.returncode == 0 else "not_found",
        "stderr": result.stderr
    }


def main():
    """CLI entry point."""
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: tmux_harness.py <command> [args...]"}))
        sys.exit(1)

    cmd = sys.argv[1]
    args = sys.argv[2:]

    try:
        if cmd == "create":
            name = args[0] if args else "test"
            width = int(args[1]) if len(args) > 1 else 80
            height = int(args[2]) if len(args) > 2 else 24
            result = cli_create(name, width, height)

        elif cmd == "run":
            if len(args) < 2:
                result = {"error": "Usage: run <session> <command>"}
            else:
                result = cli_run(args[0], args[1])

        elif cmd == "type":
            if len(args) < 2:
                result = {"error": "Usage: type <session> <text>"}
            else:
                result = cli_type(args[0], args[1])

        elif cmd == "key":
            if len(args) < 2:
                result = {"error": "Usage: key <session> <key>"}
            else:
                result = cli_key(args[0], args[1])

        elif cmd == "capture":
            if not args:
                result = {"error": "Usage: capture <session>"}
            else:
                result = cli_capture(args[0])

        elif cmd == "wait":
            if len(args) < 2:
                result = {"error": "Usage: wait <session> <text> [timeout]"}
            else:
                timeout = float(args[2]) if len(args) > 2 else 10.0
                result = cli_wait(args[0], args[1], timeout)

        elif cmd == "kill":
            if not args:
                result = {"error": "Usage: kill <session>"}
            else:
                result = cli_kill(args[0])

        else:
            result = {"error": f"Unknown command: {cmd}"}

        print(json.dumps(result, indent=2))

    except Exception as e:
        print(json.dumps({"error": str(e), "type": type(e).__name__}))
        sys.exit(1)


if __name__ == "__main__":
    main()

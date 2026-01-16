---
name: Termbox Testing
description: Test termbox2 UI applications using tmux sessions. Use this skill when you need to test terminal UI apps that require a real PTY, run pytest-based UI tests, or interact with tmux sessions programmatically.
---

# Termbox Testing with Tmux

This skill runs termbox2 UI tests using tmux to provide a real PTY environment.
Termbox2 fails in headless environments but works inside tmux sessions.

## Quick Start - Run All Tests

```bash
cd /home/anthony/zig-agent
zig build && uv run --with pytest --with pytest-json-report pytest scripts/test_termbox.py -v --tb=short
```

## Quick Start - Machine-Readable Output

```bash
cd /home/anthony/zig-agent
uv run --with pytest --with pytest-json-report pytest scripts/test_termbox.py --json-report --json-report-file=test_results.json -q
cat test_results.json
```

---

## Step-by-Step Workflow

### Step 1: Build the Project

```bash
cd /home/anthony/zig-agent && zig build 2>&1
```

**If build fails**: Fix errors, rebuild. Do not proceed until build succeeds.

### Step 2: Run Pytest

```bash
uv run --with pytest --with pytest-json-report pytest scripts/test_termbox.py -v --tb=short 2>&1
```

**Output interpretation**:
- `PASSED` - Test succeeded
- `FAILED` - Test failed (see error message)
- `SKIPPED` - Test skipped (usually missing API key)
- `ERROR` - Test crashed before completing

### Step 3: For Specific Tests

Run a single test:
```bash
uv run --with pytest pytest scripts/test_termbox.py::TestTmuxHarness::test_session_creation -v
```

Run a test class:
```bash
uv run --with pytest pytest scripts/test_termbox.py::TestBasicShell -v
```

---

## Manual Tmux Testing (for debugging)

Use the CLI harness for interactive debugging:

### Create a session
```bash
uv run scripts/tmux_harness.py create mytest 80 24
```
Returns JSON: `{"status": "created", "session": {"name": "mytest_abc123", ...}}`

### Run a command
```bash
uv run scripts/tmux_harness.py run mytest_abc123 "./zig-out/bin/zig-agent"
```

### Type text (without Enter)
```bash
uv run scripts/tmux_harness.py type mytest_abc123 "hello world"
```

### Send special key
```bash
uv run scripts/tmux_harness.py key mytest_abc123 Enter
uv run scripts/tmux_harness.py key mytest_abc123 C-c
uv run scripts/tmux_harness.py key mytest_abc123 Up
```

### Capture screen
```bash
uv run scripts/tmux_harness.py capture mytest_abc123
```
Returns JSON with `lines` array and `raw` string.

### Wait for text
```bash
uv run scripts/tmux_harness.py wait mytest_abc123 ">" 10
```
Returns `{"status": "found", ...}` or `{"status": "timeout", ...}`

### Kill session
```bash
uv run scripts/tmux_harness.py kill mytest_abc123
```

---

## Common Special Keys

| Key | tmux name | Description |
|-----|-----------|-------------|
| Enter | `Enter` | Submit/newline |
| Escape | `Escape` | Escape key |
| Ctrl+C | `C-c` | Interrupt |
| Ctrl+D | `C-d` | EOF |
| Backspace | `BSpace` | Delete char |
| Arrow Up | `Up` | Navigate up |
| Arrow Down | `Down` | Navigate down |
| Arrow Left | `Left` | Move cursor left |
| Arrow Right | `Right` | Move cursor right |
| Tab | `Tab` | Tab key |
| Space | `Space` | Space key |

---

## Writing New Test Scenarios

Add tests to `scripts/test_termbox.py`:

```python
class TestMyFeature:
    def test_something(self, tmux_session: TmuxSession, ensure_built, project_root: Path):
        """Describe what this test verifies."""
        binary = project_root / "zig-out" / "bin" / "zig-agent"

        # Start the app
        tmux_session.run(str(binary))

        # Wait for prompt
        assert_text_appears(tmux_session, ">", timeout=5)

        # Interact
        tmux_session.type_text("my input")
        tmux_session.send_key("Enter")

        # Verify
        assert_text_appears(tmux_session, "expected output", timeout=10)
```

### Key Fixtures

| Fixture | Purpose |
|---------|---------|
| `tmux_session` | Fresh tmux session, auto-cleanup |
| `ensure_built` | Builds project before test |
| `project_root` | Path to project root |

### Key Helpers

| Helper | Purpose |
|--------|---------|
| `assert_text_appears(session, text, timeout)` | Fail if text doesn't appear |
| `assert_text_absent(session, text)` | Fail if text appears |
| `session.wait_for_stable()` | Wait for screen to stop changing |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "tmux not found" | Install tmux: `sudo apt install tmux` |
| Tests hang | Check for blocking `wait_for_text` with text that never appears |
| Session leak | Run `tmux kill-server` to clean up all sessions |
| "Binary not found" | Run `zig build` first |
| API tests skip | Set `OPENROUTER_API_KEY` environment variable |

### List active tmux sessions
```bash
tmux list-sessions
```

### Kill all tmux sessions
```bash
tmux kill-server
```

### Attach to session for debugging
```bash
tmux attach -t session_name
```
(Use `Ctrl+B D` to detach)

---

## JSON Output Format

When using `--json-report`:

```json
{
  "summary": {
    "total": 10,
    "passed": 8,
    "failed": 1,
    "skipped": 1
  },
  "tests": [
    {
      "nodeid": "scripts/test_termbox.py::TestTmuxHarness::test_session_creation",
      "outcome": "passed",
      "duration": 0.234
    }
  ]
}
```

---

## Workflow Summary

```
1. zig build                                                    # Build project
2. uv run --with pytest pytest scripts/test_termbox.py -v      # Run tests
3. (If fails) Fix code, goto 1
4. (If passes) Done!
```

**For machine-readable results**:
```bash
uv run --with pytest --with pytest-json-report pytest scripts/test_termbox.py --json-report --json-report-file=results.json -q && cat results.json
```

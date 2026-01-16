---
name: Zig Testing
description: Run zig build/test cycles and fix errors iteratively. Use this skill when you need to build Zig code, run Zig tests, fix compile errors, or write new Zig tests.
---

# Zig Testing Loop

You are running the Zig build and test cycle. Follow these steps EXACTLY.

## Step 1: Run Build First

```bash
zig build 2>&1
```

**If build succeeds** (no output or just warnings): Go to Step 2.

**If build fails**: Fix the errors shown, then re-run `zig build 2>&1`. Repeat until it passes.

## Step 2: Run Tests

```bash
zig build test 2>&1
```

**If tests pass** (shows only test output, no errors): You're done!

**If tests fail**: Read the error output, fix the failing test or code, then re-run `zig build test 2>&1`. Repeat until all tests pass.

---

## Common Zig Error Patterns and Fixes

### Compile Errors

| Error | Fix |
|-------|-----|
| `error: expected ',' after argument` | You have a trailing argument without comma - check function call syntax |
| `error: expected type 'X', found 'Y'` | Type mismatch - use `@as(X, value)` or `@intCast` for coercion |
| `error: cannot assign to constant` | Variable was declared `const`, use `var` if you need to mutate |
| `error: unused variable` | Either use `_ = variable;` to discard, or remove the variable |
| `error: undefined reference` | Missing import or the symbol is not public (`pub fn`) |

### Test-Specific Errors

| Error | Fix |
|-------|-----|
| `error.TestExpectedEqual` | Values don't match - check expected vs actual order |
| `error: memory leak detected` | Add missing `defer thing.deinit()` after allocation |
| `error: double free detected` | Remove duplicate `deinit()` call or check ownership |

### Type Coercion Fixes

```zig
// Integer literal to specific type
try std.testing.expectEqual(@as(i32, 5), myFunc());

// Compare optionals
try std.testing.expectEqual(@as(?i32, null), result);

// Compare slices/strings (use expectEqualStrings)
try std.testing.expectEqualStrings("expected", actual);
```

---

## Writing New Tests

Tests go at the **bottom** of the source file they test:

```zig
// === Production code above ===

test "descriptive name of what is tested" {
    const allocator = std.testing.allocator;  // Always use this - detects leaks

    // Setup
    var thing = try MyThing.init(allocator);
    defer thing.deinit();  // ALWAYS defer cleanup

    // Act
    const result = thing.doSomething();

    // Assert
    try std.testing.expectEqual(@as(ExpectedType, expected), result);
}
```

### Test Assertions Quick Reference

```zig
// Boolean check
try std.testing.expect(condition);

// Equality (order: expected, actual)
try std.testing.expectEqual(@as(i32, 5), getValue());

// String equality
try std.testing.expectEqualStrings("expected", actual);

// Error expected
try std.testing.expectError(error.InvalidInput, mightFail());

// Approximate equality for floats
try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.001);
```

---

## Test Discovery

Tests are discovered through imports in `src/main.zig`:

```zig
test {
    _ = @import("api/client.zig");
    _ = @import("api/types.zig");
    // Add new modules here
}
```

**If your new tests don't run**: Ensure the file is imported in `src/main.zig`'s test block.

---

## Project-Specific Commands

| Command | Purpose |
|---------|---------|
| `zig build` | Build the project |
| `zig build test` | Run all tests |
| `zig build run` | Build and run the app |
| `zig test src/path/file.zig` | Run tests for single file (may fail if file has dependencies) |

---

## Workflow Summary

```
1. zig build 2>&1        → Fix any compile errors
2. zig build test 2>&1   → Fix any test failures
3. Repeat until both pass
```

**IMPORTANT**: Always run `zig build` before `zig build test`. A failing build means tests won't run.

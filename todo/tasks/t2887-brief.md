# t2887 — Headless canary: detect wrong opencode binary, fail loud with long backoff

## Session Origin

Interactive (marcusquinn). Discovered while investigating awardsapp/awardsapp#3046, which showed alex-solovyev's runner posting `CLAIM_RELEASED reason=launch_recovery:no_worker_process` 468 times in 48h. The worker log tail showed `Canary test FAILED ... opencode=2.1.119 (Claude Code) ... error: unknown option '-m'`. anomalyco/opencode is at v1.14.x — the `2.1.119 (Claude Code)` version string is Anthropic's `claude` CLI (`@anthropic-ai/claude-code`). On alex's runner, `$OPENCODE_BIN_DEFAULT` is resolving to the wrong binary, the canary feeds it `-m` (an opencode flag claude doesn't accept), and every dispatch attempt fails identically. The current 90s negative-cache backoff (t2814 `CANARY_NEGATIVE_TTL_SECONDS=90`) means each issue accumulates ~40 dispatch-claim comment pairs per hour while the runner stays broken.

## What

In `.agents/scripts/headless-runtime-lib.sh`:

1. **`_validate_opencode_binary <bin>`** — new function. Runs `<bin> --version`, returns:
   - `0` if output matches `^[01]\.[0-9]+\.[0-9]+` AND does **not** contain `(Claude Code)` (real anomalyco/opencode signature).
   - `1` if output contains `(Claude Code)` or starts with `2-9` (Anthropic claude CLI signature).
   - `2` if binary is missing or `--version` returns nothing.

2. **`_find_alternative_opencode_binary`** — new function. Searches `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, `$HOME/.local/bin/opencode`, `$HOME/.opencode/bin/opencode`, `/snap/bin/opencode`. Echoes the first path that passes `_validate_opencode_binary`. Returns 0/1.

3. **Pre-canary validation in `_run_canary_test`** — call `_validate_opencode_binary "$OPENCODE_BIN_DEFAULT"` BEFORE the existing canary command. On failure:
   - Try `_find_alternative_opencode_binary`. If found, set a local `_effective_opencode_bin` to that path, export `OPENCODE_BIN` so worker dispatch picks it up too, and continue with the canary using the resolved binary.
   - If no alternative found, print a single clear error message identifying the wrong-binary case (`OPENCODE_BIN_DEFAULT='$bin' returns '$ver' — Anthropic claude CLI, not anomalyco/opencode. Install: 'npm install -g opencode-ai'`), stamp the negative cache with reason `config_error`, and return 1.

4. **Long backoff for `config_error`** — when reading the negative cache, check for an adjacent `${fail_cache_file}.reason` file. If contents are `config_error`, use `CANARY_CONFIG_ERROR_TTL_SECONDS` (default 3600 = 1h) instead of `CANARY_NEGATIVE_TTL_SECONDS` (90s). Successful canary clears both the cache and the reason file (existing behaviour clears the cache; extend to also `rm -f ${fail_cache_file}.reason`).

5. **Use `_effective_opencode_bin` (not `$OPENCODE_BIN_DEFAULT`) in the canary command** at line 944. `OPENCODE_BIN_DEFAULT` is `readonly`, so passing the resolved path through a local variable is the only safe option.

## Why

The current canary fail-fast (t2814) only addresses *transient* failures (auth blip, rate limit). It does **not** distinguish structural runner misconfiguration from API-side problems. When a runner has the wrong binary installed, every 90s the pulse:

1. Attempts dispatch on the next eligible issue
2. Posts `DISPATCH_CLAIM` comment
3. Posts `Dispatching worker` comment
4. Runs canary → fails on `unknown option '-m'`
5. Posts `CLAIM_RELEASED reason=launch_recovery:no_worker_process` comment with worker log tail

That's **3 spam comments per dispatch attempt × ~40 attempts/hour = ~120 noise comments per hour per runner**. Across 7 issues currently being hammered (#3058, #3076, #3077, #3078, #3081, #3082, #3093), this is destroying signal in the issue threads and burning GitHub API budget.

A 1h backoff for config errors reduces this to **~2-3 attempts/hour per issue** until the runner is fixed (manually or via a future aidevops update that ships a self-heal). The clear diagnostic message means when the runner-owner comes online and reads the worker log, they immediately know what to fix.

The path-fallback search self-heals the common case where opencode IS installed somewhere on the system but `OPENCODE_BIN` env var or PATH order is wrong.

## How

### Files Scope

- `.agents/scripts/headless-runtime-lib.sh`
- `todo/tasks/t2887-brief.md`

### Implementation

Model on the existing pattern in `_enforce_opencode_version_pin` (lines 817-840) for shape — small focused function that runs `--version`, inspects output, takes corrective action.

The new `_validate_opencode_binary`:

```bash
# Returns: 0=valid anomalyco/opencode, 1=wrong binary (claude CLI), 2=missing
_validate_opencode_binary() {
    local bin="${1:-}"
    [[ -n "$bin" ]] || return 2
    command -v "$bin" >/dev/null 2>&1 || return 2

    local version_output
    version_output=$("$bin" --version 2>/dev/null || echo "")

    # Anthropic claude CLI signature
    [[ "$version_output" == *"(Claude Code)"* ]] && return 1

    # opencode is at 1.x; anything 2.x+ is wrong (claude CLI is 2.1.x)
    [[ "$version_output" =~ ^[2-9][0-9]*\. ]] && return 1

    # Sanity check: must look like a semver
    [[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1

    return 0
}
```

The path search:

```bash
_find_alternative_opencode_binary() {
    local candidates=(
        "/opt/homebrew/bin/opencode"
        "/usr/local/bin/opencode"
        "${HOME}/.local/bin/opencode"
        "${HOME}/.opencode/bin/opencode"
        "/snap/bin/opencode"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]] && _validate_opencode_binary "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
```

Pre-canary integration goes immediately after the negative-cache check (line 873) and before the `canary_output=$(mktemp ...)` line (line 875).

### Verification

1. **Locally simulate alex's misconfig**:

   ```bash
   # In the worktree:
   OPENCODE_BIN=$(which claude) bash -c 'source .agents/scripts/headless-runtime-lib.sh; _validate_opencode_binary "$OPENCODE_BIN"; echo "exit=$?"'
   ```

   Expected: `exit=1`.

2. **Verify path fallback finds local opencode**:

   ```bash
   bash -c 'source .agents/scripts/headless-runtime-lib.sh; _find_alternative_opencode_binary'
   ```

   Expected: `/opt/homebrew/bin/opencode` (or wherever opencode is installed locally).

3. **Run a real canary and confirm it still passes**:

   ```bash
   bash -c 'source .agents/scripts/headless-runtime-lib.sh; _run_canary_test "anthropic/claude-sonnet-4-6" && echo PASS || echo FAIL'
   ```

   Expected: `PASS` (because local binary is valid opencode 1.14.x).

4. **Simulate alex's case and confirm structured failure + 1h cache**:

   ```bash
   OPENCODE_BIN=$(which claude) bash -c 'source .agents/scripts/headless-runtime-lib.sh; _run_canary_test || true; cat ~/.aidevops/state/canary-last-fail.reason 2>/dev/null'
   ```

   Expected: stderr shows the structured error message; `.reason` file contains `config_error`.

5. **ShellCheck clean**: `shellcheck .agents/scripts/headless-runtime-lib.sh` returns 0.

## Acceptance

- [x] `_validate_opencode_binary` distinguishes anomalyco/opencode from anthropic/claude via the `(Claude Code)` signature in `--version` output.
- [x] `_find_alternative_opencode_binary` searches 5 common installation paths and returns the first valid one.
- [x] `_run_canary_test` validates the binary before the canary command and uses the resolved alternative if the default is wrong.
- [x] Wrong-binary case writes `config_error` to a sibling reason file and triggers a 1h backoff (vs 90s for transient failures).
- [x] Local canary still passes on this machine (existing `opencode` is valid).
- [x] ShellCheck clean.
- [x] Bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`).

## Complexity Impact

`_run_canary_test` currently 142 lines (842-984). Adding pre-canary validation inline would push it past the 100-line function-complexity gate. **Mitigation**: the validation logic is fully contained in two new helper functions (`_validate_opencode_binary`, `_find_alternative_opencode_binary`) — the call site in `_run_canary_test` is a 6-8 line block. Net function size: ~150 lines (still over the gate, but unchanged from baseline; the gate is a ratchet on regressions, not absolute).

If the gate trips, apply `complexity-bump-ok` label with the justification block:

```
## Complexity Bump Justification

`_run_canary_test` already exceeds 100 lines pre-change (142 lines).
This PR adds 8 lines for pre-canary validation; net change: 142 → ~150.
Refactor to split is out of scope — would file as a follow-up task if needed.

base=142, head=150, new=8
```

## PR Conventions

`Resolves #21000` (leaf task — no parent-task chain).

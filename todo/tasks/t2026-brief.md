<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2026: setup.sh completion sentinel + verify-setup-log.sh harness

## Origin

- **Created:** 2026-04-13
- **Session:** opencode:feature/t2026-setup-completion-sentinel
- **Created by:** marcusquinn (ai-interactive) — proposed as a systemic detection layer after filing t2022
- **Parent task:** none (harness improvement, sibling to t2022)
- **Conversation context:** While fixing GH#18439 I ran `setup.sh --non-interactive` to deploy v3.7.3. The log tail ended at `init-routines-helper.sh: line 22: GREEN: readonly variable` and I dismissed it as a cosmetic warning. When the next user request asked me to file a task for it, the reproduction forced me to discover that setup.sh was silently terminating — skipping `setup_privacy_guard` and `setup_canonical_guard`. This brief is the *detection layer* (so the next silent termination can't hide); t2022 is the *fix layer* (so the current instance goes away).

## What

Ship a completion-verification primitive for `setup.sh` that makes silent early-termination immediately detectable by any caller — human or automated — without requiring log archaeology.

Three components:

1. **Completion sentinel** — a single stable, machine-readable marker line printed as the very last output of `setup.sh main()` before `return 0`. If setup.sh exits early for any reason (readonly collision, set -e propagation, killed by watchdog, crashed shell), the sentinel is absent.
2. **`verify-setup-log.sh` helper** — a new tiny script that reads a log file, greps for the sentinel, and either exits clean or prints the last 15 lines of the log with a clear "setup.sh did not reach completion" banner. Works standalone.
3. **Auto-update wiring** — `auto-update-helper.sh:1341` already catches setup.sh non-zero exits. Extend it to also flag "exit 0 but no sentinel" anomalies (setup.sh silently succeeding without reaching the end) and, on any setup failure, emit the last-15-lines forensic tail so the operator doesn't have to hunt through `$LOG_FILE` to find the termination point.

## Why

The t2022 bug had been producing `init-routines-helper.sh: line 22: GREEN: readonly variable` on every `setup.sh --non-interactive` run for an unknown number of weeks. I dismissed it as cosmetic every time I saw it — including the same session where I was actively debugging setup.sh output. The reclassification from "cosmetic" to "P1 silent termination of security-critical hook installation" only happened when an unrelated request forced a reproduction.

**The failure mode is not "setup.sh crashes loudly". It's "setup.sh prints 240 lines of green success markers and one red warning, then exits".** The green markers dominate the signal; the warning looks like the known background noise from other helpers. Unless a caller explicitly verifies "did you run to the end", this failure mode is effectively invisible.

A completion sentinel changes the contract: instead of "trust the exit code" (which can be wrong if `set -e` semantics interact badly, or if a subshell swallows the failure) or "trust the last line looks OK" (which is what we have now and it's demonstrably unreliable), we have a **positive assertion** that the script ran through `return 0` in `main()`. Either the sentinel is in the log or setup.sh didn't finish. No interpretation needed.

### Evidence: current state is unreliable

From this session's probe (`bash setup.sh --non-interactive` on the t2022-affected branch, 270 seconds to termination):

```
[INFO] Setting up routines repo...
/Users/marcusquinn/Git/.../init-routines-helper.sh: line 22: GREEN: readonly variable
# (exit 1)
```

Counts:
- `GREEN: readonly` occurrences: 1 ← the only signal of failure
- `Setup complete!` occurrences: 0 ← never reached
- Total log lines: 240+

The `Setup complete!` line at `setup.sh:1043` IS accidentally a completion marker — but it lives inside `_setup_post_setup_steps`, so (a) it's buried among other SUCCESS lines, (b) nothing verifies it, and (c) it's not designed as a sentinel so its wording/location can drift without anyone noticing.

### Scope adjustment from original proposal

The original plan named `version-manager.sh release` as the wiring target. Investigation showed `version-manager.sh` does NOT call `setup.sh --non-interactive` — the post-release sync path calls `deploy-agents-on-merge.sh` instead, and the actual setup.sh run is a separate user step. The real automated caller is `.agents/scripts/auto-update-helper.sh:1341` in the timer-driven update flow. This is where the wiring goes. Rationale documented in PR body.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** — no, 4 files (setup.sh + new verify-setup-log.sh + auto-update-helper.sh + new test)
- [x] **Complete code blocks for every edit?** — yes, exact oldString/newString
- [x] **No judgment or design decisions?** — sentinel format and grep pattern specified
- [x] **No error handling or fallback logic to design?** — verify-setup-log.sh's error output format is specified verbatim
- [x] **Estimate 1h or less?** — 30 min
- [x] **4 or fewer acceptance criteria?** — 4 below

**Selected tier:** `tier:standard`

**Tier rationale:** Fails the `tier:simple` file-count check (4 files, including a new helper script and a new test). No single edit is complex and there's no design judgment needed, but the multi-file coordination and the new helper script warrant standard tier. Sonnet should handle it without escalation; the brief has enough detail that Haiku could also execute it if cascaded.

## How (Approach)

### Files to Modify

- `EDIT: setup.sh:1126-1159` — add `print_setup_complete_sentinel()` function and call it at the end of `main()`
- `NEW: .agents/scripts/verify-setup-log.sh` — 60-line helper that checks a log for the sentinel and prints forensic tail on failure
- `EDIT: .agents/scripts/auto-update-helper.sh:1339-1365` — after the existing exit-code check, call `verify-setup-log.sh` on the update log; log a separate error if sentinel absent (whether exit was 0 or 1)
- `NEW: tests/test-setup-completion-sentinel.sh` — unit test that verifies the sentinel function exists, is called exactly once from `main()`, and is the last statement before `return 0`

### Implementation Steps

1. **setup.sh: add the sentinel function and call.**

   At `setup.sh:1126` (just before `main()`), add:

   ```bash
   # Print the completion sentinel. This is the canonical "setup.sh finished
   # all phases" marker — any caller that needs to detect silent early-
   # termination (e.g., t2022-class bugs where a sourced helper's set -e
   # propagates a readonly assignment failure to the parent) should grep log
   # output for the literal "[SETUP_COMPLETE]" prefix.
   #
   # Format is intentionally stable and parseable. Do NOT add human-readable
   # decoration or move this function without updating verify-setup-log.sh
   # and tests/test-setup-completion-sentinel.sh.
   print_setup_complete_sentinel() {
   	local _version="${VERSION:-unknown}"
   	local _mode="non-interactive"
   	[[ "${NON_INTERACTIVE:-false}" != "true" ]] && _mode="interactive"
   	printf '[SETUP_COMPLETE] aidevops setup.sh v%s finished all phases (mode=%s)\n' \
   		"$_version" "$_mode"
   	return 0
   }
   ```

   Then in `main()` (currently ends at line 1158), change the final section from:

   ```bash
   	_setup_post_setup_steps "$_os"

   	return 0
   }
   ```

   to:

   ```bash
   	_setup_post_setup_steps "$_os"

   	# GH#18492 / t2026: completion sentinel. Must be the last output of a
   	# successful run — any silent early-termination will leave this
   	# absent from the log. Verified by verify-setup-log.sh.
   	print_setup_complete_sentinel

   	return 0
   }
   ```

2. **Create `.agents/scripts/verify-setup-log.sh`.**

   Full file content (60 lines including SPDX header and usage help):

   ```bash
   #!/usr/bin/env bash
   # SPDX-License-Identifier: MIT
   # SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
   #
   # verify-setup-log.sh — verify that a captured setup.sh log reached the
   # completion sentinel (GH#18492 / t2026).
   #
   # Exit codes:
   #   0 — sentinel present, setup.sh ran to completion
   #   1 — sentinel absent, setup.sh terminated early (prints last 15 log lines)
   #   2 — usage error (bad args, unreadable log)
   #
   # Usage:
   #   verify-setup-log.sh <log-file>
   #   verify-setup-log.sh --help
   #
   # Intended callers: auto-update-helper.sh, CI workflows, local release
   # verification scripts. The sentinel format is '[SETUP_COMPLETE] aidevops
   # setup.sh ...' — see setup.sh:print_setup_complete_sentinel.

   set -Eeuo pipefail

   _SENTINEL_PREFIX='[SETUP_COMPLETE] aidevops setup.sh'
   _TAIL_LINES=15

   _print_usage() {
   	cat <<'EOF'
   verify-setup-log.sh — verify setup.sh log completion sentinel

   Usage:
     verify-setup-log.sh <log-file>

   Exits 0 if the log contains the [SETUP_COMPLETE] sentinel.
   Exits 1 with the last 15 lines printed if the sentinel is absent.
   EOF
   	return 0
   }

   main() {
   	local log_file="${1:-}"

   	if [[ -z "$log_file" ]] || [[ "$log_file" == "--help" ]] || [[ "$log_file" == "-h" ]]; then
   		_print_usage
   		[[ -z "$log_file" ]] && return 2
   		return 0
   	fi

   	if [[ ! -r "$log_file" ]]; then
   		printf 'verify-setup-log.sh: ERROR: cannot read log file: %s\n' "$log_file" >&2
   		return 2
   	fi

   	if grep -Fq "$_SENTINEL_PREFIX" "$log_file"; then
   		return 0
   	fi

   	printf 'verify-setup-log.sh: FAIL: setup.sh did not reach completion sentinel in %s\n' "$log_file" >&2
   	printf 'Last %d lines of log (termination point):\n' "$_TAIL_LINES" >&2
   	printf -- '---\n' >&2
   	tail -n "$_TAIL_LINES" "$log_file" >&2
   	printf -- '---\n' >&2
   	return 1
   }

   main "$@"
   ```

3. **Wire into `auto-update-helper.sh`.**

   At `auto-update-helper.sh:1341-1345`, replace:

   ```bash
   	if ! bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1; then
   		log_error "setup.sh failed (exit code: $?)"
   		update_state "update" "$remote" "setup_failed"
   		return 1
   	fi
   ```

   with:

   ```bash
   	local _setup_exit=0
   	bash "$INSTALL_DIR/setup.sh" --non-interactive >>"$LOG_FILE" 2>&1 || _setup_exit=$?

   	# GH#18492 / t2026: verify the completion sentinel regardless of exit
   	# code. "exit 0 but no sentinel" would indicate a subshell swallowed a
   	# failure (rare but possible). "exit non-zero AND no sentinel" is the
   	# t2022-class silent termination.
   	local _sentinel_ok=0
   	if [[ -x "$INSTALL_DIR/.agents/scripts/verify-setup-log.sh" ]]; then
   		bash "$INSTALL_DIR/.agents/scripts/verify-setup-log.sh" "$LOG_FILE" 2>>"$LOG_FILE" || _sentinel_ok=$?
   	fi

   	if [[ "$_setup_exit" -ne 0 ]]; then
   		log_error "setup.sh failed (exit code: $_setup_exit)"
   		if [[ "$_sentinel_ok" -ne 0 ]]; then
   			log_error "setup.sh did not reach completion sentinel — see forensic tail in $LOG_FILE"
   		fi
   		update_state "update" "$remote" "setup_failed"
   		return 1
   	fi

   	if [[ "$_sentinel_ok" -ne 0 ]]; then
   		log_error "setup.sh exited 0 but did not reach completion sentinel — silent termination, see $LOG_FILE"
   		update_state "update" "$remote" "setup_sentinel_missing"
   		return 1
   	fi
   ```

4. **Create `tests/test-setup-completion-sentinel.sh`.**

   ```bash
   #!/usr/bin/env bash
   # SPDX-License-Identifier: MIT
   # SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
   #
   # test-setup-completion-sentinel.sh — regression guard for GH#18492 / t2026
   #
   # Ensures setup.sh:
   #   (1) defines print_setup_complete_sentinel
   #   (2) calls it exactly once from main()
   #   (3) the sentinel line format matches what verify-setup-log.sh greps for

   set -Eeuo pipefail
   IFS=$'\n\t'

   REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
   SETUP_SH="${REPO_ROOT}/setup.sh"
   VERIFIER="${REPO_ROOT}/.agents/scripts/verify-setup-log.sh"

   [[ -f "$SETUP_SH" ]] || { echo "setup.sh not found at $SETUP_SH"; exit 1; }
   [[ -x "$VERIFIER" ]] || { echo "verify-setup-log.sh not executable at $VERIFIER"; exit 1; }

   # 1. Function is defined
   if ! grep -q '^print_setup_complete_sentinel()' "$SETUP_SH"; then
   	echo "FAIL: print_setup_complete_sentinel function not defined in setup.sh" >&2
   	exit 1
   fi
   printf 'PASS %s\n' "print_setup_complete_sentinel function defined"

   # 2. Called exactly once
   local_count=$(grep -cE '^\s*print_setup_complete_sentinel\s*$' "$SETUP_SH" || true)
   if [[ "$local_count" != "1" ]]; then
   	echo "FAIL: print_setup_complete_sentinel called $local_count times, expected 1" >&2
   	exit 1
   fi
   printf 'PASS %s\n' "print_setup_complete_sentinel called exactly once"

   # 3. Sentinel format matches verifier prefix (tests the contract end-to-end)
   _expected_prefix='[SETUP_COMPLETE] aidevops setup.sh'
   if ! grep -Fq "$_expected_prefix" "$SETUP_SH"; then
   	echo "FAIL: sentinel format does not contain '$_expected_prefix'" >&2
   	exit 1
   fi
   printf 'PASS %s\n' "sentinel format matches verifier contract"

   # 4. End-to-end: synthesise a minimal log with and without the sentinel,
   # verify the verifier gives the right answer on each.
   TMP_DIR=$(mktemp -d)
   trap 'rm -rf "$TMP_DIR"' EXIT

   printf '%s\n' "$_expected_prefix v3.7.3 finished all phases (mode=non-interactive)" >"$TMP_DIR/good.log"
   if ! bash "$VERIFIER" "$TMP_DIR/good.log" >/dev/null 2>&1; then
   	echo "FAIL: verify-setup-log.sh rejected a valid log containing sentinel" >&2
   	exit 1
   fi
   printf 'PASS %s\n' "verify-setup-log.sh accepts valid sentinel log"

   printf 'line one\nline two\n[ERROR] something failed\n' >"$TMP_DIR/bad.log"
   if bash "$VERIFIER" "$TMP_DIR/bad.log" >/dev/null 2>&1; then
   	echo "FAIL: verify-setup-log.sh accepted a log missing the sentinel" >&2
   	exit 1
   fi
   printf 'PASS %s\n' "verify-setup-log.sh rejects log missing sentinel"

   echo "All t2026 sentinel regression tests passed"
   ```

### Verification

```bash
# 1. Tests pass (new + existing)
bash tests/test-setup-completion-sentinel.sh
# 4 PASS lines + "All t2026 sentinel regression tests passed"

# 2. Shellcheck clean on all modified/new files
shellcheck setup.sh \
           .agents/scripts/verify-setup-log.sh \
           .agents/scripts/auto-update-helper.sh \
           tests/test-setup-completion-sentinel.sh

# 3. End-to-end: run setup.sh on a clean machine, verify the sentinel line
# appears as the last non-whitespace line of output.
bash setup.sh --non-interactive 2>&1 | tail -1 | grep -Fq '[SETUP_COMPLETE]'

# 4. Negative test: confirm the verifier catches the t2022 bug if we source
# init-routines-helper.sh into a parent shell that already has GREEN readonly.
# (This is the real-world failure case that motivated this task.)
cat > /tmp/t2026-neg.log <<'EOF'
[INFO] Setting up routines repo...
/Users/.../init-routines-helper.sh: line 22: GREEN: readonly variable
EOF
bash .agents/scripts/verify-setup-log.sh /tmp/t2026-neg.log && echo "FAIL: should have rejected" || echo "PASS: verifier caught silent termination"
rm /tmp/t2026-neg.log
```

## Acceptance Criteria

- [ ] `tests/test-setup-completion-sentinel.sh` exits 0 with all 4 PASS lines.
  ```yaml
  verify:
    method: bash
    run: "bash ~/Git/aidevops/tests/test-setup-completion-sentinel.sh"
  ```
- [ ] `setup.sh` on a clean run prints `[SETUP_COMPLETE] aidevops setup.sh ...` as its final output line.
  ```yaml
  verify:
    method: bash
    run: "bash ~/Git/aidevops/setup.sh --non-interactive 2>&1 | tail -1 | grep -Fq '[SETUP_COMPLETE]'"
  ```
- [ ] `verify-setup-log.sh` correctly rejects a log missing the sentinel and prints the last 15 lines to stderr.
  ```yaml
  verify:
    method: bash
    run: "printf 'line one\\nline two\\nerror\\n' > /tmp/t2026-v.log; ! bash ~/Git/aidevops/.agents/scripts/verify-setup-log.sh /tmp/t2026-v.log 2>/dev/null"
  ```
- [ ] `auto-update-helper.sh` calls `verify-setup-log.sh` after `bash setup.sh --non-interactive` in the update flow.
  ```yaml
  verify:
    method: codebase
    pattern: "verify-setup-log\\.sh"
    path: ".agents/scripts/auto-update-helper.sh"
  ```

## Context & Decisions

- **Why sentinel over exit code alone**: `set -e` semantics interact weirdly with sourced scripts. Subshells can swallow failures. The t2022 reproduction showed `exit=1` locally BUT the parent setup.sh continued to subsequent commands in some shells. A positive completion marker is the only reliable "I finished" signal.
- **Why the sentinel format includes `[SETUP_COMPLETE]` prefix**: greppable as a literal string (no regex escaping), visually distinct from `[INFO]`/`[SUCCESS]`/`[ERROR]` prefixes, and unique enough that false positives are impossible.
- **Why auto-update-helper.sh wiring instead of the originally-proposed version-manager.sh**: investigation during this task showed `version-manager.sh release` does NOT call setup.sh. The actual automated caller is `auto-update-helper.sh:1341`, which runs every ~10 minutes via timer. Scope adjustment documented in PR body.
- **Why a separate helper script instead of inlining the check**: the verifier is also useful to human operators for post-hoc log analysis ("did yesterday's auto-update actually finish?"), to CI workflows, and to future callers that aren't the auto-update path. A single-purpose tool beats a scattered one-liner.
- **Explicit non-goals**:
  - Do NOT fix the underlying t2022 bug — that's queued separately. After this harness lands but before t2022 ships, the next `aidevops update` cycle will loudly log "setup.sh did not reach completion sentinel" proving the harness works. That's the intended demonstration.
  - Do NOT audit other scripts for similar silent-termination modes — separate follow-up.
  - Do NOT wire the verifier into CI workflows — `auto-update-helper.sh` is the minimal wiring; CI can adopt later. This PR's scope is strictly "primitive + one real caller".
  - Do NOT change `_setup_post_setup_steps`'s existing `"Setup complete!"` message — leave it as-is; the sentinel is an additional signal, not a replacement.

## Relevant Files

- `setup.sh:6` — `set -Eeuo pipefail` (the cause of inherited errexit that makes silent-termination bugs fatal)
- `setup.sh:1043` — existing `"Setup complete!"` line, buried inside `_setup_post_setup_steps`
- `setup.sh:1126-1159` — `main()` function where the sentinel call goes
- `.agents/scripts/auto-update-helper.sh:1341-1365` — existing setup.sh caller with exit-code check
- `.agents/scripts/auto-update-helper.sh:1347-1358` — existing secondary verification (VERSION file check from GH#3980 precedent — similar "exit 0 but failed" defense pattern)
- `tests/test-pulse-systemd-timeout.sh` — style reference for shell-script unit tests

## Dependencies

- **Blocked by:** none
- **Blocks:** would be an ideal gate for merging t2022 (so the fix lands on a system that can prove it worked), but not a hard blocker — t2022 can ship first and this follows.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | setup.sh main() + auto-update-helper.sh caller + existing test style |
| Implementation | 15m | sentinel function + verifier helper + auto-update wiring + test |
| Testing | 10m | shellcheck all 4 files, run new test, run full setup.sh to confirm sentinel prints |
| **Total** | **30m** | |

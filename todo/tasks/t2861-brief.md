<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2861: gh PATH shim mutates user --body-file source on disk instead of using a temp copy

## Pre-flight

- [x] Memory recall: "gh shim signature footer body-file" — 2 prior lessons confirm the shim has known parsing/race issues; this is a separate class
- [x] Discovery pass: no in-flight PRs touching `.agents/scripts/gh` in last 48h
- [x] File refs verified: `.agents/scripts/gh:327-335` checked at HEAD
- [x] Tier: `tier:standard` — single function modification with clear pattern, but `gh` shim affects every framework `gh` invocation

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (surfaced during t2840 child-issue filing)
- **Parent task:** none (independent bug)
- **Conversation context:** During t2840 decomposition, called `gh issue create --body-file todo/tasks/tNNN-brief.md` 16 times. After each call, the brief file on disk had been silently appended with a signature footer. The user-authored brief is the source of truth for the worker's implementation context — mutating it on every issue-creation call corrupts that source.

## What

The `gh` PATH shim must NOT modify the user's `--body-file` source on disk. When auto-injecting a signature footer, the shim must write the augmented body to a fresh temporary file and pass that temp path to the real `gh` binary, then clean up the temp file. The user's source file stays byte-identical before and after the call.

After the fix:

- `gh issue create --body-file todo/tasks/tNNN-brief.md` does NOT modify `tNNN-brief.md`.
- A signature footer is still appended to the issue body that GitHub receives (functional contract preserved).
- Re-running the same command produces the same GitHub-side result without piling up signature blocks in the source file.

## Why

The current implementation at `.agents/scripts/gh:327-335` opens the user's source file in append mode and writes the signature footer directly into it:

```bash
if [[ $_body_file_idx -ge 0 && -n "$_body_file_val" && -f "$_body_file_val" ]]; then
    if ! grep -q "<!-- aidevops:sig -->" "$_body_file_val" 2>/dev/null; then
        _file_content=$(<"$_body_file_val") || _file_content=""
        _sig_footer=$("$SIG_HELPER" footer --body "$_file_content" 2>/dev/null || echo "")
        if [[ -n "$_sig_footer" ]]; then
            printf '%s' "$_sig_footer" >>"$_body_file_val" || true
        fi
    fi
fi
```

This is a correctness bug for several reasons:

1. **Source-file mutation surprise.** A `gh issue create --body-file <foo>` call has the contractual semantics of "read foo, send to GitHub". The shim's append violates this contract — the file is also written to. Users editing the brief in their editor can lose changes if the file is open at the time (depending on editor behaviour around external modification).

2. **Signature pollution in version-controlled files.** Briefs at `todo/tasks/tNNN-brief.md` are committed. After a single `gh issue create` against a brief, the brief now has a signature footer that becomes part of the audit trail forever. The signature was meant for the issue body (machine-readable provenance for the GitHub surface), not the source brief.

3. **Idempotency illusion.** The current code guards against double-injection via `grep -q "<!-- aidevops:sig -->"`. That check protects against a second injection, but it does not undo the first. Once the marker is in the file, every subsequent call sees it and skips — but the file is already polluted. A user who re-runs the command after editing the brief gets stale signature data (wrong runtime, wrong session time, wrong token count) committed to the file.

4. **Mismatch with `--body` (string) handling.** The `--body` branch at line 312-323 modifies the in-memory args array without touching any file — exactly the right pattern. The `--body-file` branch should mirror this: write the augmented content to a new temp file and substitute the arg.

## Tier

**Selected tier:** `tier:standard`

**Rationale:** Single shim function modification with a clear local pattern (the `--body` branch immediately above is the model). Not in `.agents/configs/self-hosting-files.conf`, but the shim runs on every framework `gh` call — a regression here would silently corrupt issue/PR creation across all repos. Worth maintainer review rather than auto-dispatch.

## PR Conventions

Leaf task. PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/gh:326-335` — replace the in-place file append with a temp-file substitution pattern.

### Implementation Steps

1. Replace the `--body-file` augmentation block. Current:

```bash
# --- --body-file case --------------------------------------------------------
if [[ $_body_file_idx -ge 0 && -n "$_body_file_val" && -f "$_body_file_val" ]]; then
    if ! grep -q "<!-- aidevops:sig -->" "$_body_file_val" 2>/dev/null; then
        _file_content=$(<"$_body_file_val") || _file_content=""
        _sig_footer=$("$SIG_HELPER" footer --body "$_file_content" 2>/dev/null || echo "")
        if [[ -n "$_sig_footer" ]]; then
            printf '%s' "$_sig_footer" >>"$_body_file_val" || true
        fi
    fi
fi
```

Replace with a temp-file pattern:

```bash
# --- --body-file case --------------------------------------------------------
# t2861: write the augmented content to a fresh temp file rather than appending
# to the user's source. The user's brief on disk stays byte-identical.
if [[ $_body_file_idx -ge 0 && -n "$_body_file_val" && -f "$_body_file_val" ]]; then
    if ! grep -q "<!-- aidevops:sig -->" "$_body_file_val" 2>/dev/null; then
        _file_content=$(<"$_body_file_val") || _file_content=""
        _sig_footer=$("$SIG_HELPER" footer --body "$_file_content" 2>/dev/null || echo "")
        if [[ -n "$_sig_footer" ]]; then
            # Build augmented body in a temp file we own.
            _tmp_body_file=$(mktemp -t aidevops-gh-shim-body.XXXXXX) || _tmp_body_file=""
            if [[ -n "$_tmp_body_file" ]]; then
                printf '%s%s' "$_file_content" "$_sig_footer" >"$_tmp_body_file" || {
                    rm -f "$_tmp_body_file"
                    _tmp_body_file=""
                }
            fi
            if [[ -n "$_tmp_body_file" ]]; then
                # Substitute the arg pointing at user's file with our temp file.
                if [[ $_body_file_eq -eq 1 ]]; then
                    _modified_args[_body_file_idx]="--body-file=${_tmp_body_file}"
                else
                    _modified_args[_body_file_idx + 1]="$_tmp_body_file"
                fi
                # Schedule cleanup. exec clears traps, so register before exec
                # only — but exec replaces the process, so we cannot rm after.
                # Use a background reaper keyed on parent pid as a safety net.
                ( sleep 30 && rm -f "$_tmp_body_file" ) &
                disown
            fi
            # If temp creation failed, fall through silently — gh receives the
            # original file unmodified, the issue is created without a footer.
            # Better than corrupting the user's source.
        fi
    fi
fi
```

2. **Avoid the bash trap+exec problem.** The shim ends with `exec "$REAL_GH" "${_modified_args[@]}"`. `exec` replaces the process, so any `EXIT` trap registered earlier doesn't fire. The temp file would leak. Three options:

   - **Background reaper** (shown above): `( sleep 30 && rm -f "$_tmp_body_file" ) & disown`. Crude but reliable. 30s is more than enough for `gh` to finish reading the file.
   - **`mktemp` to `/tmp` directory and let the OS clean up at boot**: simpler, but litters `/tmp` until reboot.
   - **Replace `exec` with a normal call + `rm`**: changes process semantics — child becomes a real subprocess, exit codes still propagate but `gh`'s signal handling differs. Avoid unless the test suite specifically tests for parent-process behaviour.

   Recommend the background reaper.

3. Add a regression test `.agents/scripts/test-gh-shim-body-file-immutable.sh`:

```bash
#!/usr/bin/env bash
# Regression test for t2861: gh shim must not mutate --body-file source.
set -euo pipefail

# Create a fixture brief
fixture=$(mktemp -t aidevops-test-brief.XXXXXX)
printf 'Test body\n\nSecond paragraph.\n' >"$fixture"
fixture_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')

# Mock gh: just echo args, do not call the real binary
SHIM=~/.aidevops/agents/scripts/gh
REAL_GH=/bin/true SHIM_TEST_MODE=1 "$SHIM" issue create --body-file "$fixture" --title "test" 2>/dev/null || true

# Verify file is unchanged
fixture_hash_after=$(shasum -a 256 "$fixture" | awk '{print $1}')
if [[ "$fixture_hash" != "$fixture_hash_after" ]]; then
    echo "FAIL: --body-file source was mutated"
    diff <(printf 'Test body\n\nSecond paragraph.\n') "$fixture"
    rm -f "$fixture"
    exit 1
fi

rm -f "$fixture"
echo "PASS: --body-file source unchanged"
```

The test requires a `SHIM_TEST_MODE` env var that short-circuits the `exec` step (so the test can read the result of `_modified_args`). Add that minimal hook to the shim:

```bash
# At the top of the shim, near other early-return cases:
if [[ "${SHIM_TEST_MODE:-}" == "1" ]]; then
    # Test mode: print the resolved --body-file path and exit.
    # Used by test-gh-shim-body-file-immutable.sh.
    for ((_t = 0; _t < ${#_modified_args[@]}; _t++)); do
        case "${_modified_args[_t]}" in
        --body-file)
            printf 'resolved_body_file=%s\n' "${_modified_args[_t + 1]}"
            ;;
        --body-file=*)
            printf 'resolved_body_file=%s\n' "${_modified_args[_t]#--body-file=}"
            ;;
        esac
    done
    exit 0
fi
```

Insert this just before the final `exec "$REAL_GH" "${_modified_args[@]}"` line.

### Complexity Impact

- **Target function:** none (top-level shim script, not a function body)
- **Current line count:** 337 lines total in the shim
- **Estimated growth:** ~25 lines (replace existing 9-line block with ~25 lines + ~15 lines for SHIM_TEST_MODE branch)
- **Projected post-change:** ~360 lines total — still well under file-size threshold
- **Action required:** None.

### Verification

```bash
# 1. Lint
shellcheck .agents/scripts/gh

# 2. Regression test
chmod +x .agents/scripts/test-gh-shim-body-file-immutable.sh
.agents/scripts/test-gh-shim-body-file-immutable.sh
# Expected: PASS

# 3. End-to-end manual test
echo 'Test body' >/tmp/brief-test.md
hash_before=$(shasum -a 256 /tmp/brief-test.md | awk '{print $1}')
gh issue create --repo marcusquinn/aidevops-test --title "shim test" --body-file /tmp/brief-test.md --dry-run 2>&1 || true
hash_after=$(shasum -a 256 /tmp/brief-test.md | awk '{print $1}')
[[ "$hash_before" == "$hash_after" ]] && echo "PASS: file unchanged" || echo "FAIL: file mutated"
rm -f /tmp/brief-test.md

# 4. Verify temp files clean up after 30s
ls /tmp/aidevops-gh-shim-body.* 2>/dev/null
sleep 35
ls /tmp/aidevops-gh-shim-body.* 2>/dev/null && echo "FAIL: temp files leak" || echo "PASS: temp cleanup"
```

### Files Scope

- `.agents/scripts/gh`
- `.agents/scripts/test-gh-shim-body-file-immutable.sh`

## Acceptance Criteria

- [ ] `gh issue create --body-file <file>` does not modify `<file>` on disk.
- [ ] Issue body received by GitHub still includes the signature footer.
- [ ] `shellcheck .agents/scripts/gh` clean.
- [ ] New regression test `test-gh-shim-body-file-immutable.sh` PASSes.
- [ ] Temp files created by the shim are cleaned up within 60s of the gh call.
- [ ] `--body` (string) path remains unchanged — that branch is already correct.

## Context & Decisions

- **Why a temp file instead of converting `--body-file` to `--body`?** GitHub issue bodies have a 65k character limit but command-line argv has lower practical limits on some platforms. Briefs can be 500+ lines (~50k bytes) — converting to `--body` could hit argv limits. Temp file is the safer pattern.
- **Why a background reaper instead of in-process trap?** The shim ends with `exec`, which replaces the process and clears traps. Forking a sleep-then-rm and disowning it is the simplest reliable pattern for "delete this file in 30 seconds regardless of how I exit".
- **Why 30s sleep?** `gh` CLI typically completes a single issue create in 1-3s. 30s is 10x margin — long enough for slow networks, short enough that even a long-running `gh` operation has finished reading the file by then. (`gh` reads `--body-file` once at startup, not streaming.)
- **What about race conditions on the temp filename?** `mktemp -t` generates a unique filename; no race possible.
- **Why not also fix the `--body` branch?** It's already correct — it modifies the args array, not any file.

## Relevant Files

- `.agents/scripts/gh:312-323` — reference pattern: `--body` (string) branch handles augmentation in-memory without touching files.
- `.agents/scripts/gh:326-335` — current buggy `--body-file` handler.
- `.agents/scripts/gh-signature-helper.sh` — the helper that generates the footer; signature behaviour itself is unchanged.
- `prompts/build.txt` §"#8 Signature footer hallucination" — documents the signature contract this shim implements.
- Memory: WORKING_SOLUTION on parallel `gh issue create --body-file` race (2026-04-22T19:24:20Z) — separate bug class, will not be fixed by this task.

## Dependencies

- **Blocked by:** none
- **Blocks:** None directly. Reduces noise in committed brief files going forward.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | re-read .agents/scripts/gh:280-337 for full arg-parsing context |
| Implementation | 30m | replace block + add SHIM_TEST_MODE branch |
| Testing | 45m | write + verify regression test, manual e2e |
| **Total** | **~85m** | |

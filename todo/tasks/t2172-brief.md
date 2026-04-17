---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2172: auto-clean broken symlinks in opencode runtime dirs

## Origin

- **Created:** 2026-04-17
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** User reported that new OpenCode sessions fail to start with "Failed to parse command /Users/marcusquinn/.config/opencode/command/jersey-planning-search.md" on the splash screen. Root cause is a broken symlink in `~/.config/opencode/command/` pointing to a target directory that no longer exists. Urgent patch release requested.

## What

A self-healing cleanup that removes broken (dangling) symlinks from the four OpenCode runtime directories:

- `~/.config/opencode/command/`
- `~/.config/opencode/agent/`
- `~/.config/opencode/skills/` (recursive — symlinks live at `<skill>/SKILL.md`)
- `~/.config/opencode/tool/`

The cleanup is exposed as a new `cleanup-broken-symlinks` subcommand on `agent-sources-helper.sh` (the script that creates these symlinks in the first place) and is called automatically from the existing self-healing paths so it reaches all users without intervention:

1. Cron path: `aidevops-update-check.sh` (runs every ~10 min as part of the existing update check).
2. Install path: `setup.sh` (fresh installs + `aidevops update --force`).
3. Creator path: `agent-sources-helper.sh sync`, `add`, and `remove` already touch the symlink tree — a call to the new cleanup at the end of each ensures the tree leaves every invocation clean.

The fix also ships in a patch release (3.8.66 -> 3.8.67) so existing users on the update cron pick it up within ~10 minutes.

## Why

New OpenCode sessions currently fail at splash-screen parse of the command directory if *any* symlink in that directory is dangling. The user already reproduced this locally with three broken symlinks pointing into a `planning-jersey-agents` custom source that was moved/deleted without going through `agent-sources-helper.sh remove`. The session-blocking failure mode is easy to reach and silent: once a private source's local clone is moved, renamed, or deleted outside the helper's `remove` command, the symlinks it created become orphans and the next new session dies.

Without this fix:

- Any user whose private agent source clone is ever moved or deleted is one session-restart away from losing OpenCode entirely.
- There is no existing self-heal — the current `cleanup_source_symlinks` is keyed on source NAME, so it fires only on explicit `remove <source>`, not on "symlink target vanished".
- Manual recovery requires the user to know the exact failing path (opencode shows only the first failing file), `rm` it, and pray no others exist.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — Actually touches 3 files (helper + update-check + setup-module) + 1 new test. Exceeds the limit.
- [x] **Every target file under 500 lines?** — `agent-sources-helper.sh` is 635 lines. Exceeds.
- [ ] **Exact `oldString`/`newString` for every edit?** — No, the new function and call sites are insertions in context.
- [x] **No judgment or design decisions?** — There ARE judgment calls: which dirs to scan (picked 4 based on opencode layout), whether to recurse (yes for `skills/`), error messaging.
- [x] **No error handling or fallback logic to design?** — Some: silent-no-op when dir missing, idempotent, log removed paths.
- [x] **No cross-package or cross-module changes?** — All in `.agents/scripts/`.
- [x] **Estimate 1h or less?** — Yes, ~45m including test.
- [x] **4 or fewer acceptance criteria?** — Yes.

Several items unchecked. Also this is being implemented directly in the interactive session (no dispatch), so tier is notional. Marking `tier:standard`.

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file change with some design judgment (directory coverage, messaging, idempotency). Implemented interactively; tier labels are for future re-dispatch only.

## PR Conventions

Leaf (non-parent) issue. PR body uses `Resolves #<issue>` to close the issue on merge.

## How (Approach)

### Worker Quick-Start

```bash
# Quick repro of the bug (from a clean $HOME):
mkdir -p "$HOME/.config/opencode/command"
ln -s /tmp/does-not-exist.md "$HOME/.config/opencode/command/broken.md"
# New opencode session splash: "Failed to parse command .../broken.md"

# The fix pattern (one-liner equivalent of what cleanup_broken_command_symlinks does):
find "$HOME/.config/opencode/command" -maxdepth 1 -type l ! -exec test -e {} \; -print -delete
```

### Files to Modify

- `EDIT: .agents/scripts/agent-sources-helper.sh` — add `cleanup_broken_command_symlinks()` function, wire into `cmd_sync`, `cmd_add`, `cmd_remove`; add `cleanup-broken-symlinks` subcommand + help entry. Model on the existing `cleanup_source_symlinks()` at :286-323.
- `EDIT: aidevops.sh` — add a fail-open call to `agent-sources-helper.sh cleanup-broken-symlinks` near the end of `cmd_update` (line ~1010). This reaches every user on the auto-update cron.
- `EDIT: .agents/scripts/aidevops-update-check.sh` — add a fail-open call at the end of `main()` for session-start self-heal (belt-and-braces alongside the cron path).
- `NEW: .agents/scripts/tests/test-opencode-symlink-cleanup.sh` — regression test using a temp `$HOME`. Model on `.agents/scripts/tests/test-auto-dispatch-no-assign.sh` for harness conventions.

### Implementation Steps

1. **Add the cleanup function** to `agent-sources-helper.sh` (just above `cleanup_source_symlinks` at line 285):

```bash
# Remove dangling symlinks from all OpenCode runtime dirs.
# A dangling symlink in any of these paths breaks opencode at session start
# because the runtime parses the dir and fails on the first broken entry.
# Safe to run unconditionally — only removes symlinks whose target does not exist.
cleanup_broken_command_symlinks() {
	local -a dirs=(
		"${HOME}/.config/opencode/command"
		"${HOME}/.config/opencode/agent"
		"${HOME}/.config/opencode/skills"
		"${HOME}/.config/opencode/tool"
	)

	local removed=0
	local dir
	for dir in "${dirs[@]}"; do
		[[ -d "${dir}" ]] || continue
		# maxdepth 3 covers command/*.md (depth 1), skills/<name>/SKILL.md (depth 2),
		# and any future nested symlink layouts without walking node_modules etc.
		while IFS= read -r link; do
			# -L && ! -e = symlink whose target is missing
			if [[ -L "${link}" && ! -e "${link}" ]]; then
				local target
				target="$(readlink "${link}" 2>/dev/null || echo '?')"
				info "  Removed broken symlink: ${link#"${HOME}/"} -> ${target}"
				rm -f "${link}"
				((++removed))
			fi
		done < <(find "${dir}" -maxdepth 3 -type l 2>/dev/null)
	done

	if [[ ${removed} -gt 0 ]]; then
		success "Removed ${removed} broken symlink(s) from OpenCode runtime dirs"
	fi
	return 0
}
```

2. **Add the `cleanup-broken-symlinks` subcommand** in `main()` case block:

```bash
cleanup-broken-symlinks)
	cleanup_broken_command_symlinks
	;;
```

3. **Add help entry** in `show_help()` after the existing commands.

4. **Wire into existing flows**. At the end of `cmd_sync` (before `return 0`), at the end of `cmd_add` (after sync), and at the end of `cmd_remove` (after `cleanup_source_symlinks`): call `cleanup_broken_command_symlinks`. This ensures orphans created by a failed mid-sync or a manually-deleted source are swept immediately.

5. **Wire into cron path** — `aidevops-update-check.sh`. Add a single call near the end (fail-open):

```bash
# Self-heal broken opencode symlinks (t2172). Never block the update cron.
if [[ -x "${SCRIPT_DIR}/agent-sources-helper.sh" ]]; then
	"${SCRIPT_DIR}/agent-sources-helper.sh" cleanup-broken-symlinks >/dev/null 2>&1 || true
fi
```

6. **Wire into install path** — `setup-modules/config.sh` (after command/agent generation). Same pattern as cron, fail-open.

7. **Regression test** — `test-opencode-symlink-cleanup.sh`:
   - Create temp `$HOME` with `command/live.md -> /existing-target`, `command/broken.md -> /nonexistent`, `skills/foo/SKILL.md -> /nonexistent`.
   - Run `HOME=$fake agent-sources-helper.sh cleanup-broken-symlinks`.
   - Assert: `live.md` still exists; `broken.md` gone; `skills/foo/SKILL.md` gone; `skills/foo/` dir remains.
   - Idempotency: second run removes nothing, exits 0.

### Verification

```bash
# Syntax + lint
bash -n .agents/scripts/agent-sources-helper.sh
shellcheck .agents/scripts/agent-sources-helper.sh
shellcheck .agents/scripts/tests/test-opencode-symlink-cleanup.sh

# Regression test
.agents/scripts/tests/test-opencode-symlink-cleanup.sh

# Manual verify against the original bug
mkdir -p /tmp/t2172-fake/.config/opencode/command
ln -s /does-not-exist /tmp/t2172-fake/.config/opencode/command/orphan.md
HOME=/tmp/t2172-fake .agents/scripts/agent-sources-helper.sh cleanup-broken-symlinks
test ! -L /tmp/t2172-fake/.config/opencode/command/orphan.md && echo OK
rm -rf /tmp/t2172-fake
```

## Acceptance Criteria

- [ ] `agent-sources-helper.sh cleanup-broken-symlinks` removes dangling symlinks from `command/`, `agent/`, `skills/`, and `tool/` under `~/.config/opencode/`.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-opencode-symlink-cleanup.sh"
  ```
- [ ] The cleanup is called from `aidevops-update-check.sh` (cron path) and fails open.
  ```yaml
  verify:
    method: codebase
    pattern: "cleanup-broken-symlinks"
    path: ".agents/scripts/aidevops-update-check.sh"
  ```
- [ ] The cleanup is called from `cmd_update` in `aidevops.sh` (cron/update path).
  ```yaml
  verify:
    method: codebase
    pattern: "cleanup-broken-symlinks"
    path: "aidevops.sh"
  ```
- [ ] The cleanup is called from `agent-sources-helper.sh` internal flows (`cmd_sync`, `cmd_add`, `cmd_remove`).
  ```yaml
  verify:
    method: bash
    run: "grep -c 'cleanup_broken_command_symlinks' .agents/scripts/agent-sources-helper.sh | awk '$1 >= 4 { exit 0 } { exit 1 }'"
  ```
- [ ] Patch release 3.8.67 is tagged and pushed so users on the update cron pick it up within ~10 min.
  ```yaml
  verify:
    method: manual
    prompt: "After merge, run .agents/scripts/version-manager.sh release patch and confirm tag v3.8.67 is pushed."
  ```
- [ ] `bash -n` and `shellcheck` clean.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/agent-sources-helper.sh .agents/scripts/tests/test-opencode-symlink-cleanup.sh"
  ```

## Context & Decisions

- **Why cleanup instead of tolerance-in-opencode:** OpenCode is the runtime; aidevops is the creator of these symlinks. The fix belongs on the creator side — aidevops should not leave orphaned symlinks that confuse any parser (opencode today, something else tomorrow).
- **Why all four dirs, not just `command/`:** All four are opencode discovery paths and all could plausibly host symlinks (agent-sources-helper.sh creates at least in `command/` and the agents root; skills/ already has one broken entry locally unrelated to private sources). Covering all four is strictly safer and has no cost — a `-L && ! -e` check is near-free.
- **Why in `agent-sources-helper.sh` rather than a new script:** That helper is the primary creator of runtime-dir symlinks and already has a cleanup helper. Adding a complementary "cleanup broken" subcommand is the smallest-diff, most-discoverable home.
- **Why fail-open on the cron path:** A cleanup script that crashes the update cron would be far worse than the symptom it fixes. Stderr-silent `|| true` is the safe default.
- **Not touched:** `pulse-wrapper.sh`, `pulse-merge.sh`, `dispatch-dedup-helper.sh`, `worker-lifecycle-common.sh` — user explicitly asked to preserve pulse stability and these have nothing to do with the symlink issue.

## Relevant Files

- `.agents/scripts/agent-sources-helper.sh:285-323` — existing `cleanup_source_symlinks()` pattern to follow
- `.agents/scripts/agent-sources-helper.sh:547-583` — `sync_slash_commands()` which creates the symlinks in the first place
- `.agents/scripts/agent-sources-helper.sh:588-633` — `main()` case dispatch where new subcommand goes
- `.agents/scripts/aidevops-update-check.sh` — cron-invoked update check
- `.agents/scripts/setup-modules/config.sh` — setup-time opencode config wiring
- `.agents/scripts/tests/test-auto-dispatch-no-assign.sh` — test harness pattern to model on
- `.agents/scripts/version-manager.sh` — release mechanics (patch bump)

## Dependencies

- **Blocked by:** none (hotfix)
- **Blocks:** new OpenCode session starts for any user whose private agent source gets moved/deleted (currently broken for them)
- **External:** patch release tag must be pushed for users to receive the fix via `aidevops update`

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Already done — agent-sources-helper.sh + generate-opencode-commands.sh |
| Implementation | 25m | Helper function + 4 call sites + test |
| Testing | 15m | Regression test + manual repro + shellcheck |
| Release | 10m | version-manager.sh release patch + verify tag |
| **Total** | **~1h** | |

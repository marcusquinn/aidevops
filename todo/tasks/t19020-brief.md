<!-- aidevops:brief-schema=v2 -->

# t19020: Session-greeting advisories must ask only for real human action

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `advisory toast session greeting ordering remedy noise`, `canonical recovery advisory DS_Store uncommitted noise` → 0 hits
- [x] Discovery pass: no open PRs or issues touch the target files; recent commits are e0c21939f7 (t19004) and 9001538f44 (GH#38273), which this builds on
- [x] File refs verified at HEAD `3176ba3296`
- [x] Tier: `tier:standard`. Local display and diagnosis only; no dispatch, merge or trust-boundary change

## Origin

- **Created:** 2026-11-15
- **Session:** opencode interactive productivity mission (Parent #38332 / t19002 evidence track)
- **Created by:** ai-interactive
- **Conversation context:** The maintainer asked that users rarely, if ever, need to read into issues or local state. Session mining for that mission found the session-start greeting asking for human attention on noise, while the one high-leverage human action is buried.

## What

The session-start greeting (`aidevops-update-check.sh::_check_advisories` → OpenCode toast) should list only advisories that need a human, each with the correct next step. Specifically:

1. Canonical-checkout diagnosis should ignore untracked OS/runtime metadata (`.DS_Store`, `Thumbs.db`, `desktop.ini`, and OpenCode's `.opencode/` dependency artefacts), so those files alone never raise "requires manual review".
2. The canonical-recovery advisory's `Effect:` text should state the real effect. Since t2871, pulse does not pause PR processing for a dirty canonical checkout.
3. Per-repo advisories already counted by the setup-debt `[WARN]` aggregate (`sync-pat-*`, `cross-account-inherit-*`, `repo-onboarding-*`) should not be listed again one by one.
4. Per-reason `underfill-*` and per-repo `canonical-recovery-*` advisories should collapse to one line per family.
5. The generic "Run in your terminal: `aidevops security`" suffix should appear only on security advisories. Every line keeps its dismiss hint.
6. The GitHub App read-routing advisory should be classified `[WARN]` and carry its own setup command in the displayed line.
7. (Scope added during implementation.) The displayed summary should skip writer metadata (epoch stamps, `[advisory:<id>]` headers, `#` lines) and unwrap `title:`. A healthy auto-update daemon should clear a stale `daemon-disabled` advisory on any update, not only interactive TTY runs. Evidence: the advisory had been shown since 2026-11-06 while `aidevops auto-update health-check` reported `HEALTHY (last run 242s ago)`; `macos-user-lookup` displayed only `1794625049`.

## Why

Measured on 2026-11-15 (local machine, point-in-time):

- `~/.aidevops/cache/session-greeting-opencode.txt` was 59 lines, from 51 advisory files. 23 `Repository: …` lines and 2 SYNC_PAT/cross-account lines repeated the three setup-debt `[WARN]` aggregates. 6 `UNDERFILL_ATTRIBUTION` lines were pulse diagnostics with AI-runnable remedies.
- 7 `[CANONICAL DIAGNOSTIC] <repo> requires manual review` lines. For 5 repos the only dirty path was an untracked `.DS_Store`; for 1 it was an untracked `.opencode/package-lock.json` written by OpenCode's plugin install (its generated `.opencode/.gitignore` covers `package.json` and `bun.lock` but not npm's lockfile). `canonical-recovery-routine.sh` retries every tick and retains them forever (`tick complete: scanned=7 cleared=0 retained=7`).
- The advisory body claims "PR processing, CI failure routing, and completion sweep are paused for this repo". That text dates from t2871 (2ada606812). Today the only caller, `pulse-wrapper-cycle.sh:193-195`, ignores the return code, and canonical maintenance is diagnostic-only (`pulse-canonical-maintenance.sh:300-323`).
- The App read-routing advisory (`github-app-read-routing`) reports that 78% of known REST cost could move off the PAT. Pulse logs show 56 progress-stage deferrals (`dispatch_max`, `preflight_early_dispatch`, `preflight_post_label_refill`, `approval_merge_trigger`) in the `emergency` REST band at `0/5000`. Yet this advisory is an unprefixed info line buried mid-toast, and its suffix sends the user to `aidevops security`, which does not set up an App.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Display-layer aggregation plus a narrow porcelain filter, both following existing patterns (`worktree-helper-add.sh:80-102` already filters `?? .DS_Store`). No dispatch or trust-boundary change.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-canonical-recovery.sh:165-182`: in `_pcr_detect_state`, drop untracked (`??`) records from `git status --porcelain -z --untracked-files=all` (raw paths, untracked directories expanded) whose path is OS metadata (basename `.DS_Store`, `Thumbs.db`, `desktop.ini`) or an OpenCode dependency artefact under `.opencode/` (`package-lock.json`, `bun.lock`, `package.json`, `node_modules/*`) before classifying `uncommitted`. Tracked edits and every other untracked path remain `uncommitted`.
- `EDIT: .agents/scripts/pulse-canonical-recovery.sh:337-338`: correct the `Effect:` text. Keep lines 1-4 unchanged: `canonical-recovery-routine.sh::_crr_extract_repo_path` parses line 4.
- `EDIT: .agents/scripts/aidevops-update-check.sh:373-443`: in `_check_advisories`, skip setup-debt-covered prefixes when the aggregate line was emitted, collapse the `underfill-*` and `canonical-recovery-*` families, and limit the `aidevops security` suffix to `[SECURITY ADVISORY]`/`[ADVISORY]` lines.
- `EDIT: .agents/scripts/github_auth_usage.py:98-110`: prefix line 1 with `[WARN]` and include the `app create` command plus the unbound owners in it.
- `EDIT: aidevops.sh:559-561` and `.agents/scripts/aidevops-cli/aidevops-update-lib.sh:712-746`: non-interactive updates call `_update_check_daemon_health --clear-only`, which removes a stale advisory when healthy and never writes. Line 1 of a written advisory carries the fix command.

### Complete Write Surface

- **Callers/readers:** `_check_advisories` output feeds the greeting cache and `greeting-toast.mjs::classifyLines` (prefix-based buckets). `canonical-recovery-routine.sh` parses advisory line 4 only.
- **Writers/mutation paths:** none new. Advisory files are rewritten by their existing writers. Once a repo's state is `clean`, `canonical-recovery-routine.sh` removes the stale advisory on its next tick.
- **Existing verification/tests:** `.agents/scripts/tests/test-canonical-recovery.sh`, `.agents/scripts/tests/test-setup-debt-helper.sh`, `.agents/scripts/tests/test-update-check-gh-slurp-prerequisite.sh`, `.agents/scripts/tests/test-pulse-underfill-attribution.sh`.
- **Generated/deployed mirrors:** deployed by `setup.sh`; nothing generated.
- **Cleanup/rollback paths:** a revert restores per-file listing; advisory files are disposable.

### Hazards and Compatibility

- A human's untracked `.DS_Store` is never meaningful work, and the canonical checkout is still never mutated (diagnosis only).
- Mixed versions: older hosts keep listing every advisory line. No file-format change except the App advisory's line 1.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-canonical-recovery.sh
bash .agents/scripts/tests/test-setup-debt-helper.sh
bash .agents/scripts/tests/test-update-check-gh-slurp-prerequisite.sh
bash .agents/scripts/tests/test-pulse-underfill-attribution.sh
shellcheck .agents/scripts/pulse-canonical-recovery.sh .agents/scripts/aidevops-update-check.sh
```

Production path: `DRY_RUN=1 .agents/scripts/pulse-canonical-recovery.sh --dry-run <canonical-with-only-.DS_Store>` reports clean. Running `_check_advisories` against the live advisory directory shows the collapsed lines.

### Files Scope

- `.agents/scripts/pulse-canonical-recovery.sh`
- `.agents/scripts/aidevops-update-check.sh`
- `.agents/scripts/github_auth_usage.py`
- `aidevops.sh`
- `.agents/scripts/aidevops-cli/aidevops-update-lib.sh`

## Acceptance Criteria

- [ ] A canonical checkout whose only dirty path is an untracked `.DS_Store` is diagnosed `clean`; a human untracked file or tracked edit is still `uncommitted`.
- [ ] With the live advisory set, the greeting lists no per-repo line already counted by a setup-debt `[WARN]`, at most one underfill line and at most one canonical-recovery line.
- [ ] The App read-routing line is `[WARN]`-classified and shows `aidevops github auth app create --owner`.
- [ ] Non-security advisory lines no longer tell the user to run `aidevops security`.
- [ ] A non-interactive update with a healthy daemon removes a stale `daemon-disabled` advisory.

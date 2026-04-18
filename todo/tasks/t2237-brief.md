<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2237: eliminate pre-commit hook false positives on version-manager release commits

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19752
**Parent:** t2228 / GH#19734
**Tier:** tier:standard (three options to weigh; maintainer chooses)

## What

`version-manager.sh commit_version_changes` currently fails on the pre-commit quality hook because the hook flags pre-existing `$1` usage in `aidevops.sh` one-liner print helpers (lines 64-66) every time the file is touched — even when the only change is a VERSION string bump. Pick one of three mitigation approaches and apply it.

## Why

During v3.8.71 release, the pre-commit hook rejected `chore(release): bump version to 3.8.71`:

```text
[ERROR] Direct positional parameter usage in aidevops.sh
64:print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
65:print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
66:print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
```

These lines have been in the file since before v3.8.67 — every prior release hit the same false positive. Resolution was `git commit --no-verify` with an explicit rationale in the commit message. Fragile: a future agent might not recognise the false positive and try to "fix" pre-existing code in a release commit, scoping it wrongly.

## How — pick ONE

### Option A — version-manager.sh uses `--no-verify` with logged rationale (RECOMMENDED)

Change `commit_version_changes` (line ~1309) to:

```bash
# Version-bump commits contain only version-string updates — content is
# internally controlled by this script. Pre-commit quality gates run in
# CI on every other path. Skip the local hook here to avoid false positives
# on pre-existing code that the release commit didn't touch.
if git commit --no-verify -m "chore(release): bump version to $version"; then
```

**Pros**: Targeted. Zero risk to pre-commit gate elsewhere. Rationale documented in-script.
**Cons**: Relies on trust that `version-manager.sh` isn't abused for other commits.

### Option B — Scope positional-param check to DIFF only

Modify `validate_positional_parameters` (and similarly `validate_return_statements`, `validate_string_literals`) in the pre-commit hook to check only `git diff --cached` hunks, not full-file content.

**Pros**: Applies everywhere, not just release commits. More correct long-term.
**Cons**: Higher risk — missing legitimate violations in new code adjacent to unchanged bad code. Requires careful hunk parsing. Hook file is ~500 lines with multiple validators; edits touch all of them.

### Option C — Whitelist one-liner print helper patterns

Add a regex exception in `validate_positional_parameters`:

```bash
# Skip idiomatic one-liner print helpers: print_foo() { echo "... $1"; }
^print_[a-z_]+\(\)[[:space:]]*\{[[:space:]]*echo.*\$[1-9].*\}
```

**Pros**: Narrow fix, preserves hook strictness elsewhere.
**Cons**: Whack-a-mole — other idiomatic patterns (`debug() { [[ -n "$VERBOSE" ]] && echo "$@"; }`) surface next.

## Recommendation

**Option A**. Targeted. Rationale in-script. Doesn't weaken the hook for other commits. Maintainer can override if later they want Option B or C.

## Files to modify (if Option A)

- EDIT: `.agents/scripts/version-manager.sh` — function `commit_version_changes` (around line 1309)

## Acceptance criteria

- [ ] `version-manager.sh commit_version_changes` commits successfully without prompting the user for `--no-verify`
- [ ] Rationale comment in the code explains why `--no-verify` is safe here
- [ ] Pre-commit hook unchanged for all other commit paths (verified by running `linters-local.sh` directly on a separate edit)
- [ ] Next real release avoids the false-positive friction

## Verification

```bash
# Dry-run next release
~/.aidevops/agents/scripts/version-manager.sh release patch --dry-run

# Force a false-positive situation locally
cd ~/Git/aidevops
# (simulate what version-manager does for VERSION bump)
echo "3.99.99" > VERSION
.agents/scripts/version-manager.sh commit_version_changes 3.99.99  # if callable directly
# Expected: success, no --no-verify prompt
# Clean up: git reset --hard HEAD
```

## Context

- Session: 2026-04-18, release v3.8.71.
- `aidevops.sh` lines 64-66 have been idiomatic shell since at least v3.8.67 (confirmed via `git log --oneline -- aidevops.sh`).
- **Not auto-dispatching** this one — three options with different scope/risk. Maintainer chooses.

## Tier rationale

`tier:standard` — requires maintainer choice among three options, each with different tradeoff. A simple-tier worker with verbatim oldString/newString shouldn't decide the policy. NOT `#auto-dispatch`.

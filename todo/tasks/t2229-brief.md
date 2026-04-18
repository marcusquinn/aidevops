<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2229: prevent `.task-counter` silent regression on PR merge

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19735
**Parent:** t2228 / GH#19734
**Tier:** tier:standard (multiple layers, needs coordinated design)

## What

Guarantee that no PR merge can regress `.task-counter` below `origin/main`'s current value. Three-layer defence: `.gitattributes` merge strategy, CI monotonicity check, and automatic drift reset during `full-loop-helper.sh commit-and-pr` rebase.

## Why

Silent data-loss risk. During v3.8.71 release lifecycle:

- Branch forked at `.task-counter = 2214`.
- Canonical ran `claim-task-id.sh` → counter → 2215.
- Three parallel sessions bumped it to 2218.
- `full-loop-helper.sh commit-and-pr` rebased my branch onto `origin/main` at t=T, picking up 2215.
- By t=T+45s (push-to-PR), `origin/main` was 2218. My PR's `.task-counter` showed a 2218→2215 regression in the diff.
- Squash-merge would have silently reverted to 2215. Next `claim-task-id.sh` would re-allocate t2215 — duplicating an already-claimed ID.

Caught only by eyeballing `git diff --stat`. Zero automated defence today.

## How

### Layer 1 — `.gitattributes`

```gitattributes
.task-counter merge=ours
```

`merge=ours` preserves the branch's version on merge, but **does not apply to squash-merges** (our default). Still worth adding for the rare non-squash merge path and as a signal of intent.

### Layer 2 — CI check (`.github/workflows/counter-monotonic.yml`)

New workflow on `pull_request` events. Logic:

```yaml
name: Counter Monotonic Check
on:
  pull_request:
    paths: ['.task-counter']
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Compare counter
        run: |
          BASE=$(git show "origin/${{ github.base_ref }}:.task-counter")
          HEAD=$(cat .task-counter)
          if [ "$HEAD" -lt "$BASE" ]; then
            echo "::error::PR regresses .task-counter ($BASE → $HEAD). Rebase onto latest base."
            exit 1
          fi
          echo "counter: $BASE → $HEAD (OK)"
```

Blocks the PR deterministically.

### Layer 3 — `full-loop-helper.sh commit-and-pr` auto-reset

In `_rebase_and_push` (around line 674), after successful `git rebase origin/main`, compare branch's `.task-counter` to `origin/main`'s:

```bash
if [[ -f .task-counter ]]; then
    local branch_counter base_counter
    branch_counter=$(cat .task-counter)
    base_counter=$(git show origin/main:.task-counter)
    if [[ "$branch_counter" -lt "$base_counter" ]]; then
        print_info "Auto-resetting .task-counter: $branch_counter → $base_counter (base drifted during rebase)"
        echo "$base_counter" > .task-counter
        git add .task-counter
        git commit -m "chore: reset .task-counter to origin/main value (race prevention)"
    fi
fi
```

Prevents the regression ever being pushed.

## Acceptance criteria

- [ ] `.gitattributes` at repo root has `.task-counter merge=ours` entry
- [ ] `.github/workflows/counter-monotonic.yml` exists and runs on PRs touching `.task-counter`
- [ ] CI check fails on a deliberate-regression test PR
- [ ] `full-loop-helper.sh commit-and-pr` auto-resets drifted counter before push
- [ ] `claim-task-id.sh` CAS loop unchanged (allocation-time correctness still guaranteed)
- [ ] Regression test in `.agents/scripts/tests/` verifying the rebase reset

## Verification

```bash
# Layer 2 test: push a PR that deliberately regresses .task-counter
# Expect: counter-monotonic.yml check fails

# Layer 3 test: simulate drift locally
cd ~/Git/aidevops-feature-test
git checkout -b test/counter-drift
# (edit some file, commit)
echo "$(($(cat .task-counter) - 5))" > .task-counter  # fake a regression
git commit -am "regression test"
~/.aidevops/agents/scripts/full-loop-helper.sh commit-and-pr \
  --issue <test-issue> --message "test" --title "test: counter drift"
# Expect: auto-reset commit appears in log before push
```

## Context

- Session: 2026-04-18, PR #19715 (t2214 gemini nits).
- First observed during manual rebase after `full-loop-helper.sh commit-and-pr` reported `.task-counter` in the diff — the helper succeeded but produced a regressing PR.
- Confirmed via `git show origin/main:.task-counter` (2218) vs `git show HEAD:.task-counter` (2215).
- Critical because duplicate task IDs are invisible until collision, by which point two briefs exist for one ID and audit trail is tangled.
- Related: t2047 (commit-msg collision guard) protects against manual tNNN-in-subject collisions. This issue covers the orthogonal `.task-counter` file-level risk.

## Tier rationale

`tier:standard` — three coordinated layers, new CI workflow, new helper branch logic. A simple-tier worker with only oldString/newString can't scaffold all three files. Needs a reasoning model that can hold the cross-layer invariant in mind.

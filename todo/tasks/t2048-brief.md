---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2048: implement: fine-grained PAT path for github-actions[bot] main push (from t2038 decision)

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:headless worker for t2038 (GH#18522)
- **Created by:** marcusquinn (via t2038 research decision)
- **Parent task:** t2038 (GH#18522) — research/decide task that picked this path
- **Conversation context:** t2038 researched two viable paths for unblocking `github-actions[bot]` pushes to `main` and chose **Path B (fine-grained PAT)** over **Path C (rulesets + deploy key)** on setup-cost asymmetry (~20–30m vs ~2–3h), rollback simplicity, and identical threat model. **Path A (rulesets + github-actions Integration bypass)** was disqualified because personal-account repos return `422 Validation Failed — Actor GitHub Actions integration must be part of the ruleset source or owner organization`. See `todo/tasks/t2038-brief.md` "Decision" section for the full rationale. This task implements the chosen path.

## What

The `sync-on-pr-merge` job in `.github/workflows/issue-sync.yml` uses a repo-scoped fine-grained PAT (stored as Actions secret `SYNC_PAT`) instead of `secrets.GITHUB_TOKEN` for the `Checkout main` + `Update TODO.md proof-log` steps. The PAT authenticates as the repo admin (`marcusquinn`), and because classic branch protection has `enforce_admins: false`, the push bypasses `required_approving_review_count` and lands the proof-log commit on `main` directly.

Two parts:

1. **Maintainer-only manual step (cannot be done by an LLM worker):** create the fine-grained PAT in GitHub UI and add it as the repo secret `SYNC_PAT`. Credential step — out of scope for headless automation.
2. **Code change (this task's deliverable):** update `.github/workflows/issue-sync.yml` so the relevant steps use `secrets.SYNC_PAT` with a documented fallback to `secrets.GITHUB_TOKEN` (so the workflow keeps working until the maintainer creates the secret, falling back to the t2029/t2034 loud-failure path).

End-state: a merged PR that toggles the workflow to prefer `SYNC_PAT` when set, documentation in the workflow file explaining the PAT setup procedure, and a follow-up completion note in `.agents/AGENTS.md` and `todo/tasks/t2038-brief.md` once the maintainer has actually added the secret and verified a real PR merge auto-completes its TODO entry.

## Why

The t2029+t2034 loud-failure fix makes the branch-protection rejection visible and actionable but does not remove the friction. Every merged PR with a tNNN title still fires the fallback path (`::error::` annotation + PR comment + manual `task-complete-helper.sh` call). At this repo's merge volume, that's ~10–30 manual command runs per day for the maintainer. The PAT path eliminates this in ~20–30 minutes of one-time setup plus ~15 minutes of PAT rotation per year.

The decision rationale (why PAT and not the rulesets alternative) is fully documented in `todo/tasks/t2038-brief.md` "Decision" section. Implementation does NOT need to re-derive it.

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 1 file: `.github/workflows/issue-sync.yml`. Plus 1 doc update to `.agents/AGENTS.md` (trivial paragraph edit).
- [x] **Complete code blocks for every edit?** — yes, see "How" section below; every edit has a full diff.
- [x] **No judgment or design decisions?** — the design decision is already in t2038-brief.md. This task is pure plumbing.
- [x] **No error handling or fallback logic to design?** — fallback to `secrets.GITHUB_TOKEN` is explicit and minimal (`${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}`).
- [x] **≤1h estimate?** — ~30–45m for the workflow edit + doc update.
- [x] **≤4 acceptance criteria?** — exactly 4.

**Selected tier:** `tier:standard`

**Tier rationale:** The workflow edit is mechanical but touches a security-sensitive boundary (which principal's credentials are used for a direct-push-to-main step). A Sonnet-level worker can follow the explicit diffs below without re-deriving the security reasoning. Simple tier would be borderline — the `||` fallback syntax and the two-step edit pattern push it just past the simple-tier disqualifier of "multi-step coordinated changes across a file". Standard tier gives enough headroom without burning reasoning-tier budget.

## How (Approach)

### Prerequisite: maintainer PAT setup (manual, NOT done by the worker)

**Document this in the workflow file comments but do not attempt it from an automated worker.** The maintainer runs these steps once:

1. Navigate to <https://github.com/settings/personal-access-tokens/new>.
2. **Token name:** `aidevops-sync-on-pr-merge`.
3. **Expiration:** 366 days (maximum allowed for fine-grained PATs). Calendar reminder at day 330 to rotate.
4. **Resource owner:** `marcusquinn` (the repo owner).
5. **Repository access:** Only select repositories → `marcusquinn/aidevops`.
6. **Repository permissions:**
   - `Contents`: Read and write
   - (All others: No access, including `Workflows` — explicitly NOT `Workflows: Write`.)
7. Generate the token and copy it.
8. Navigate to <https://github.com/marcusquinn/aidevops/settings/secrets/actions/new>.
9. **Name:** `SYNC_PAT`
10. **Value:** the token from step 7.
11. Save.

Verification (from any machine with `gh auth`):

```bash
gh api "repos/marcusquinn/aidevops/actions/secrets" --jq '.secrets[] | select(.name == "SYNC_PAT") | .name'
# Expected: SYNC_PAT
```

### Code change: switch the sync-on-pr-merge steps to prefer SYNC_PAT

**File:** `.github/workflows/issue-sync.yml`

**Edit 1 — `Checkout main` step (around line 458–465):** switch the `token` parameter to prefer `SYNC_PAT`, falling back to `GITHUB_TOKEN`.

Current (verified at line 458–465 on the feature/t2038-bypass-research branch):

```yaml
      - name: Checkout main
        if: steps.extract.outputs.task_id != ''
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          ref: main
          fetch-depth: 1
          token: ${{ secrets.GITHUB_TOKEN }}
```

After:

```yaml
      - name: Checkout main
        if: steps.extract.outputs.task_id != ''
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          ref: main
          fetch-depth: 1
          # t2048: prefer SYNC_PAT (fine-grained PAT scoped to this repo,
          # Contents: Read and write) to bypass branch protection via
          # enforce_admins:false. Falls back to GITHUB_TOKEN when the secret
          # is unset, which routes to the t2029/t2034 loud-failure path.
          # See todo/tasks/t2038-brief.md Decision section for rationale.
          token: ${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}
```

**Edit 2 — `Update TODO.md proof-log` step env block (around line 467–479):** add `SYNC_PAT_AVAILABLE` flag and replace `GH_TOKEN` assignment to prefer `SYNC_PAT`.

Current:

```yaml
      - name: Update TODO.md proof-log
        if: steps.extract.outputs.task_id != ''
        env:
          TASK_ID: ${{ steps.extract.outputs.task_id }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          # t2034: gh CLI needs GH_TOKEN explicitly — without it, the t2029
          # `gh pr comment` fallback (posted when the TODO.md push is rejected
          # by branch protection) silently fails because gh has no auth.
          # ...
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

After:

```yaml
      - name: Update TODO.md proof-log
        if: steps.extract.outputs.task_id != ''
        env:
          TASK_ID: ${{ steps.extract.outputs.task_id }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          # t2034: gh CLI needs GH_TOKEN explicitly — without it, the t2029
          # `gh pr comment` fallback (posted when the TODO.md push is rejected
          # by branch protection) silently fails because gh has no auth.
          # t2048: prefer SYNC_PAT for the push so branch protection bypass
          # works via enforce_admins:false. Still falls back to GITHUB_TOKEN
          # for the gh CLI call even when SYNC_PAT is unset — the PR comment
          # is always useful to post regardless of which token did the push.
          GH_TOKEN: ${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}
```

**Edit 3 — add a `Detect PAT availability` step BEFORE the push attempt** so the workflow log explicitly records which credential path ran. This turns "did the secret actually work?" into a one-grep question instead of a forensic archaeology trip through workflow logs. Add this as a new first line inside the `Update TODO.md proof-log` step's `run:` block, right after the `git config` lines:

```yaml
          # t2048: log which credential path is active so operators can tell
          # at a glance whether the PAT is wired up. This is the single clear
          # signal that tells "did the PAT swap land?" without spelunking.
          if [[ -n "${SYNC_PAT_PRESENT:-}" ]]; then
            echo "::notice::Using SYNC_PAT for push (t2048 path)"
          else
            echo "::notice::Using GITHUB_TOKEN for push (pre-t2048 fallback — push will be rejected by branch protection)"
          fi
```

And add to the env block:

```yaml
          # t2048: expose secret presence as a boolean-ish env var. GitHub
          # hides secret values from logs, but ${{ secrets.SYNC_PAT != '' }}
          # evaluates to 'true' or 'false' at workflow-compile time and is
          # safe to log.
          SYNC_PAT_PRESENT: ${{ secrets.SYNC_PAT != '' && 'true' || '' }}
```

### AGENTS.md doc update

The t2038 brief already updated `.agents/AGENTS.md` "Known limitation" paragraph to mention t2048 as the implementation tracking task. After t2048 merges AND the maintainer actually adds the `SYNC_PAT` secret AND a real PR merge succeeds with the new path, the paragraph should be updated to note the limitation is resolved. That doc update is a follow-up t2049 (to be filed after verification), NOT part of t2048 itself.

### Verification

```bash
# YAML still parses
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/issue-sync.yml'))"

# SYNC_PAT appears in the right place (2 occurrences: checkout token + env.GH_TOKEN)
grep -c "secrets.SYNC_PAT || secrets.GITHUB_TOKEN" .github/workflows/issue-sync.yml
# Expected: 2

# Notice step is present
grep "Using SYNC_PAT for push" .github/workflows/issue-sync.yml
# Expected: 1 match

# SYNC_PAT_PRESENT env var is exposed
grep "SYNC_PAT_PRESENT:" .github/workflows/issue-sync.yml
# Expected: 1 match
```

**Runtime verification (post-merge, maintainer-driven, NOT part of the worker's scope):** after the PAT is added as a secret and a subsequent PR with a `tNNN:` title merges to `main`, the `sync-on-pr-merge` workflow run logs should contain `::notice::Using SYNC_PAT for push (t2048 path)` and the push should succeed WITHOUT the t2029 fallback firing. The TODO entry should be `[x]` with `pr:#NNN completed:YYYY-MM-DD` proof-log on `main` within ~2 minutes of merge.

## Acceptance Criteria

- [ ] `.github/workflows/issue-sync.yml` `Checkout main` step uses `${{ secrets.SYNC_PAT || secrets.GITHUB_TOKEN }}` as its token.
  ```yaml
  verify:
    method: codebase
    pattern: "token: \\$\\{\\{ secrets.SYNC_PAT \\|\\| secrets.GITHUB_TOKEN \\}\\}"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] `Update TODO.md proof-log` step's `GH_TOKEN` env uses the same fallback chain.
  ```yaml
  verify:
    method: codebase
    pattern: "GH_TOKEN: \\$\\{\\{ secrets.SYNC_PAT \\|\\| secrets.GITHUB_TOKEN \\}\\}"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] A `::notice::` log line is emitted identifying which credential path is active (`SYNC_PAT_PRESENT` check).
  ```yaml
  verify:
    method: codebase
    pattern: "Using SYNC_PAT for push"
    path: ".github/workflows/issue-sync.yml"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/issue-sync.yml\"))'"
  ```

## Context & Decisions

**Why not just replace `GITHUB_TOKEN` outright with `SYNC_PAT`.** The `||` fallback ensures the workflow keeps running correctly even before the maintainer creates the secret. Without the fallback, the workflow would fail to check out `main` (no token) until the secret is added, which would block ALL TODO.md auto-completion — even the existing loud-failure fallback. With the fallback, the workflow behaves exactly like pre-t2048 until `SYNC_PAT` appears, then automatically starts using it. This is the safest possible deploy order.

**Why a new `::notice::` log line instead of relying on inference from push success.** Operators need to confirm the PAT is wired up BEFORE waiting for a real failure to prove the new path works. A single grep over workflow logs answers "did the swap land?" — no forensics. Cheap to add, high signal.

**Why NOT edit the gh CLI call's auth separately from the push auth.** The gh CLI uses `GH_TOKEN` from env. Using the same fallback chain for both the checkout token and `GH_TOKEN` means the same principal handles both push and comment — simpler to reason about than two different credential paths in one step.

**Non-goals (implementation-time):**

- Renaming the `GH_TOKEN` env var to something more descriptive.
- Adding rotation reminders or calendar hooks for the PAT — that's separate operational tooling.
- Updating any OTHER workflows to also use `SYNC_PAT`. This task is scoped to the `sync-on-pr-merge` job specifically. If other workflows hit the same limitation later, file a separate task.
- Verifying the PAT actually works at runtime — that's a post-merge maintainer step, not worker scope.
- Removing the t2029/t2034 loud-failure fallback. It's still the correct behaviour when the PAT is unset OR expired.

## Relevant Files

- `.github/workflows/issue-sync.yml:458-561` — the `Checkout main` and `Update TODO.md proof-log` steps to modify.
- `.agents/AGENTS.md` "Known limitation — sync-on-pr-merge" paragraph — already updated by t2038 to reference t2048. Do NOT re-edit in this task (the paragraph will be updated again by t2049 after runtime verification).
- `todo/tasks/t2038-brief.md` "Decision" section — full decision rationale, do not re-derive.
- `todo/tasks/t2029-brief.md` and `todo/tasks/t2034-brief.md` — upstream context on the loud-failure path this PAT swap builds on top of.

## Dependencies

- **Blocked by:** t2038 (GH#18522) — the research/decide task that picked this path. Must land first. ✅ Resolved by the PR opening t2048.
- **Blocks:** the elimination of manual `task-complete-helper.sh` calls after every merge. Until t2048 lands AND the maintainer creates `SYNC_PAT`, the t2029/t2034 loud-failure path continues to fire on every merge.
- **External:** the maintainer must create the `SYNC_PAT` secret before the new code path activates. This is documented but not automatable.

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Workflow edits (3 small diffs) | ~15m |
| YAML parse verification + grep verification | ~5m |
| Commit + PR + review-bot gate | ~10m |
| **Total** | **~30m hands-on** |

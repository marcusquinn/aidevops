# t2370: worker self-apply complexity-bump-ok when PR body has justification section

## Session origin

Filed from the t2207 / PR #19821 session. The `complexity-bump-ok` label is the documented override for nesting-depth false positives on file splits (see t2368), but currently it appears to require maintainer application. On PR #19821 I applied it at creation time via `gh_create_pr --label complexity-bump-ok`, which worked because I was the maintainer. A worker dispatched against a simplification issue would not be able to self-apply, so the PR would either sit waiting for a human to notice, or fail the complexity gate and be retried endlessly.

## What

Let a worker self-apply `complexity-bump-ok` when its PR body contains a validated `## Complexity Bump Justification` section with scanner evidence. Mirrors the existing `coderabbit-nits-ok` self-apply pattern (which workers can already use when bot reviews are cosmetic).

## Why

The label exists to let legitimate file splits pass a known-false-positive CI gate. Requiring a maintainer to manually apply it:

- Turns every simplification PR into a human-gated merge (defeats the purpose of auto-dispatch).
- Is the reason simplification issues sit in the queue — prior workers completed the code change, but couldn't cross the CI gate, and their PRs auto-closed or stalled.
- Has an obvious validation surface: the justification section must cite scanner evidence (file:line ref + measurement). That's a mechanical check, not a human judgement.

The precedent exists: `coderabbit-nits-ok` is worker-applicable on PRs with only CodeRabbit cosmetic CHANGES_REQUESTED reviews (prompts/build.txt → "Review Bot Gate" Override). Same shape: a worker knows "this class of feedback is dismissable, I'm going to mark it" and the review bot gate respects the label. Symmetric for complexity.

## How

1. **Workflow validator** that enforces the justification section is present and non-empty:

   - NEW: `.github/workflows/complexity-bump-justification-check.yml`
   - Trigger: `pull_request` events on `labeled` with `complexity-bump-ok`.
   - Check: PR body contains a `## Complexity Bump Justification` H2 section AND at least one `file:line` reference AND at least one numeric measurement (regex match for digits and/or "depth=", "base=", "head=").
   - On fail: remove the label, post a comment explaining what's missing, re-request the label after the body is updated. Mirror `.github/workflows/new-file-smell-justification-check.yml` if it exists (parallel precedent for `new-file-smell-ok` label with required justification section).
   - Model on: search `.github/workflows/` for the existing `coderabbit-nits-ok` or `new-file-smell-ok` enforcement workflow and copy the structure.

2. **Permission grant for workers:**

   - EDIT: wherever label-application authorization is enforced. Likely either: (a) GitHub branch-protection label-push restrictions, (b) a pulse-side check, or (c) nothing — GitHub itself doesn't restrict label writes per-user, so if workers can already label, no code change is needed and only (1) matters.
   - Verify empirically: as a worker token, attempt `gh pr edit N --add-label complexity-bump-ok`. If it fails → find the restriction and relax it with the validator as the gate. If it succeeds → the validator is sufficient.

3. **Documentation**:

   - EDIT: `prompts/build.txt` "Review Bot Gate" section (or wherever `coderabbit-nits-ok` is documented) to add the `complexity-bump-ok` self-apply rule symmetrically.
   - EDIT: the playbook being created in t2368 (`.agents/reference/large-file-split.md`) to document the self-apply rule in the "Known CI false-positive classes" section.

## Verification

- Simulate a PR with `complexity-bump-ok` label applied and NO `## Complexity Bump Justification` section in body → validator runs → label removed, comment posted.
- Simulate with the section present but no evidence → validator runs → label removed, comment posted.
- Simulate with full section + evidence → validator passes → label stays → Complexity Analysis gate accepts the PR.
- Dispatch a worker against a synthetic `file-size-debt` issue. Observe worker creates PR with justification section and label. Verify no human intervention required to merge.

## Acceptance criteria

- [ ] `.github/workflows/complexity-bump-justification-check.yml` validates the required section on `labeled` event
- [ ] Validator removes the label and posts a remediation comment on invalid PRs
- [ ] `prompts/build.txt` documents the self-apply rule (symmetric with `coderabbit-nits-ok`)
- [ ] Either: (a) workers can apply the label with no additional config change (verified empirically), OR (b) the authorization path is relaxed with a documented rationale
- [ ] A scanner-dispatched worker can complete a file-size-debt simplification PR end-to-end without maintainer intervention (verified via next real simplification dispatch)

## Tier

`tier:standard` — new workflow file + one doc edit + empirical permission check. Medium scope, pattern to copy from `coderabbit-nits-ok` / `new-file-smell-ok`.

## Related

- #19821 — the PR where `complexity-bump-ok` was applied by the maintainer; workers couldn't have done this
- t2368 (#19824) — the playbook that documents the label as the documented override; depends on this task landing for workers to actually USE it
- t2371 (#19828) — richer scanner bodies will pre-declare the label expectation; this task makes that declaration actionable
- Framework precedent: `coderabbit-nits-ok` self-apply, `new-file-smell-ok` justification workflow

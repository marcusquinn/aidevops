# t2368: reference doc: large-file split playbook for shell libs

## Session origin

Filed from the t2207 / PR #19821 session after six prior worker attempts failed on the same simplification task (#19699). Root cause of every failure was missing framework knowledge (not missing worker capability). Consolidating that knowledge into a single reference doc is the highest-leverage fix: one place to read before starting, instead of re-discovering the same lessons each time.

## What

Write `.agents/reference/large-file-split.md` — the canonical playbook for splitting a large shell library into sub-libraries. Covers the mechanical pattern, the known CI false-positive classes and their overrides, and a PR body template. Linked from scanner-filed issue bodies (see t2371) so workers have a direct pointer.

## Why

Every worker that attempted #19699 re-discovered the same issues from scratch:

- Nesting-depth scanner is a global `elif`-counter; produces false positives on file splits. Unknown without reading `.agents/scripts/complexity-regression-helper.sh:225-256`.
- `complexity-bump-ok` label exists as the documented override. Unknown without grepping the codebase.
- Pre-commit hook flags `"$var"` as "repeated string literals" (t2230 bug). Workaround requires user permission.
- Pre-push hook rejects on same nesting-depth false positive; `COMPLEXITY_GUARD_DISABLE=1` is the targeted bypass. Unknown without reading the hook's error message.
- Function-complexity identity key is `(file, fname)` — moving a >100-line function to a new file creates a "new" violation even though the function is unchanged. Must keep such functions in the original file. Unknown without tracing the scanner.
- `issue-sync-lib.sh` is the in-repo precedent for include guards + SCRIPT_DIR fallback + sub-library sourcing. Unknown without searching the repo.
- `printf '%s\0' "$@"` is the compliant rest-args emitter (vs `while shift; printf "$1"` which trips the positional-parameter hook). Unknown without hitting the hook.

These are all documentable in 200-300 lines of reference. Workers then arrive at the task already knowing the answer.

## How

NEW: `.agents/reference/large-file-split.md` with these sections (in order):

1. **When to use this** — you're responding to a `file-size-debt` / `function-complexity` / `nesting-depth` scanner issue, OR you're voluntarily splitting a shell lib that's grown past maintainable size.

2. **Canonical pattern** — with a working example built from `headless-runtime-lib.sh` + `headless-runtime-{provider,failure,model}.sh` (or `issue-sync-helper.sh` + `issue-sync-lib.sh` as a simpler cite):
   - Orchestrator file retains include guard, imports shared-constants, sources sub-libraries.
   - Each sub-library: include guard (`_XXX_LIB_LOADED=1`), SPDX header, usage comment.
   - Sourcing: `# shellcheck source=./sub-lib.sh` + `# shellcheck disable=SC1091` (runtime-resolved via `$SCRIPT_DIR`, static resolution impossible without `-x`).
   - Defensive `SCRIPT_DIR` fallback in the orchestrator, derived from `BASH_SOURCE[0]`. Cite the `issue-sync-lib.sh` precedent (`issue-sync-lib.sh:35-41`).

3. **Identity-key preservation rules**:
   - `function-complexity` keys on `(file, fname)`. Functions over 100 lines MUST stay in the original file, or they re-register as new violations.
   - `file-size` keys on `file`. Splitting automatically resolves this.
   - `nesting-depth` keys on `(file, 'NEST')`. Splitting into new files creates new violation keys — expect `+N new` regressions. This is a known false positive (see section 4).
   - `bash32-compat` keys on the specific construct. Splitting is neutral.

4. **Known CI false-positive classes on splits**:
   - **Nesting-depth**: `complexity-regression-helper.sh scan_dir_nesting_depth` (`:225-256`) is a global `elif`-counting AWK, not a real nesting metric. `elif` matches the open-regex but has no corresponding close, inflating the counter. Evidence: the pre-split `headless-runtime-lib.sh` scored `max_depth=83` (physically impossible). **Override**: apply `complexity-bump-ok` label and include `## Complexity Bump Justification` section in the PR body with scanner evidence (file:line ref, measurement).
   - **Pre-push complexity guard**: the client-side hook rejects on the same false positive. Targeted bypass: `COMPLEXITY_GUARD_DISABLE=1 git push`. Document alongside the CI label.

5. **Pre-commit hook gotchas (and compliant rewrites)**:
   - `SC1091` from sourced sub-libraries → inline `# shellcheck disable=SC1091` directive with a one-line reason.
   - `validate_positional_parameters` flags `"$1"` in rest-args emit loops → rewrite as `[[ $# -gt 0 ]] && printf '%s\0' "$@"` (identical behaviour, no `$1` reference).
   - `validate_string_literals` flags `"$var"` interpolations as "repeated string literals" (variable references, not literals). **Known framework bug tracked in t2230 (#19739).** If you hit this on a split: do NOT rewrite variable references to dedupe (code harm). Options: (a) `COMPLEXITY_GUARD_DISABLE=1` + commit with `--no-verify` + maintainer approval documented in the commit message, (b) if t2230 has landed, use whatever opt-out it ships.

6. **PR body template** — complete mergeable skeleton with placeholders for file table, per-metric regression table, and complexity-bump justification. Copy from PR #19821 body as the reference.

7. **Verification checklist** — pre-push sanity:
   - `shellcheck` clean on all files (warning+ severity).
   - Smoke test via the real caller path (`SCRIPT_DIR=... source <orchestrator>`) to confirm all expected functions resolve and behaviour is identical.
   - `.agents/scripts/complexity-regression-helper.sh check` for all four metrics; expect `file-size new=0`, `function-complexity new=0`, `bash32-compat new=0`, and document any `nesting-depth new>0` in the PR body.

## Verification

- PR reviewers can point to this doc when flagging common mistakes.
- `grep -rn "large-file-split.md" .agents/` surfaces links from: issue bodies (see t2371), scanner-output templates, relevant agent prompts.
- Run `.agents/scripts/verify-agent-discoverability.sh` if such a thing exists for reference docs (or add check).
- Cross-link from the AGENTS.md "Git Workflow" section under a "Large-file refactors" bullet.

## Acceptance criteria

- [ ] `.agents/reference/large-file-split.md` exists with the 7 sections above
- [ ] Cites concrete `file:line` references for scanner internals (at minimum: `complexity-regression-helper.sh:225-256`, `issue-sync-lib.sh:35-41`)
- [ ] Includes a complete PR body template that copy-pastes into `gh pr create --body`
- [ ] Linked from AGENTS.md Git Workflow section
- [ ] Linked from `workflows/brief.md` or equivalent (so brief composition picks it up)
- [ ] A worker reading ONLY this doc + the scanner-filed issue body can complete a split PR end-to-end without re-discovering any lesson

## Tier

`tier:standard` — writing a reference doc, medium scope, requires synthesis of multiple sources but all are in-repo.

## Related

- #19699, #19821 — the session that surfaced the missing documentation
- #19739 (t2230) — the string-literal hook bug; if fixed, section 5's last bullet simplifies
- GH#19118 — pre-dispatch validators (related infrastructure)
- t2367 (#19823) — pre-dispatch validator (complementary fix)
- t2370 (#19826) — worker self-apply of `complexity-bump-ok` (reduces friction for workers following this playbook)
- t2371 (#19828) — richer scanner-filed bodies (will link to this doc)

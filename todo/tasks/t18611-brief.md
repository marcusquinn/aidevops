<!-- aidevops:brief-schema=v2 -->

# Add a shell-style rule and diff-scoped gate for early-exit pipe readers under pipefail

## Origin

- Created from the maintainer review of #33882 (fixed by PR #33903). The review marked this as a separate follow-up, not part of that PR.
- Class is recurring: #27981 (worktree branch lookup SIGPIPE), #30824 (issue-sync first-match pipelines), #33882 (brief readiness flips on large briefs).

## What

Add a documented rule plus a diff-scoped check that flags new `<writer> | grep -q…` (and the same early-exit reader shape: `grep -m1`, `head -n…`) inside scripts that enable `pipefail`. Model it on the existing counter-stack gate so only PR-changed lines are judged; historical occurrences are not blocked.

## Why

Under `set -o pipefail`, an early-exit reader closes the pipe after its first match. A writer still producing output gets SIGPIPE (exit 141), and `pipefail` reports 141 instead of the reader's 0. The result is a false "no match" that depends on input size and pipe buffer timing. In #33882 a 256 KB body gave 100/100 false negatives on macOS, and a Linux runner flipped ~3% of runs. `reference/shell-style-guide.md` has no SIGPIPE rule and no gate exists, so each instance is found by incident.

Baseline at filing (main): `rg -o "\|[[:space:]]*grep[[:space:]]+-[[:alpha:]]*q" .agents/scripts .agents/hooks --glob '*.sh' --glob '!**/tests/**'` gives 966 matches across 284 files. Many are safe (short writers that finish before the reader exits), which is why this must be a changed-line gate, not an absolute count.

## Tier

`tier:standard` — new checker and workflow copied from an existing gate pattern; no shared-library changes.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/pipe-early-exit-check.sh` — model on `.agents/scripts/counter-stack-check.sh` (`--scan-files`, `--scan-all`, `--fix-hint`, per-file `# pipe-early-exit-check:disable` directive in the first 20 lines).
- `NEW: .github/workflows/pipe-early-exit-check.yml` — model on `.github/workflows/counter-stack-check.yml` (changed `.sh` files only, sticky PR comment marker `<!-- pipe-early-exit-check -->`).
- `EDIT: .agents/reference/shell-style-guide.md` — new section after "Counter Safety (grep -c)" (currently line 99) with banned/allowed patterns and the enforcement pointer.
- `NEW: .agents/scripts/tests/test-pipe-early-exit-check.sh` — fixture cases for the checker (required by the style guide's "Self-modifying tooling test discipline").

### Complete Write Surface

- **Callers/readers:** `.github/workflows/pipe-early-exit-check.yml` (new) is the only caller of `.agents/scripts/pipe-early-exit-check.sh`. `.agents/scripts/linters-local.sh` is not changed; `rg -n counter-stack-check .agents/scripts --glob 'linters-local*.sh'` returns nothing, so the copied gate is CI-only today and this keeps parity.
- **Writers/mutation paths:** N/A with evidence: the checker only reads `.sh` files and prints findings; the workflow writes only one sticky PR comment through the marker `<!-- pipe-early-exit-check -->`, as `.github/workflows/counter-stack-check.yml:84` does.
- **Existing verification/tests:** new fixtures in `.agents/scripts/tests/test-pipe-early-exit-check.sh`. Existing SIGPIPE regressions that must stay green: `.agents/scripts/tests/test-worktree-helper-branch-lookup-sigpipe.sh`, `.agents/scripts/tests/test-pulse-sigpipe-llm-state.sh`, `.agents/scripts/tests/test-brief-readiness.sh`.
- **Schemas/config:** N/A with evidence: no config file is read; options are CLI flags copied from `.agents/scripts/counter-stack-check.sh`. Making the job a required check is a maintainer branch-protection action outside this task.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; no generated file or manual mirror edit is involved.
- **Migrations/backfills:** N/A with evidence: the gate is diff-scoped, so the 966 historical matches need no backfill and are explicitly out of scope.
- **Cleanup/rollback paths:** delete `.github/workflows/pipe-early-exit-check.yml` to disable the gate; `.agents/scripts/pipe-early-exit-check.sh` and the style-guide section are inert without it.

### Implementation Steps

1. Read `.agents/scripts/counter-stack-check.sh` and `.github/workflows/counter-stack-check.yml`; copy their structure and option names.
2. Detection (line-based is acceptable): flag a line that pipes into `grep` with `-q`/`--quiet`/`-m 1`, or into `head`, when the file enables pipefail (`set -o pipefail` or a `set -…o pipefail` combined flag). Skip comment lines, here-string forms (`grep -q … <<<"$x"`), and files with the disable directive.
3. `--fix-hint` prints the allowed patterns: `grep -qF -- "$needle" <<<"$haystack"`; or capture to a variable first, then test; or `{ writer || true; } | grep -q` only when the writer's status is genuinely irrelevant.
4. Workflow: run on `pull_request` for changed `*.sh` files only; fail only on findings on lines the PR adds (`git diff -U0` against the base); post/update one sticky comment.
5. Style-guide section: banned pattern, allowed patterns, one-paragraph mechanism, enforcement pointer, and originating incidents #27981, #30824, #33882.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A with evidence: read-only scanner; concurrent PR runs only update their own PR's sticky comment.
- **Migration/rollback:** the workflow, checker and doc section land in one PR; reverting it removes the gate with no residual state.
- **Mixed-version/backward compatibility:** judge added lines only (`git diff -U0` against the PR base), so touching a legacy file does not fail on its pre-existing matches. Files without pipefail are ignored. Short writers (`printf '%s' "$small"`) are still flagged on new lines; that is intended because the here-string form is always safe, and the disable directive covers fixtures.
- **Idempotency/retry:** reruns update the same sticky comment in place via the marker, as counter-stack-check does; findings are deterministic for a given diff.
- **Partial failure/recovery:** a scanner error fails the job closed with its error text; no repository state changes, so a rerun is the recovery.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pipe-early-exit-check.sh
bash .agents/scripts/pipe-early-exit-check.sh --scan-files .agents/scripts/brief-readiness-helper.sh
shellcheck .agents/scripts/pipe-early-exit-check.sh .agents/scripts/tests/test-pipe-early-exit-check.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the test script proves detection of `| grep -q` / `| head` under pipefail, the here-string allowance, the disable directive and the ignored non-pipefail file (acceptance criteria 1-3). The `--scan-files` run on the file fixed by #33903 is the clean positive control for the allowed pattern. `shellcheck` and `linters-local.sh --changed` cover the new script, test and `.github/workflows/pipe-early-exit-check.yml` lint. The style-guide section is checked by Markdown Lint in CI (criterion 4).
- **Broad verification trigger:** Not required; no shared library, root tooling or release path changes.

### Scope Boundaries

- Do not rewrite the 966 historical occurrences in this PR.
- Do not add the check to `linters-local.sh` or pre-commit hooks.
- Do not change `counter-stack-check.sh`.

### Files Scope

- `.agents/scripts/pipe-early-exit-check.sh`
- `.agents/scripts/tests/test-pipe-early-exit-check.sh`
- `.github/workflows/pipe-early-exit-check.yml`
- `.agents/reference/shell-style-guide.md`

## Acceptance Criteria

- [ ] A PR that adds `printf '%s\n' "$body" | grep -qF "$marker"` to a pipefail script gets a failing `pipe-early-exit-check` job naming the file and line.
- [ ] A PR that adds `grep -qF -- "$marker" <<<"$body"` passes.
- [ ] A PR that touches no `.sh` files, or only files without pipefail, does not fail (negative/regression guarantee: no absolute-count blocking of legacy debt).
- [ ] `reference/shell-style-guide.md` documents the banned and allowed patterns and links the enforcement script.
- [ ] Existing SIGPIPE regression tests still pass.

## Context & Decisions

- Diff-scoped rather than a `ratchets.json` count, because most of the 966 existing matches are harmless short writers and counting them would trap unrelated edits (see "Gate design — ratchet, not absolute" in the style guide).
- `head` and `grep -m1` are included because #30824 was the first-match variant of the same mechanism.

## Relevant Files

- `.agents/scripts/counter-stack-check.sh` — pattern to copy.
- `.github/workflows/counter-stack-check.yml` — workflow pattern to copy.
- `.agents/scripts/brief-readiness-helper.sh` — fixed example (#33903).
- `.agents/reference/shell-style-guide.md:99` — neighbouring "Counter Safety" section for placement and format.

## Dependencies

- None.

## Estimate Breakdown

- Checker + fixtures: 1.5h. Workflow: 0.5h. Docs: 0.5h. Total ~2.5h.

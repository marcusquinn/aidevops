<!-- aidevops:brief-schema=v2 -->

# t18549: Brief readiness: read indented continuation lines so nested sub-bullet fields are not reported empty

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found while publishing the pulse-review follow-up briefs t18546, t18547 and t18548. Each draft failed `verify-brief-helper.sh check-readiness` only because field content sat in nested sub-bullets. Issue: GH#33009.

## What

Schema-v2 readiness should accept a write-surface, hazard or surface-mapping field whose content is held in indented sub-bullets under the `- **Field:**` label, while still rejecting empty, placeholder and bare `N/A` fields.

## Why

- `_field_line` returns only the first line that contains `**<field>:**` (`.agents/scripts/brief-readiness-helper.sh:162-169`). `_field_is_substantive` then rejects the empty remainder (L171-186), and `_write_surface_field_is_valid` never sees the backticked paths in the sub-bullets (L188-203).
- On 2026-09-29, one draft failed 8 fields at once (`write-surface:Callers/readers;write-surface:Writers/mutation paths;write-surface:Cleanup/rollback paths;write-surface:Existing verification/tests;hazard:Concurrency/atomicity;hazard:Mixed-version/backward compatibility;hazard:Idempotency/retry;hazard:Partial failure/recovery;`). Every field had to be rewritten as one long line.
- A readability-neutral formatting choice blocks `publication:pending` → `auto-dispatch` reconciliation (`.agents/scripts/planning-publication-reconcile.sh:153-193`) and costs one retry loop per brief.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a bounded parser change in one helper, plus test variants in its existing test file. No dispatch-path, pulse or release files change.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/brief-readiness-helper.sh:162-169` — make `_field_line` return the first matching field line joined with its continuation lines. Use one awk pass, not repeated greps.
  - Continuation lines are the following lines indented deeper than the field's own bullet. Stop at the first blank line, heading, or line at the same or lower indentation.
  - Keep case-insensitive, first-match behaviour.
  - Return a single line joined with spaces, so the regexes in `_field_is_substantive` (L171-186) and `_write_surface_field_is_valid` (L188-203) work unchanged.
- `EDIT: .agents/scripts/tests/test-brief-readiness.sh:460-468` — add positive and negative nested-continuation variants derived from `BODY_V2_COMPLETE` via `sed`, following the `BODY_V2_SHORT_PATH_BUN` pattern, plus matching numbered test blocks after the last existing test.

### Complete Write Surface

- **Callers/readers:** `_field_line` is read only by `_field_is_substantive` and `_write_surface_field_is_valid` in `.agents/scripts/brief-readiness-helper.sh`; the schema-v2 verdict is consumed by `.agents/scripts/verify-brief-helper.sh`, `.agents/scripts/planning-publication-reconcile.sh`, `.agents/scripts/pulse-dispatch-brief-scope.sh`, `.agents/scripts/claim-task-id-issue.sh`, `.agents/scripts/issue-sync-lib-compose.sh` and `.agents/scripts/issue-body-format-helper.sh`.
- **Writers/mutation paths:** N/A because the helper is read-only over brief text; no file, label or cache is written by the changed function.
- **Schemas/config:** N/A because the brief schema-v2 marker, field names and `.agents/templates/brief-template.md` are unchanged; nested sub-bullets become an accepted spelling of the same field.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/brief-readiness-helper.sh` to `~/.aidevops/agents/scripts/` on release.
- **Migrations/backfills:** N/A because no persisted data changes; briefs that pass today still pass.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/brief-readiness-helper.sh` and `.agents/scripts/tests/test-brief-readiness.sh`.
- **Existing verification/tests:** `.agents/scripts/tests/test-brief-readiness.sh` (including T20/T22 fenced-content rejection) and `.agents/scripts/tests/test-verify-brief.sh`.

### Implementation Steps

1. Rewrite `_field_line` in `.agents/scripts/brief-readiness-helper.sh` as one awk pass that finds the first case-insensitive `**<field>:**` line, records its leading indent, appends deeper-indented following lines, and prints one space-joined line.
2. Stop the continuation at a fence delimiter line (three or more backticks or tildes). Write-surface and hazard sections are already fence-filtered by `_extract_markdown_section`, but the verification section is extracted with fenced content included (`.agents/scripts/brief-readiness-helper.sh:330`), so `Surface mapping` must not absorb an indented code block.
3. Add positive and negative nested variants to `.agents/scripts/tests/test-brief-readiness.sh`, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the function is a pure text transform with no shared state, files or locks.
- **Migration/rollback:** no persisted format; rollback is a plain revert with no data to restore.
- **Mixed-version/backward compatibility:** every brief that passes today keeps passing because the first line is unchanged and only appended to; older deployed helpers keep rejecting nested fields until the release reaches them, which is today's behaviour.
- **Idempotency/retry:** the verdict is a deterministic function of the brief text, so repeated checks give the same result.
- **Partial failure/recovery:** if awk finds no field line the function returns empty output and the caller rejects the field exactly as today; a malformed continuation can only add text to a field, never remove the placeholder, `TBD` or `N/A` rejections applied to the joined line.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/brief-readiness-helper.sh .agents/scripts/tests/test-brief-readiness.sh
bash .agents/scripts/tests/test-brief-readiness.sh
bash .agents/scripts/tests/test-verify-brief.sh
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18538-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18548-brief.md
```

- **Surface mapping:** `shellcheck` covers both changed files; `test-brief-readiness.sh` proves the positive nested case, the empty, bare `N/A` and sibling-field negatives, and fenced-content rejection (backward-compatibility and partial-failure hazards); `test-verify-brief.sh` and the two real briefs prove existing single-line briefs, and briefs with a first-line value plus sub-bullets, still report `WORKER_READY=true` (mixed-version hazard).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**

- Do not change field names, the schema-v2 marker or `.agents/templates/brief-template.md`.
- Do not relax the placeholder, `TBD`, `TODO`, bare `N/A` or `unknown` rejections.
- Do not let fenced code blocks populate a field, including in the verification section.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/brief-readiness-helper.sh`
- `.agents/scripts/tests/test-brief-readiness.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] A schema-v2 brief whose write-surface and hazard fields hold content only in indented sub-bullets, with backticked paths in the write-surface ones, reports `WORKER_READY=true`.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-brief-readiness.sh"
  ```

- [ ] Negative/regression: a field label with no inline text and no continuation still fails, a field whose only continuation is `N/A` still fails the write-surface rule, a sibling `- **Next field:**` line is never merged into the previous field, and fenced content still cannot satisfy a field.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-brief-readiness.sh && bash .agents/scripts/tests/test-verify-brief.sh"
  ```

- [ ] Existing published briefs still pass readiness unchanged.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18538-brief.md"
  ```

## Context & Decisions

- Joining continuation lines into one line was chosen over rewriting the field regexes, so the existing substantive and write-surface rules apply to nested content without duplication.
- Changing the template to forbid sub-bullets was rejected: models and house style naturally split multi-part fields, and the parser, not the author, should absorb that.

## Relevant Files

- `.agents/scripts/brief-readiness-helper.sh:162-203` — field extraction and validation
- `.agents/scripts/brief-readiness-helper.sh:325-358` — schema-v2 field loop
- `.agents/scripts/brief-readiness-parser.awk` — section and fence parsing (read-only)
- `.agents/scripts/tests/test-brief-readiness.sh:179-304,460-468` — `BODY_V2_COMPLETE` and the `sed`-variant pattern
- `.agents/scripts/planning-publication-reconcile.sh:153-193` — publication gate that consumes readiness (read-only)

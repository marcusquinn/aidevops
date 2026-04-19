# t2371: large-file simplification gate: richer scanner-filed issue bodies

## Session origin

Filed from the t2207 / PR #19821 session. Issue #19699 (the scanner-filed simplification issue) had a body that said, essentially: "file exceeds 2000 lines, break into smaller focused modules". That body told the worker WHAT but not HOW. Six prior workers tried, all failed on the same set of framework-knowledge gaps (see t2368). Making the scanner's body richer — specifically, linking to the playbook and pre-declaring the expected override label — turns a 20-token body into a 100-token body that a worker can actually execute.

## What

Enhance `pulse-dispatch-large-file-gate.sh`'s issue-body template (line ~545-600) so scanner-filed file-size-debt issues link to the split playbook, cite a concrete in-repo precedent, pre-flag the `complexity-bump-ok` label expectation, and name the cohesive function groups in the cited file. Same treatment for sibling simplification gates (function-complexity, nesting-depth).

## Why

Scanner-filed issue bodies are the first thing a dispatched worker reads. If the body names the pattern to copy, the worker arrives at the task already oriented. If not, the worker spends its first 30% of context budget exploring. PR #19821 spent tokens re-discovering:

- `issue-sync-lib.sh` as the split precedent
- `complexity-bump-ok` as the override label
- The justification-section expectation

All of which could have been pre-declared in the issue body in one sentence each.

Density is cheap when it's pointers. Dense instructions (300 lines inline) would be the wrong direction — those go in the playbook (t2368). Dense pointers (10 lines naming files, labels, precedents) go in every scanner-filed body.

## How

1. **Scanner-body enhancement**

   - EDIT: `.agents/scripts/pulse-dispatch-large-file-gate.sh` around line 545-600 where the issue body is composed.
   - Current body template has `## What`, `## Why`, `## How` sections. Enhance `## How` with:

     ```markdown
     ## How

     - EDIT: `{cited_file}`
     - Extract cohesive function groups into separate files
     - Keep a thin orchestrator in the original file that sources the extracted modules
     - Verify: `wc -l {cited_file}` should be below {threshold}

     **Reference pattern:** `.agents/reference/large-file-split.md` (playbook for shell-lib splits).

     **Precedent in this repo:** `issue-sync-helper.sh` + `issue-sync-lib.sh` — the canonical split. Copy the include-guard and SCRIPT_DIR-fallback pattern from there.

     **Expected CI gate overrides:** This PR will likely trigger a `nesting-depth` regression from the file-split identity-key change. This is a known false positive — apply the `complexity-bump-ok` label AND include a `## Complexity Bump Justification` section in the PR body citing scanner evidence. See the playbook § "Known CI false-positive classes".

     **Generator marker** (for pre-dispatch validator, t2367):
     <!-- aidevops:generator=large-file-simplification-gate cited_file={cited_file} threshold={threshold} -->
     ```

2. **Sibling gates** — apply equivalent enhancements to:

   - `.agents/scripts/*complexity*.sh` for `function-complexity` issues (different playbook section, different override label).
   - `.agents/scripts/*nesting*.sh` or wherever `nesting-depth` issues are filed, if that's a separate gate.

3. **Verification test** — NEW: `.agents/scripts/tests/test-large-file-gate-body.sh` that invokes the gate against a fixture repo and asserts the issue body contains the playbook link, precedent cite, override label mention, and generator marker.

## Verification

- After landing, dispatch a synthetic file-size-debt issue and confirm the body has all four enhancements.
- Inspect the next real scanner-filed issue in the wild — verify body quality.
- Side benefit: the `aidevops:generator=` marker enables t2367's validator path with zero extra work.

## Acceptance criteria

- [ ] Scanner-filed file-size-debt issue bodies link to `.agents/reference/large-file-split.md` (once t2368 lands) OR a named placeholder until then
- [ ] Bodies cite `issue-sync-lib.sh` (or current canonical split) as the in-repo precedent
- [ ] Bodies pre-declare `complexity-bump-ok` label expectation + justification section requirement
- [ ] Bodies emit the `<!-- aidevops:generator=... -->` marker (completes t2367's upstream half)
- [ ] Unit test verifies all four enhancements
- [ ] Treatment applied symmetrically to sibling scanners (function-complexity, nesting-depth if separate)

## Tier

`tier:standard` — body-template enhancement, straightforward string changes, clear verification path.

## Depends on

- t2368 (#19824) — playbook must exist before the body can link to it. Until t2368 lands, use a TODO placeholder.
- t2367 (#19823) — generator marker is shared infra with this task; whichever lands first, the other copies the marker format.

## Related

- #19699 — canonical example of a too-thin scanner body (the "just break into focused modules" body)
- #19822 — duplicate filing that a better body + generator marker would have prevented
- PR #19821 — source of the lessons embedded in this enhancement
- GH#18538 — worker triage responsibility (thin bodies defeat this)

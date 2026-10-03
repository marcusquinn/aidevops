# t18576: fix(pulse-dep-graph): read dependencies only from structured fields, not prose or code spans in issue bodies

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33166
- **Conversation context:** Found when GH#33159 was falsely labelled status:blocked from prose examples in its body.

## What

The dependency graph treats any issue-body line containing the dependency phrase as a real dependency, including prose and backtick-quoted examples. An issue that only discusses dependency syntax gets `status:blocked` and never dispatches.

## Why

Observed on 2026-09-30 with GH#33159 (t18575), a claim-task-id bug report with no real predecessor:

- Its Why section quoted two example TODO dependency fields containing t18563, t18571, GH#33135 and GH#33150, all open.
- A pulse run relabelled it from `status:available` to `status:blocked` 17 minutes after creation, with no comment. Planning publication then added `status:available` back, leaving both status labels at once.
- Rewording the two prose lines so no task ID or issue number followed the phrase removed the false dependency.

Root cause: `.agents/scripts/pulse-dep-graph.sh:89` matches the phrase anywhere, case-insensitively, and captures to end of line. `:90-91` then collect every task ID and `#NNN` on the rest of that line. There is no anchoring to a field and no skipping of code spans or fenced blocks.

This is the same failure class as GH#26391, where body text created a circular dependency; that fix only changed the meta-issue filer.

## How

1. In `pulse-dep-graph.sh`, restrict body parsing to the structured forms the framework emits:
   - A line beginning (after optional list marker) with the bare TODO field.
   - The brief-template bold field.

   Strip fenced code blocks and inline code spans before matching, but keep accepting backtick-quoted IDs inside the bold field value, which is what `brief-template.md` emits.
2. Leave label-based and native-relationship dependencies unchanged.
3. Check `.agents/scripts/claim-task-id.sh` predecessor detection (around `:1522-1626`) for the same prose-capture pattern. Document the result in the PR; change it only if it shares the defect.

## Reference pattern

Use the fence-aware visible-text helpers already used for briefs (`_unfenced_brief_text` / `_visible_brief_text` in `.agents/scripts/brief-readiness-helper.sh`) rather than a new parser.

### Files Scope

- `.agents/scripts/pulse-dep-graph.sh`
- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/tests/test-pulse-dep-graph-prose-dependencies.sh`

## Acceptance criteria

- [ ] A body whose only dependency mention is prose or a code span yields no dependency edges.
- [ ] Structured fields still yield edges: the bare TODO field line and the brief-template bold field with backtick-quoted IDs, with no regression for existing test fixtures.
- [ ] Label and native-relationship dependencies are unchanged.

## Verification

```bash
bash .agents/scripts/tests/test-pulse-dep-graph-prose-dependencies.sh
shellcheck .agents/scripts/pulse-dep-graph.sh

```

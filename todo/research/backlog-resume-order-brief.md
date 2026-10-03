<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Recorded post-compaction next-action precedence

## Summary

The #32829 manual review sampled nine real automatic summaries from the current
mission session. First resumed tools were TodoWrite (six), memory recall (two)
and bounded-operation status (one), not Bash. Later Git revalidation does not
prove that the literal recorded next command was the first resumed action.
Do not reuse the earlier first-Bash count as exact first-tool acceptance evidence.

## Scope and ownership

- Own `.agents/plugins/opencode-aidevops/compaction.mjs`, especially
  `compactionSummaryRules` around lines 360-387, and its existing focused test
  if acceptance requires a change. Discover that test by the function name.
- Do not modify `v2.mjs` or its adapter test; the independent cache unit owns them.
- Reference the existing highest-priority host-aligned summary rules and
  `.agents/reference/session.md`. Keep all host headings and user aims intact.
- Parent owns integration, review, runtime verification, merge and release.
  Deliver a draft PR, never merge or publish.

## How

Determine whether the recorded next move actually requires the observed first
tool; classify any justified revalidation before declaring a defect. Where the
summary records a safe next action, make its precedence over optional housekeeping
and progress narration explicit in the summary presented to the resumed agent.
Do not merely add a rule seen only by the summarizer and then discarded.
Keep the fix narrow and inspect duplicate instructions before adding guidance.
Never automatically execute a command parsed from historical summary text.
Fresh user corrections and authority/safety/mutable-state checks still take
precedence; a summary cannot authorize a destructive action or widen scope.

## Verification

- Existing host-summary/continuation tests and changed-file lint must pass.
- Parent checks a real automatic compaction/resumption for preserved aims and
  whether the recorded first next action is actually executed before optional
  housekeeping or a progress reply. Text-pattern tests alone cannot certify this.
- Report honest coverage limits and source lines if the observed first action
  was justified; do not manufacture a failure or guaranteed compliance claim.

## Safety

No always-loaded guidance expansion, new runner or test-only interface, automatic
execution of historical commands, blanket permissions or global config changes.
Use local/fixture evidence in the worker; parent controls live acceptance.
This is a follow-up defect/investigation from Ref #32829, not permission to close
that reminder before its outstanding evidence has been dispositioned.

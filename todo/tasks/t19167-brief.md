# fix(decisions): holds the recovery supervisor marked as needing a human never reach /decisions

## Origin

Interactive productivity mission session, 2026-11-19. An audit of this runner's terminal-blocker recovery decisions against live issue labels.

## What

`maintainer-decisions-helper.sh list` (the `/decisions` queue) must show every open hold for which this runner's recovery supervisor recorded `wake: human_decision`, with the recorded `next_action` as the question. This must hold even when the issue's labels name an AI or dependency owner (`needs-ai-recovery`, `needs-dependency`) or only `hold-for-review`.

## Why

- `reference/worker-integration-recovery.md` "Terminal-blocker recovery" step 5 and "Unclassified holds" have the supervisor record `wake: human_decision` when only a person can resolve a hold. The supervisor deduplicates its public ask: when an older comment already names the input, it posts nothing new.
- The classifier in `maintainer-decisions-helper.sh` (`MD_CLASSIFY_JQ`) keeps an issue only when it has a `needs-maintainer-*`, `needs-credentials` or `needs-source-access` label, or a canonical supervisor ask. Older uncanonical comments match neither, so the hold was dropped silently.
- Observed 2026-11-19: 36 open local `human_decision` records, 5 of them maintainer decisions missing from `/decisions`. Example: a consent-audit issue labelled `status:blocked` + `needs-ai-recovery` for 4 days, waiting on the owner to sign a read-only SSH grant. Two issues carried `needs-dependency` while the recorded next action was a maintainer source or split decision. Those holds wait indefinitely while nobody sees them.

## How (Approach)

- `.agents/scripts/maintainer-decisions-helper.sh`:
  - Add `_md_recorded_decision repo number`. It reads `${AIDEVOPS_BLOCKER_RECOVERY_DIR:-~/.aidevops/.agent-workspace/terminal-blocker-recovery}/decisions/<owner>--<repo>--<N>.json`, the key written by `terminal-blocker-recovery-helper.sh record` (`_tbr_key`). It prints `{t, by, q}` only for `wake == "human_decision"`, otherwise `null`, and also `null` for a missing or corrupt file.
  - `_md_classify_issue` passes it as `--argjson local`. `MD_CLASSIFY_JQ` adds it to `$requests` dated `recorded_epoch`, so the existing answered, parked, replied and decide ordering applies unchanged. The final `select` keeps an issue that has a recorded request.
  - Header documents the new request source and the env var.
- Display only: a record is evidence, never authority (`#aidevops:trust-boundary` comment). The helper stays read-only toward GitHub.

### Files Scope

- `.agents/scripts/maintainer-decisions-helper.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/maintainer-decisions-helper.sh` is clean; `pipe-early-exit-check.sh --scan-files --diff-base origin/main` reports no violations.
- Synthetic classifier input: with no record, a `status:blocked` + `needs-ai-recovery` issue with no canonical ask is filtered out. With a standing `human_decision` record it is `decide`, with `next_action` as the question. With a newer plain OWNER reply it is `replied`. A `brief_revision` record or a corrupt file yields `null`.
- A live `list --repo <repo>` on an affected repository shows the previously hidden hold as `decide`.

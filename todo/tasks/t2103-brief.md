<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2103: Pre-dispatch no-op validator for auto-generated issues

## Origin

- **Created:** 2026-04-15
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** t2100 / #19035
- **Conversation context:** Fix 3 of the #19024 post-mortem — the defense-in-depth layer. Fixes 1 and 2 (#19036, #19037) eliminate the ratchet-down bug at the source; this fix adds a generalisable safety net that catches the same class of failure for any future auto-generated issue type.

## What

New helper `pre-dispatch-validator-helper.sh` with a `validate <issue-number> <slug>` subcommand. Before the pulse spawns a worker for an auto-generated issue, this runs a registered validator for that issue's generator type in a fresh checkout. Exit codes:

- `0` = dispatch proceeds
- `10` = premise falsified, caller closes the issue with a rationale comment instead of dispatching
- `20` = validator error, dispatch proceeds with a warning log

First concrete validator: **ratchet-down**. Runs `complexity-scan-helper.sh ratchet-check . 5` in a fresh clone and returns exit 10 if it reports "No ratchet-down available".

Generator identification uses a hidden body marker `<!-- aidevops:generator=ratchet-down -->` that the issue generator in `_complexity_scan_ratchet_check` must emit. Generator-marker extraction is safer than parsing titles or labels.

## Why

The #19024 worker silently exited despite the explicit "Worker triage responsibility" prompt rule. Prompt-following failures cannot be robustly fixed with more prompt text. Moving the no-op check before dispatch makes it deterministic — the pulse doesn't rely on the model.

Once ratchet-down is in place, the mechanism extends to quality-debt, review-followup, and contribution-watch generators as separate follow-ups. The extensibility pattern is "one validator script per generator, registered at startup", not "extract commands from issue bodies".

## Tier

**tier:standard** — new helper + new mechanism + new test harness + dispatch-engine integration. Requires research to identify the right dispatch hook point. ~2-3h estimate. Not tier:simple because it touches multiple files and introduces a new abstraction.

## Reference

- Parent: #19035
- Incident: #19024
- Full design, file list, research steps, and acceptance criteria in the GitHub issue body at **#19038**
- Worker prompt rule that was ignored: `prompts/build.txt` "Worker triage responsibility (GH#18538)"

## Acceptance

- `pre-dispatch-validator-helper.sh` helper with `validate` subcommand
- Ratchet-down validator registered and tested (falsified and legitimate cases)
- Dispatch entry-point calls validator after dedup, before worker spawn
- Generator marker `<!-- aidevops:generator=ratchet-down -->` emitted by `_complexity_scan_ratchet_check`
- Exit 10 triggers issue closure with rationale + signature footer
- Emergency bypass env var `AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1`
- Documentation: `reference/pre-dispatch-validators.md`
- Test coverage: ratchet-down falsified, ratchet-down legitimate, unregistered generator fallback
- No regression on legitimate ratchet-down dispatches

## Non-goals

- Don't implement validators for other generator types in this issue
- Don't extract commands from issue bodies at runtime (injection surface)
- Don't block dispatch on validator errors (log and proceed)

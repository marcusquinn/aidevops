# t19210: fix(terminal-blocker): external_trigger_pending holds publish dependency guidance that names a nonexistent linked blocker

Issue: GH#39482 (the issue body is canonical; this is a backup).

## What

An `external_trigger_pending` hold publishes `Unblock label: needs-dependency` with the dependency guidance ("the linked blocking issue must close ... the dependency pass removes status:blocked"). There is no linked blocker. The trigger-revisit pass or an OWNER/MEMBER retry directive clears the hold. Publish reason-accurate guidance.

## How

1. `.agents/scripts/shared-gh-wrappers-status.sh` `blocked_companion_guidance`: take an optional reason argument and print trigger guidance for `needs-dependency` + `external_trigger_pending`.
2. `.agents/scripts/terminal-blocker-circuit.sh` (around line 1187): pass the reason.
3. `.agents/scripts/approval-snapshot-v2.sh` (around lines 146–157): accept the new text for `external_trigger_pending` and keep accepting the old text.

### Files Scope

- `.agents/scripts/shared-gh-wrappers-status.sh`
- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/approval-snapshot-v2.sh`
- `.agents/scripts/tests/test-approval-helper-content-binding.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`

## Verification

- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` and `bash .agents/scripts/tests/test-approval-helper-content-binding.sh` pass.
- `shellcheck` is clean on the changed scripts.

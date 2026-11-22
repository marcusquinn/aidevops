## What

Add `aidevops repos checkpoint-policy <on|off> [slug-or-path] [--owner OWNER]`. It sets or clears `checkpoint_policy.auto_resolve_decisions` (GH#38155) and `checkpoint_policy.auto_continue_unknown_pending_work` (GH#36525) together, with `configured_by` set to the current `gh` login. Show the policy state in `aidevops repos list`.

## Why

Both AI-resolution policies are opt-in per repo. The only enable path is hand-editing `~/.config/aidevops/repos.json`, as described in `.agents/reference/checkpoint-revision-recovery.md`.

- On 2026-11-15, 0 of 70 pulse-enabled repos on the maintainer's runner had either policy.
- Every decision-blocked or unknown-blocked worker draft therefore waited for a human: 25 open `blocked_by=decision` issues in one repo alone, and about 27 drafts with `BLOCKED_CHECKPOINT_ATTENTION` in `pulse.log`.
- Enabling the policies for 25 personal repos needed a one-off Python script. Other operators will never discover the key.

## How

1. `.agents/scripts/aidevops-cli/aidevops-repos-lib.sh`: add `set_repo_checkpoint_policy SELECTOR on|off`, modelled on `set_repo_pulse` (line 777). Use the same selector resolution and atomic jq write, and preserve other `checkpoint_policy` keys.
   - `on` requires `gh api repos/SLUG --jq .permissions.push` to be true for the current login; it sets both keys and `configured_by`.
   - `off` sets both keys false.
   - `--owner OWNER` applies to every pulse-enabled repo with that owner prefix and reports changed/skipped counts.
2. `aidevops.sh`: add the `checkpoint-policy)` case in `cmd_repos` beside `pulse)` (around line 1069), with a `_repos_checkpoint_policy` wrapper mirroring `_repos_pulse` (line 976) and a usage line.
3. `.agents/reference/checkpoint-revision-recovery.md`: replace the hand-edit instruction with the command, and keep the JSON as the stored shape.

### Files Scope

- aidevops.sh
- .agents/scripts/aidevops-cli/aidevops-repos-lib.sh
- .agents/reference/checkpoint-revision-recovery.md
- TODO.md
- todo/tasks/t19042-brief.md

## Acceptance

- `aidevops repos checkpoint-policy on owner/repo` makes `_pcc_decision_policy owner/repo` (`pr-checkpoint-decision-resolver.sh:85`) succeed. It does the same for the unknown-digest policy reader (`pr-checkpoint-unknown-digest.sh:42`).
- `off` disables both. Other repos.json keys and entries are unchanged; the file stays mode 600.
- Without push permission, `on` refuses with a clear error.

## Verification

- Run against a temp copy of the registry (`REPOS_FILE` / `AIDEVOPS_REPOS_JSON`): on, off, `--owner`, and a no-permission case.
- `shellcheck aidevops.sh .agents/scripts/aidevops-cli/aidevops-repos-lib.sh`.

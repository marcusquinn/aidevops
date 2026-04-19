# t2404: Add loginctl enable-linger guidance for Linux systemd auto-update

## Session origin

- Date: 2026-04-19
- Context: Interactive audit of Linux auto-update paths (see also t2403). User framed: "interesting that Linux users might not have auto-update running, so worth a look at if there's anything broken in aidevops that might prevent that." This is the highest-severity finding of the audit.
- Sibling: t2403 (systemd status/docs visibility — prerequisite-adjacent, not blocking).

## Why

`_cmd_enable_systemd` at `.agents/scripts/auto-update-helper.sh:1634-1691` installs a systemd **user** timer via `systemctl --user enable --now aidevops-auto-update.timer`. Without `loginctl enable-linger $USER`, the systemd user manager stops when the last session for the user ends. When it stops, every user timer — including the auto-update timer — stops firing.

Concrete failure mode on a server / headless Linux deployment:

1. Operator SSHs in, runs `aidevops auto-update enable` → success, timer enabled.
2. Operator logs out.
3. systemd user manager reaps (default: `logind.conf KillUserProcesses=yes` on some distros, or simply no active session to keep it alive).
4. Next pulse-update-check window: no update fires. Framework silently drifts.
5. Operator comes back days later, sees an outdated version with no indication why.

No grep hit for `loginctl` / `enable-linger` in the entire framework (verified: `rg -n 'loginctl|enable-linger|linger' ~/Git/aidevops/.agents/` returns 4 matches, all in `screen-time-helper.sh` for session duration estimation, none in auto-update or setup).

The framework advertises headless Linux / WSL2 / server support but the auto-update path has no mechanism to survive logout on those hosts.

## What

Close the linger gap in three places, ordered by visibility:

1. **Runtime notice** in `_cmd_enable_systemd`: after successful timer enable, check `loginctl show-user "$USER" -p Linger --value` and if `no`, print an end-of-output notice explaining what linger does and how to enable it. Non-interactive setup must still succeed — print the notice on stderr and exit 0.
2. **Interactive auto-enable prompt** in `setup-modules/post-setup.sh setup_auto_update`: when `PLATFORM_LINUX=true` and `NON_INTERACTIVE=false` and the backend resolves to systemd, after enabling the timer, prompt: "Enable linger so auto-update runs when you're logged out? Requires sudo. [Y/n]". On yes, run `sudo loginctl enable-linger "$USER"`. On no, print the manual command.
3. **Reference doc** in `.agents/reference/auto-update.md`: a "Linux systemd: logout persistence" subsection explaining linger, when you need it (always, on a server), when you don't (laptop with always-on session), and the one-liner.

Do **not** auto-enable linger in the non-interactive path — it requires root and silently running sudo is a surprise.

## How

### Files to modify

- **EDIT**: `.agents/scripts/auto-update-helper.sh`
  - After line 1688 (inside `_cmd_enable_systemd`, before `return 0`): add a linger check block. Model on the existing "Disable with:" / "Check now:" status echo pattern — print an aligned block. Query: `loginctl show-user "$USER" -p Linger --value 2>/dev/null`. Output in YELLOW when linger is `no`, with the remediation command.
  - `cmd_help` SCHEDULER BACKENDS section (edited by t2403): add one line: "Linux systemd requires `loginctl enable-linger $USER` to run when logged out. See 'aidevops auto-update status' for current state."
  - `_cmd_status_scheduler` systemd branch (added by t2403): include a "Linger: yes|no" row parallel to the Status/Unit/Interval rows. When `no`, print the remediation command inline.

- **EDIT**: `setup-modules/post-setup.sh`
  - `setup_auto_update` (line 17-54): after `bash "$auto_update_script" enable` in the interactive branch (line 47), if `$(uname -s) == "Linux"` and `systemctl --user is-enabled aidevops-auto-update.timer` is enabled, check linger state. Prompt and run `sudo loginctl enable-linger "$USER"` on Y. Skip entirely in `NON_INTERACTIVE=true`.

- **EDIT**: `.agents/reference/auto-update.md`
  - Add a "Linux systemd: logout persistence (linger)" subsection between the existing "Scheduler" and "Disable" lines. ~5 lines explaining the behaviour and the remediation command.

### Reference patterns

- Linger state read: `loginctl show-user "$USER" -p Linger --value` — returns `yes` or `no`. Available on any `systemd-logind`-running host.
- Interactive prompt style: model on `setup_prompt enable_auto` at `setup-modules/post-setup.sh:45` — same function handles Y/n default gracefully.
- NON_INTERACTIVE gate: the existing `if [[ "$NON_INTERACTIVE" == "true" ]]` pattern at line 36 is the exact idiom to reuse.

### Edge cases to handle

- Containers without `systemd-logind` (Docker minimal images): `loginctl` command fails. Fall back to printing a generic info message, don't crash the enable flow.
- Root-owned setup (rare): `$USER == root` has linger irrelevant for root — skip the prompt entirely.
- WSL2 with systemd opt-in enabled but logind stub: `loginctl show-user` may return blank or error. Treat as "unknown — print generic remediation message".

## Acceptance criteria

- [ ] `_cmd_enable_systemd` prints a linger-status notice on enable (YELLOW when `no`, just-informational when `yes`).
- [ ] Status output (from t2403 systemd branch) includes a "Linger: yes|no" row.
- [ ] Help text mentions linger requirement.
- [ ] `setup_auto_update` interactive path prompts for linger on Linux systemd hosts and runs `sudo loginctl enable-linger` on yes.
- [ ] `setup_auto_update` non-interactive path prints the manual `loginctl enable-linger` command to stderr but does NOT run sudo automatically.
- [ ] `.agents/reference/auto-update.md` has a dedicated linger subsection.
- [ ] Container-without-logind path doesn't crash: `loginctl` absent → clean info message.
- [ ] `shellcheck` clean on both modified scripts.
- [ ] macOS setup path unchanged (tested by `bash setup.sh --non-interactive` on macOS).

## Context

- Root cause: framework was built macOS-first. Linux scheduler abstraction (t1219, platform-detect.sh, t1748) landed later but never closed the "user vs system timer" logout gap.
- NOT required: switch to a system-level systemd unit. User timer + linger is the idiomatic choice — system units would require `sudo` for every enable/disable and drag in root-owned state files. Design decision deliberately preserves current architecture.
- Tier: `tier:standard` — two file edits but one is a UX-with-sudo decision that disqualifies `tier:simple` (judgment keyword: "prompt", sudo invocation, conditional behaviour based on env).
- This is THE most likely cause of a Linux user's auto-update silently not running. Higher severity than t2403.

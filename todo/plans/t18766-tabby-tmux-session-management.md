<!-- SPDX-License-Identifier: MIT -->

# t18766: Multi-host Tabby and tmux session management

## Status and ownership

- Created: 2026-10-23.
- This task delivers the implementation specification and a sanitized prototype, not production functionality.
- Implementation will be tracked separately after this specification merges. It is a manual assignee-owned task: do not auto-dispatch it from this document.
- The combined `opencode-tab.sh` is the sole prototype reference for both `new` and `restore`.
- Suggested implementation tier: standard. This is stateful cross-platform coordination, not an exact mechanical script copy.
- No implementation PR has been seeded. Existing profile-sync functionality must remain unchanged.

## Pre-flight evidence

- [x] Memory recall for Tabby/tmux, multi-host restore, duplicate tabs, and launcher integration returned no relevant stored lessons.
- [x] Collision discovery against the Tabby helper, terminal-title documentation, and CLI entry point returned three recent related commits and no related merged/open PR or claimed-issue entries. Refresh before implementation; this is not a guarantee against concurrent work.
- [x] Existing integration files were verified in aidevops source at `bc8bc3b80460d2ab23781dd7493dc41c8462b3ae`; publication work was then based on `e01861a9c`. The initial inspected files had no local changes.
- [x] Prototype Bash syntax, ShellCheck, isolated lock lifecycle checks, and mocked restore ordering/deduplication passed. Latest fixes are not yet confirmed end-to-end on both client platforms.
- [x] Private host addresses, names, usernames, and identity-file paths were removed before publication. The prototype defaults to OpenSSH configuration/agent authentication and generic aliases only.

## What

Add native aidevops commands to create and restore interactive remote tmux sessions as separate Tabby tabs across configured SSH hosts. A user should switch between Linux and macOS laptops without restarting remote OpenCode processes.

Use one shared backend for creation and restoration. If an `opencode-tab.sh` compatibility wrapper is useful, make it thin and explicitly installed. Local attachment tracking must not prevent another laptop from attaching to the same remote session.

## Why

The original workflow has approximately 10-15 changing terminals, often multiple OpenCode sessions in the same project. Static project profiles do not represent this workload. The prototype demonstrates multiple hosts, session numbering, local duplicate prevention, launch ordering, and forwarding of dynamic OpenCode titles.

Replace hardcoded connection details and ad hoc scripts with supported framework tooling, without conflating profile reconciliation with live tab/connection management.

## Reference artifact and existing capabilities

The reviewed, sanitized reference is [the research prototype](../research/t18766-opencode-tab-prototype.sh). It is not installed framework code or a completed implementation. Its unresolved limitations below are intentional handoff evidence, not guarantees.

| Verified file | Reuse or preserve |
| --- | --- |
| `aidevops.sh` | Tabby CLI help/dispatch; it delegates to `tabby-helper.sh`. |
| `.agents/scripts/tabby-helper.sh` | Existing `sync`, `status`, `zshrc`, `fix-shell`, help, platform-aware config discovery, and isolated Python environment selection. |
| `.agents/scripts/tabby-profile-sync.py` | Managed local-profile reconciliation. Duplicate profiles are not duplicate live tabs. |
| `.agents/scripts/tabby-python-lib.sh` | Inspect existing dependency selection before adding a runtime requirement. |
| `.agents/scripts/shared-constants.sh` | Shared shell constants and conventions. |
| `.agents/scripts/terminal-title-helper.sh` | OSC title integration; do not add a competing writer. |
| `.agents/tools/terminal/terminal-title.md` | OpenCode status/title ownership and tmux forwarding. |
| `.agents/tools/terminal/terminal-optimization.md` | Existing basic tmux guidance. |
| `.agents/scripts/tests/test-tabby-profile-sync.sh` | Existing shell test conventions and regression entry point. |
| `tests/test-tabby-profile-sync.py` | Existing Tabby Python regression coverage. |

## User-facing contract

Proposed namespace under the existing Tabby commands:

```text
aidevops tabby sessions new <host-id>
aidevops tabby sessions restore [host-id]
aidevops tabby sessions list [host-id]
aidevops tabby sessions doctor [host-id]
```

- `new`: create the next detached numbered tmux session, then request a tab attached to it. Default to a normal shell, not an automatic OpenCode launch.
- `restore <host-id>`: request only missing local attachments for that host.
- `restore`: process all enabled hosts in configured order. Attempt remaining hosts after a failure and return nonzero if any host fails.
- `list`: display matching remote sessions and locally observed attachment/pending state without opening tabs.
- `doctor`: report local configuration, dependencies, CLI compatibility, and state-directory problems. Remote probes must be explicit and non-mutating.
- Provide a dry run that changes neither sessions nor reservations. Preserve all existing profile commands, especially `aidevops tabby status`.

## Configuration

Proposed user-owned configuration: `~/.config/aidevops/tabby-hosts.json`, with a documented test/alternate-location override. Do not use `repos.json` as remote session inventory.

```json
{
  "version": 1,
  "hosts": [
    {
      "id": "alpha",
      "sshHost": "dev-alpha",
      "titlePrefix": "A",
      "restoreOrder": 10,
      "sessionPrefix": "oc-",
      "connectIntervalSeconds": 5,
      "enabled": true
    },
    {
      "id": "beta",
      "sshHost": "dev-beta",
      "titlePrefix": "B",
      "restoreOrder": 20,
      "sessionPrefix": "oc-",
      "connectIntervalSeconds": 5,
      "enabled": true
    }
  ]
}
```

Prefer OpenSSH aliases so endpoint, port, username, agent, identity selection, and proxy settings remain in each laptop's private SSH configuration. Support validated explicit connection options for migration, but never ship actual deployment details or personal identity paths. Reject ambiguous alias/explicit combinations, option-like host values, and arbitrary shell hooks. Never store private key material, passwords, cookies, or authentication tokens in config/state.

## Required behavior

### Creation and persistence

1. Number independently per host: `oc-001` plus `oc-009` produces `oc-010`; no matching sessions produces `oc-001`.
2. Reserve names by actual atomic tmux creation. Concurrent `new` calls either create distinct names or report a retryable collision; never silently reuse an existing session.
3. Keep a newly created detached session if Tabby fails or is cancelled; report its identity and recovery command.
4. Select only the configured prefix, excluding unrelated worker/server/test sessions.
5. Closing a local tab must not kill remote tmux/OpenCode. Reconnection is not reboot resurrection: restarting the remote server loses live processes; resuming a stored OpenCode conversation is separate.

### Duplicate prevention

1. Deduplicate within the local client account by endpoint and stable session identity, not global tmux attachment count. Both laptops may attach simultaneously.
2. Recognize supported legacy direct-SSH attachments locally. Never inspect other users' processes or print unrelated process arguments.
3. Reserve before asking Tabby to open a tab; hand off pending-to-active ownership atomically. Use OS-backed locking, not marker-file existence alone. Reject outdated launch identifiers.
4. Recover after disconnect, failed SSH, tab closure, cancellation, and stale pending state. Never unlink a live lock inode. Validate ownership and PID reuse if process identities are used.
5. Define session-rename and equivalent-endpoint-alias behavior; these must not silently create duplicates.
6. Report requested, connected, pending, skipped, and failed actions separately. A CLI request is not evidence of Run approval or successful authentication.

The prototype uses Perl `flock`, local process matching, and a 120-second pending reservation. A still-open Tabby confirmation can outlive that timeout. Document this limitation or resolve it with verified completion evidence; do not claim perfect tab-level idempotency from lock tests alone.

### Tabby transport, ordering, and authentication pacing

1. Discover the executable on Linux/macOS, including the macOS bundle when absent from PATH.
2. Preserve argv across Tabby, the wrapper, SSH, and the remote shell. Test spaces and metacharacters; safely handle or reject unsupported names before launch. Never use `eval`.
3. The tested prototype uses repeated `--command=...` arguments. Bare `run -- ...` did not populate the command array in the inspected parser configuration; verify actual installed/versioned behavior instead of guessing equivalent CLI forms.
4. Tabby 1.0.235 exhibited `mixin.stripAnsi is not a function`. Diagnose broken/unsupported CLI versions rather than modifying application archives. Upstream evidence: https://github.com/Eugeny/tabby/issues/11658 and https://github.com/Eugeny/tabby/pull/11513.
5. Respect Run/Cancel confirmations. Support one window initially: the inspected handler routes to the last-created window, not a verified selectable window ID.
6. Request tabs by configured host order, numeric suffix, then alphabetic named sessions. `oc-2` precedes `oc-10`. Do not close or move existing tabs for sorting or move tabs whenever task/status titles change.
7. Pace new authentications and bound retries. A real server log showed per-source unauthenticated connection limiting and MaxStartups drops. A five-second pause is only a fallback, not proof that authentication finished. Do not weaken server SSH limits.

### Titles and clipboard

- Forward active pane titles with compact prefixes such as `A001 <status/title>`, falling back to the command when empty.
- Reuse aidevops/OpenCode status-title ownership; do not add another competing OSC writer.
- Document tmux `set-titles`, `set-titles-string`, and Tabby's dynamic-title permission.
- The observed OpenCode clipboard path required `set-clipboard on`; `external` allowed tmux copying but not the application's request. Explain the clipboard-write permission trade-off.
- Never silently edit remote `.tmux.conf`, enable clipboard access, restart tmux, or kill sessions. Offer reviewed snippets or an explicit setup action.

## How (Approach)

### Files to Modify

- `aidevops.sh`: CLI help; preserve the existing helper dispatch.
- `.agents/scripts/tabby-helper.sh`: route a new `sessions` namespace without changing profile commands.
- `.agents/tools/terminal/terminal-title.md`: link the new capability and title/clipboard boundaries.
- Run the existing Tabby tests above as regressions; change them only where dispatch/help contracts require it.

Proposed new files, not claims of existing interfaces:

- `.agents/scripts/tabby-session-helper.sh`: backend; use narrowly scoped config/locking/transport modules as needed.
- `.agents/configs/tabby-hosts.example.json`: versioned sanitized example.
- `.agents/tools/terminal/remote-sessions.md`: setup, migration, commands, recovery, limitations.
- `.agents/scripts/tests/test-tabby-session-helper.sh`: focused tests in the existing shell infrastructure; an existing-style Python module is acceptable if implementation uses Python.

### Complete Write Surface

Implement in source, never deployed installed copies. Discover exact installer manifests, config examples, and documentation indexes before editing; their additional paths are not yet known. Do not change application repositories, real server inventory, or user SSH configuration.

### Implementation Steps

1. Refresh discovery and repository guidance in a linked worktree; inspect the prototype and current CLI/test conventions.
2. Add validated configuration and deterministic session planning/reporting.
3. Implement enumeration/creation, local pending-to-active coordination, supported legacy detection, and bounded recovery.
4. Add the verified Tabby transport adapter and compatibility diagnostics. Do not opportunistically install dependencies during restore.
5. Wire dispatch, help, example config, and migration documentation. Keep any compatibility wrapper thin and optional.
6. Add focused regressions and perform real interactive Linux/macOS verification before claiming support.

### Hazards and Compatibility

- Support Linux and macOS, including Bash 3.2 where applicable. Avoid GNU-only sort, `readlink -f`, associative arrays, or `/proc` without portable alternatives.
- Inspect existing interpreter/environment selection. Do not assume Python, Perl, Homebrew, Tabby, or remote tmux is installed; distinguish local and remote requirements.
- Preserve host verification, passphrases, authentication, and MFA. Never disable host checking, inject broad secrets, reset credentials, or log environments.
- Protect local state from symlinks/ownership abuse. Config edits and failures are recovery cases, not authority to kill remote work.

### Verification Before Dispatch

Refresh upstream collision checks and current source paths before implementation. Reference tests are isolated/mocked, not proof of live client support. Use the existing shell/Python test framework; no new CI service, test runner, or live-host fixture is needed. Smoke checks must use separately authorized non-sensitive sessions, not ongoing user work.

## Acceptance criteria

- [ ] Existing Tabby profile commands retain their behavior.
- [ ] `new` correctly numbers and creates sessions without starting duplicate OpenCode processes.
- [ ] Restore handles all enabled hosts, continues after per-host failures, and reports aggregate failure accurately.
- [ ] Repeated restore requests zero extra tabs for connected/pending sessions; concurrent restore does not produce duplicate active attachments. Pending UI limits are demonstrated and documented.
- [ ] Supported legacy attachments are recognized locally without blocking another laptop.
- [ ] Disconnect/failure/closure permits reopening; stale state recovers; outdated launch identifiers cannot attach after reassignment.
- [ ] Renames and equivalent endpoint aliases have tested, documented behavior.
- [ ] Empty state, missing tmux/identity files, invalid config, and broken CLI produce distinct results/errors.
- [ ] Natural ordering and service exclusion are tested; existing tabs are never closed for ordering.
- [ ] Paths with spaces and unsafe input are handled safely or explicitly rejected before launch.
- [ ] No personal connection details or credential material enter source, tests, issue bodies, or logs; SSH safeguards stay enabled.
- [ ] Dynamic titles reuse existing status integration; clipboard setup is opt-in and documented.
- [ ] Linux/macOS smoke checks prove real attached clients, persistence after tab closure, and repeat-restore behavior with confirmations accounted for.

## Verification commands and delivery evidence

Using final filenames and the repository's required interpreter/environment:

```bash
bash -n .agents/scripts/tabby-helper.sh
bash -n .agents/scripts/tabby-session-helper.sh
shellcheck .agents/scripts/tabby-helper.sh .agents/scripts/tabby-session-helper.sh
bash .agents/scripts/tests/test-tabby-session-helper.sh
bash .agents/scripts/tests/test-tabby-profile-sync.sh
python3 tests/test-tabby-profile-sync.py
```

The session-helper commands are proposed deliverables, not existing commands. Inspect existing tests' interpreter/PyYAML requirements first; reuse the environment selector. Apply other required gates to the affected scope rather than using an unbounded full-suite run as generic proof.

Deliver the implementation PR, focused results, client/Tabby/tmux versions, sanitized summaries, known limits, migration, and rollback. Do not publish authentication logs or terminal contents.

## Non-goals and rollback

- No GUI reordering, automatic per-host windows, OpenCode conversation migration, reboot resurrection, daemon, background SSH keeper, or automatic package installation.
- No destructive cleanup of unrelated tabs, tmux sessions, control sockets, or live locks.
- Roll back the new namespace/helper and inactive owned state only. Keep remote work and profile commands intact; direct SSH/tmux and the retained prototype remain fallback options.

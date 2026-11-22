---
description: Multi-host remote tmux sessions in Tabby, with local attachment leases
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Remote Tabby sessions

Create persistent remote shells and restore their Tabby attachments without
starting OpenCode automatically. Existing `tabby sync`, `status`, `zshrc`, and
`fix-shell` still manage profiles; they do not manage these connections.

## Setup and commands

Register an existing SSH alias with `aidevops tabby sessions host add dev-alpha`,
or create an aidevops-managed alias using the host commands below. The inventory
defaults to `~/.config/aidevops/tabby-hosts.json`. Alternatively, copy the generic
`configs/tabby-hosts.example.json` from the installed agents tree. Keep real
connection details in private OpenSSH configuration; do not put real endpoints,
usernames, keys, or authentication logs in project files or reports. No command
installs packages or weakens SSH host-key verification. Selecting an identity file
for a managed alias can change which keys SSH offers, but never changes key
material. All hosts default to enabled.

```bash
aidevops tabby sessions doctor
aidevops tabby sessions doctor alpha --remote
aidevops tabby sessions new alpha
aidevops tabby sessions restore
aidevops tabby sessions restore beta --dry-run
aidevops tabby sessions list
```

### Managing configured hosts

```bash
# Register an existing alias; no remote connection.
aidevops tabby sessions host add alpha --ssh-host dev-alpha

# Create an SSH alias and register it (replace these generic values).
aidevops tabby sessions host add beta --hostname server.example.invalid \
  --user developer --port 22 --identity-file ~/.ssh/id_ed25519

aidevops tabby sessions host list
aidevops tabby sessions host show beta
aidevops tabby sessions host update beta --session-prefix oc- --title-prefix B
aidevops tabby sessions host update beta --hostname replacement.example.invalid
aidevops tabby sessions host update beta --disabled
aidevops tabby sessions host update beta --enabled --connect-interval 5 --restore-order 20

# Use only configured identities, instead of offering unrelated SSH agent keys.
aidevops tabby sessions host update beta --identities-only
# Explicitly allow normal agent-key selection again.
aidevops tabby sessions host update beta --no-identities-only

# Keep the SSH alias, or explicitly remove the managed SSH alias too.
aidevops tabby sessions host remove alpha
aidevops tabby sessions host remove beta --ssh --dry-run
```

`sessions list` lists remote tmux sessions. `sessions host list/show` inspect
local inventory, including disabled hosts; they do not launch Tabby. `add`
creates an inventory when needed and defaults to prefix `oc-`, title prefix equal
to the host ID, and a five-second launch interval. Empty title prefixes are invalid.
`update` changes only supplied fields. `--ssh-host` is add-only; remove and add
the inventory entry to change its alias mapping. Registration of an existing
alias checks local `ssh -G` resolution; this is not proof of network reachability
or authentication, and existing OpenSSH `Match exec` rules still apply.

`--identity-file` also defaults the inventory's `identitiesOnly` setting to true,
matching direct SSH with `-i KEY -o IdentitiesOnly=yes`. Override this with
`--no-identities-only` in the same command when other agent identities are needed.
`--identities-only` can also be set on existing/user-owned aliases without editing
their SSH configuration; it uses that alias's configured identity files. It does
not select a key by itself. Aliases without either an explicit identity override
or an `identitiesOnly` setting retain their existing OpenSSH identity selection.

Host commands print the selected inventory path. `--config` overrides
`AIDEVOPS_TABBY_HOSTS`, which overrides the default. Writes to temporary inventory
paths are refused: unset a stale smoke-test override or pass a durable `--config`.
`--allow-temporary-config` is an explicit testing escape hatch. Every modifying
host command supports `--dry-run`, which creates no files, directories, backups,
locks, tabs, or sessions.

New SSH aliases live in `~/.ssh/aidevops.conf`, referenced by a leading `Include`
in `~/.ssh/config`. The generated file contains ownership metadata and is edited
only through these commands; external modifications cause SSH writes to fail
closed. Existing user-owned alias blocks (including matching patterns and local
Includes) are never edited or adopted. Global `Host *` and `Match all` defaults
remain supported. Conditional `Match` rules are not evaluated or executed during
SSH ownership checks: SSH changes refuse them, including rules found in Includes.
Dynamic Includes and conflicting aliases also require manual configuration. Register
user-owned aliases without SSH options, then use inventory-only updates. Legacy
inventory SSH overrides must be migrated manually before managing an alias.
An already-managed alias can be registered by another host ID without SSH options;
`add` with SSH options refuses to overwrite it. Use `update` for intentional changes.

Writes reject symlink paths, hardlinked/non-owned files, and group/world-writable
configuration files. New/replaced files and timestamped backups are private (0600).
Backups are stored outside SSH Include globs under
`~/.local/state/aidevops/tabby-host-config/backups/`; each write reports its backup
path. Permanent `.aidevops-tabby-hosts.lock` files serialize cooperating
writers. A busy lock fails immediately with a retry message, rather than waiting
indefinitely; do not delete lock files while commands run. Individual file replacements are
atomic, but the multi-file operation is not: failed writes attempt rollback and
report an incomplete rollback explicitly. Backups are retained privately. The
managed Include and empty managed file remain after the last alias is removed.

`remove` changes only inventory unless `--ssh` is supplied. SSH deletion requires
an aidevops-managed alias without another reference in the selected inventory;
other inventory files cannot be checked automatically. No operation deletes keys,
known-host entries, attachment leases, remote sessions, or tabs. Endpoint updates
leave existing tabs on the original endpoint: use fresh `list`/`restore` afterward.
These commands do not remove Tabby's Run/Cancel confirmation.

Requirements: Python 3.9+ (standard library only), OpenSSH with `-G`, local `ps`,
Tabby with the repeated `run --command=<argument>` array interface, and remote
tmux. The Bash launcher uses Bash 3.2-compatible syntax. It first reuses the
existing Tabby Python selector, then falls back to `python3` without requiring
PyYAML or preparing a virtualenv. Linux PATH and both system/user macOS app
bundles are searched. `AIDEVOPS_TABBY_BIN` selects an alternate executable.

Inventory/creation probes use `BatchMode=yes`, a 15-second connection timeout,
and a 45-second bound per attempt. Read-only inventory probes retry transient
connection resets, closures, timeouts, and channel refusals up to four attempts,
waiting 2, 4, then 8 seconds (at most 194 seconds including probe timeouts).
Authentication,
host-key, tmux, and malformed-response failures are not retried. Creation commands
are never retried after an uncertain transport failure. Errors report sanitized
failure categories, not raw SSH logs. Persistent connection/channel failures need
private inspection of SSH server connection limits or multiplexing; retries cannot
override those limits. Prepare your SSH agent, MFA-authenticated control
connection, or other private OpenSSH authentication first. Interactive tabs
retain normal SSH authentication, host-key prompts, and MFA; probes never
collect or print authentication diagnostics. `doctor` normally uses only local
`ssh -G`; `--remote` explicitly permits a read-only remote probe. OpenSSH's own
locally configured `Match exec` behavior still applies to `-G`.

Restore inventories each host once before launching its tabs. Managed tabs then
connect directly with interactive SSH, without a second non-interactive inventory
probe per tab. Stable-ID leases prevent duplicate managed attachments, and the
final tmux command still checks session ID, creation time, server PID, and prefix
on the server before attaching. If local legacy direct-SSH attachments are found,
the tab still requires fresh inventory to resolve legacy names and ambiguity;
that read-only probe uses the same retry policy. Initial inventory remains
non-interactive, so prepare authentication before running restore.

Probe stdout uses unique per-request response boundaries. SSH/login-shell output
outside those boundaries is excluded privately; unexpected records inside the
inventory remain errors. Missing/duplicate boundaries fail closed rather than
being mistaken for an empty inventory. Neither startup text nor authentication
diagnostics are printed or persisted. No shell configuration changes are needed.

Inventory records use a printable pipe delimiter rather than literal tabs, with
strict field validation. Managed names cannot contain pipes; unrelated names
retain their full value for prefix filtering, rather than being truncated.

`AIDEVOPS_TABBY_HOSTS` / `--config` and `AIDEVOPS_TABBY_STATE_DIR` / `--state-dir`
select alternate inventory/state locations, including paths with spaces or
shell metacharacters. Dry runs read inventory but create no remote sessions,
local reservations, directories, or tabs. `list` does not open tabs or create
state. Restore orders hosts by `restoreOrder`, preserving inventory order for
ties, then numeric suffix (`oc-2` before `oc-10`), then named suffix alphabetically.
Only `sessionPrefix` sessions are selected; existing tabs are never moved/closed.
Each host failure is reported, remaining hosts are attempted, and any failure
makes the aggregate exit status nonzero.

Optional migration fields are `port`, `user`, and `identityFile`; use them only
in private inventory. They override the corresponding alias values with fixed
OpenSSH argv options. `sshHost` must remain an alias (no `user@host`, option-like
values, arbitrary `sshOptions`, or shell hooks). An unavailable explicit identity
is a distinct error. Moving these settings into OpenSSH is preferred.

## Creation, leases, and recovery

`new` enumerates matching numeric names and creates the next detached tmux
session atomically. A collision retries against fresh inventory, at most five
times. It never silently reuses a colliding name. Local launch failure does not
delete remote work: use `aidevops tabby sessions list alpha`, then `restore alpha`.
Closing a tab disconnects SSH; remote tmux and OpenCode remain running. A remote
reboot is different: this feature does not resurrect processes or resume stored
OpenCode conversations. Server-side policies such as `destroy-unattached` or
login-session cleanup can defeat persistence; review them separately, never
change them automatically.

State defaults to `~/.local/state/aidevops/tabby-sessions` on both platforms.
It must be owned by the local account and mode 0700. Symlink paths/lock files,
non-private files, and hardlinked lock files are rejected. Lock filenames hash
the resolved endpoint and stable tmux identity (session ID, creation time, server
PID), not display names. State contains only launch nonces, expiry/phase, and
the remote tmux client PID; no credentials, connection settings, or process
arguments. Lock inodes are permanent: **never delete a live lock or directory**.
The OS releases an active lease on disconnect/process exit. OpenSSH closes extra
inherited file descriptors, so after supervisor death recovery also checks for
the exact random launch nonce in current-account managed SSH/wrapper arguments.
It never trusts a reusable numeric local PID or publishes those arguments. If
process inspection fails, recovery fails closed instead of launching a duplicate.

Unreadable metadata in an unlocked, nonempty lease also refuses a new launch:
it cannot establish whether an orphaned attachment remains. Preserve the state
and investigate privately; do not delete lock files or overwrite their contents
to force a restore. A busy lock remains `pending` while metadata may be mid-write.

States are deliberately distinct:

- `created`: detached remote session exists; no local attachment guarantee.
- `requested`: Tabby's CLI accepted the request, not proof of Run/authentication.
- `pending`: a 120-second launch reservation, or a live wrapper/SSH transport
  without verified remote tmux attachment.
- `connected`: a live local lease/nonce's observed remote PID matches tmux's
  `list-clients` entry for that stable session ID at the latest inventory probe.
- `skipped`: no new request; the reason identifies pending/connected/legacy work.
- `failed`: remote/config/local/launch failure, not an empty inventory.
- `missing`: no current local attachment lease or unexpired reservation.

Run/Cancel confirmations remain Tabby's responsibility. Cancellation cannot be
observed before the wrapper runs, so reservations expire after 120 seconds.
Even a failed/timed-out CLI call retains its bounded reservation because Tabby
may already have received it. After expiry, `restore` may request another tab;
an old confirmation will **refuse attachment**, including if it was never
reassigned. Expiry/reassignment and wrapper handoff use the same OS-backed lock
and nonce. This prevents duplicate managed attachments, not duplicate empty
confirmation tabs. Cancel stale confirmations yourself; the helper never closes
them. A wrapper waiting for authentication retains its live lease until exit;
it is not treated as stale merely because 120 seconds passed.

Aliases resolving through `ssh -G` to the same hostname/user/port share leases.
DNS aliases with different textual hostnames are not resolved over the network.
For those, set the same non-sensitive `endpointId` on the equivalent inventory
entries. This is an explicit grouping assertion: never reuse it for different
accounts, servers, or tmux namespaces. Different laptops have separate state
and may attach simultaneously. Global tmux attachment counts never block them.
Changes to endpoint/identity mapping invalidate old confirmations; run restore
again. Keep a stable inventory path until its pending confirmations are gone.

Session renames inside the configured prefix preserve managed leases because
their stable identities do not change. Names containing unsupported characters
are rejected, not passed to a shell. Moving outside the prefix excludes the
session from subsequent restore; an old confirmation refuses it. Server restart
changes identity and requires fresh inventory/reservations.

The final interactive command also checks the creation time, server PID and
configured prefix inside tmux before queuing attachment on that same server.
Restarting tmux during SSH authentication cannot redirect a reserved session ID
to replacement work. An identity mismatch displays a refusal and attaches no
client; restore again using fresh inventory. No replacement session is killed.

## Legacy SSH migration boundary

Current-account processes only are inspected privately; unrelated arguments are
never printed. Supported direct forms are `ssh [-t|-tt] <configured-alias>
tmux attach[-session] -t <name-or-session-id>` (also a single quoted remote
command). `-o ConnectTimeout=...`, `-o IdentitiesOnly=yes`, and `-i <private-path>`
are accepted for prototype migration. Endpoint overrides, arbitrary wrappers,
remote shell pipelines, `new-session -A`, custom sockets, truncated/ambiguous
process listings, and aliases absent from inventory are not claimed supported.

A recognized legacy target skips its session. If a legacy command refers to a
name/ID absent from current matching inventory (for example after a rename),
restore conservatively skips that endpoint's sessions as `legacy-ambiguous`.
Disconnect/migrate that **local legacy attachment** yourself to resolve it; do
not kill remote work. No local process command can retroactively identify the
stable session behind an already-renamed legacy target. Managed launches check
again at wrapper start, but cannot serialize a new unmanaged/manual SSH launch
that races after that check. Use managed commands on that laptop for atomic
concurrent restore guarantees.

## Dynamic titles and opt-in clipboard

Reuse [terminal-title.md](terminal-title.md) and the existing OpenCode title
owner. The backend does not write competing OSC titles or mutate remote tmux
configuration. `titlePrefix` is the inventory's desired compact host prefix;
apply it in a **reviewed, manual per-host** tmux snippet, for example for host A:

```tmux
set -g set-titles on
set -g set-titles-string 'A#{s/^oc-//:session_name} #{?pane_title,#{pane_title},#{pane_current_command}}'
```

This produces `A001 <status/title>` for `oc-001` and follows active pane titles
without changing tab ordering. Substitute your chosen `titlePrefix` and prefix
substitution if using non-default names. Allow dynamic title updates in Tabby.
Do not add a second title plugin/writer or change remote configuration during
restore. Existing sessions need the reviewed settings applied separately.

Long disposable session prefixes can fill Tabby's visible tab label and hide a
working title update at its end. During an authorized disposable smoke check,
hold a distinctive synthetic OSC title long enough to inspect the full title in
that tab's Rename dialog, then **Cancel without editing or saving**. Report only
whether the synthetic marker appears; never copy a personal title into a report.
A marker in the full title proves delivery even if the tab label clips it. Keep
the fixture's isolated `sessionPrefix`; do not broaden it or change shared
settings merely to make the smoke-test label fit.

Clipboard access is separate and **opt-in**. Remote OpenCode's OSC 52 requests
may require `set -g set-clipboard on` plus Tabby's clipboard-write permission;
`external` can permit tmux copies without permitting application requests.
Enabling this lets remote applications overwrite the local clipboard. Review
the trust boundary before enabling it. Nothing here grants clipboard access.

## Compatibility, verification, and rollback

Transport evidence: Tabby v1.0.236 `app/lib/cli.ts` declares `command` as an array
for `run`; repeated `--command=` preserves each argv element without `eval`.
`doctor` probes `--version` and `run --help` before launches. Tabby 1.0.235 and
the known `stripAnsi` failure are rejected; upgrade normally, never modify app
archives. A help probe is not proof of a GUI launch. The CLI routes to the
last-created window; selectable windows and per-host windows are not supported.
Five-second default pacing bounds launch rate but does not prove authentication
completion or prevent server-side MaxStartups drops. Failures never weaken SSH
limits, reorder tabs, or trigger unbounded retries.

Focused unittest coverage and existing profile regressions are mocked/isolated
checks, **not Linux/macOS GUI smoke proof**. Neither platform's live Tabby/SSH
attachment, title forwarding, tab-close persistence, or repeated GUI restore is
claimed verified by those checks. Before calling a platform smoke-verified,
obtain separate authorization for disposable non-sensitive sessions, record
client/Tabby/tmux versions, verify actual tmux clients and persistence after
closing only the disposable tab, and repeat restore with delayed confirmations.
Never use ongoing work or publish authentication logs/terminal contents.

Rollback by reverting the `sessions` dispatch/backend/doc changes. Existing
profile commands and remote sessions are independent. Leave live state inodes
alone; remove inactive owned state only after all managed tabs and pending
confirmations have ended. Direct SSH/tmux remains a recovery path. Setup deploys
the agents tree recursively, so there is no separate installer manifest entry;
this feature never auto-creates a private host inventory.

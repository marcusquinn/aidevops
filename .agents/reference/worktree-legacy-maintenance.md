<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Legacy worktree maintenance

Some historical `owner-cgroup-v1` observations recorded a shared supervisor
cgroup but no invocation or descendant-completion contract. Dead owner PIDs,
clean Git state, old timestamps and an archive cannot manufacture that evidence.
Ordinary cleanup continues to retain these worktrees.

`aidevops cleanup maintenance` is an explicit maintenance path, **not** another
background retention policy. It never changes old records to `sealed`, enrolls
them retroactively, exempts protected process names or relaxes CWD inspection.
It is never included in `cleanup all --apply` or scheduled automatically.

## Plan without changing worktrees

```bash
aidevops cleanup maintenance plan --repo /absolute/canonical/repository > /absolute/plan.json
```

The confirmation token is printed on stderr. Keep the plan private: it includes
local paths and worktree identities. Review the candidate and retained entries.
The plan is bound to this machine, repository/default tip, exact source identity,
HEAD and original lifecycle record. Its maximum lifetime is seven days.

Planning examines at most 50 worktrees by default (`--limit 1..200`). Progress is
written to stderr; JSON stays on stdout. `scan.next_offset` identifies the next
batch for `--offset N`; an unexamined worktree is **not** approved or classified as
retained. Offsets refer to the current Git listing, not a durable inventory: if
worktrees are added or removed between batches, restart the inventory. Replan
after each applied batch rather than assuming an old offset still identifies it.

This initial implementation accepts only clean, attributed legacy records with
no historical managed invocation, no interrupted archive operation, no live
registered owner, no open branch PR and HEAD contained in the repository's current
default branch. It requires GitHub evidence and current local default tracking
refs. It does not fetch, reset, commit, clear locks or delete anything while
planning. Unsupported remotes, dirty work and unreadable evidence are retained.
The shared Pulse archive-retention predicates also apply: protective issue/PR
labels, repeated zero-session failures and local forensic markers veto retirement.
Enrichment issue numbers and repair PR numbers are resolved from their established
branch conventions. Closed PRs are checked too; failed, malformed or potentially
truncated PR lookups retain the source. These checks run again at final proof.
Worktrees with ignored files or local forensic/security preservation markers are
retained. The current archive producer excludes ignored content: this maintenance
path must not treat a clean Git status as proof that those files are disposable.
Preserving ignored content needs a separately verified archive capability before
these candidates can be admitted; do not remove files merely to pass this check.

## Establish a maintenance window separately

Application currently supports **Linux systemd/cgroup v2**, including NixOS.
Other platforms refuse application; do not advertise this as a tested macOS or
Windows retirement adapter. Every host needs its own plan and maintenance window.

An administrator must establish a user-quiescent rescue/emergency window and run
the command as the affected **non-root user** in a root-controlled system service
named `aidevops-worktree-maintenance@UID.service`. This is not a user service or
an environment-variable opt-in. The executor verifies:

- rescue/emergency target active and root-controlled `/run/nologin` present;
- the user manager inactive and the maintenance unit ordered before and
  conflicting with `user@UID.service`;
- the actual process cgroup, system-service invocation and numeric `User=UID`;
- `KillMode=control-group`, `Restart=no` and root-controlled unit configuration;
- a root-controlled `systemctl` executable, with caller-supplied bus/loader
  environment removed from the observation subprocess;
- **all** processes bearing the user's real/effective/saved/filesystem UID inside
  this maintenance cgroup. Unreadable or outside processes refuse application.

The operator must also keep cron, system-level user jobs and other manual
launchers quiescent for the window. Do not start concurrent jobs for this UID.
No observation can protect against an administrator deliberately starting new
consumers during retirement. The existing final Git/content guards still apply.

No installer or command here switches system targets, stops sessions, installs
sudoers policy, logs out a user or starts this service. These are separate,
explicitly authorized operator actions. Do not attempt them from an active SSH
session as a way of making its own cleanup pass.

The example below is an **administrator-reviewed template**, not a deployable
default. Fill in the UID, home, trusted Python executable, plan path and reviewed
token. On NixOS express it in the system configuration; root-controlled symlinks
into the Nix store are supported. Do not run setup automatically to install it.

```ini
[Unit]
Description=Explicit legacy worktree maintenance for UID %i
Conflicts=user@%i.service
Before=user@%i.service

[Service]
Type=exec
User=%i
Environment=HOME=/home/OPERATOR
WorkingDirectory=/home/OPERATOR
ExecStart=/ABSOLUTE/PYTHON3 -B /home/OPERATOR/.aidevops/agents/scripts/worktree-maintenance.py check --plan /absolute/plan.json --confirm REVIEWED_TOKEN
KillMode=control-group
Restart=no
```

**Starting a unit with `Conflicts=` can stop the user manager.** Establish and
authorize the maintenance window first; never start this example during normal
interactive operation. Start with `check`, not `apply`. Network access and the
user's existing GitHub authentication must remain available for live PR/default
branch checks; "offline" here means user workloads are offline, not air-gapped.

## Apply only inside the verified window

After a successful check, the administrator may explicitly select `apply` in
the reviewed unit command. Both operations require `--plan` and `--confirm`.
`check` refreshes repository evidence and revalidates every candidate without
authorizing or performing deletion. Application still repeats these checks.

Each source is revalidated before calling the existing `worktree-helper.sh remove`
without `--force`. Preparation and the final native removal independently verify
the maintenance context. Incomplete CWD visibility refuses maintenance outright:
it never enters the manual degraded-recovery fallback or acquires its ownership
lease. Ordinary cleanup behavior is unchanged.

The archive-first helper owns preservation, independent restore verification,
late source fingerprints, Git locks, ownership and native removal. The maintenance
executor emits the plan token, system invocation, result and source presence for
the service journal. Existing removal audit logs remain authoritative. A failure
stops the batch and preserves the remaining candidates. Do not delete retained
producer transactions or rewrite lifecycle records to retry.

If a plan becomes stale, create and review a new plan. Do not edit the token or
manufacture old timestamps. A successful plan/check is not proof of reclaimed
space: verify source absence, archive evidence and storage after application.

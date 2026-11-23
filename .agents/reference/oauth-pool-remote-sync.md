<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# OAuth pool remote-sync

Keep one pool account in sync both ways between the local pool and another
host/user's aidevops pool (for example a shared runner user).

```bash
oauth-pool-helper.sh remote-sync sync    --host runner1 --remote-user aidevops --provider anthropic --email me@example.com
oauth-pool-helper.sh remote-sync status  --host runner1 --remote-user aidevops --provider anthropic --email me@example.com
oauth-pool-helper.sh remote-sync install --host ... # writes launchd (WatchPaths + 60s) or systemd path+timer units
oauth-pool-helper.sh remote-sync enable|disable --host ...
```

`--remote-user` runs the remote side as `sudo -n -u <user>` (passwordless sudo
required). The remote host needs aidevops deployed (`~/.aidevops/agents/scripts/oauth-pool-helper.sh`;
override with `--remote-helper`).

`--org <orgId-prefix|org name>` selects one seat when the email holds several
(e.g. Claude Team + Personal, GH#38959). Without it, a multi-seat email is
refused (`ambiguous-seat`, exit 2) rather than syncing the wrong seat. The org
is passed to the remote and added to the scheduler slug only when it is set, so
existing single-seat installs keep their units and work with older remote
helpers. An org-tagged entry merges into its exact seat, or upgrades the
email's single legacy seat that has no org.

## Rotation hazard (why not rsync)

- Refresh tokens rotate: `pool_ops_refresh.py` stores the new `refresh_token`,
  so two independent refreshers invalidate each other's grant. Only the entry
  with the newest `expires` is live.
- Copying `oauth-pool.json` wholesale overwrites the remote user's other
  providers/accounts and bypasses the `oauth-pool.json.lock.d` lock.

## Behaviour

- One pipeline per sync: `local entry-get | ssh remote entry-put | local entry-put`.
  Tokens move only over stdin/stdout, never argv or logs.
- `entry-put` writes only when incoming `expires` is newer, takes the shared
  lock, writes atomically with mode 600, clears `auth-error` and
  `authRefreshFailures*` on update, and inserts missing accounts as `active`.
  Empty stdin is a no-op; other providers/accounts are untouched.
- ssh ControlMaster multiplexing avoids sshd `MaxStartups` connection resets.
- `status` prints only sha256 fingerprints (12 hex chars) of the refresh and
  access tokens plus `expires`, never token bytes.

Tests: `python3 -m unittest discover -s .agents/scripts/tests -p test_entry_sync.py`.

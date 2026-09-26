<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Managed OpenCode service

One per-user OpenCode V1 server owns an isolated SQLite shard. Desktop and attached
TUIs share conversations through its loopback API; they never share SQLite file
handles. Project directories remain explicit on attached clients. Normal plugins,
Build+, provider integrations and aidevops tools remain enabled.

## Install and everyday use

Setup/update reconciles the service after deploying runtime plugins. macOS uses a
LaunchAgent at login; Linux and WSL2 use a systemd user service. No root service,
sudo, login-shell sourcing, database migration, or automatic Desktop restart is
performed. The default port is 49036 and the default shard is `managed-default`.

```bash
aidevops opencode service install
aidevops opencode service status
aidevops opencode managed --dir ~/Git/repo
aidevops opencode managed --dir ~/Git/repo --session ses_example
```

Use `service install --route-new` to make **plain new TUI launches** attach to this
owner. Setup opts into that route only on a fresh installation with no detected
OpenCode database. Existing installations retain their direct route unless the
user explicitly opts in. Updates preserve that decision and never change the
registered port or shard. A stopped foreground prototype can be adopted with
`service install --port 49036 --shard existing-server-shard`; stop its known owner
first. `--shard` is a storage identity, not a `ses_...` conversation ID.

**Existing histories are not imported or hidden:** `aidevops opencode --direct`
retains the old per-project history; explicit `--session-id` and `--shared-db`
retain their original meaning. Tabby's existing automatic/exact-session recovery
also remains direct. Use `aidevops opencode managed` explicitly in Tabby for shared
history; automatic managed-session Tabby recovery is not implemented. With managed
routing enabled outside Tabby, unsupported raw OpenCode flags fail with guidance
instead of silently opening another database.

## Desktop: one remaining manual connection step

Launch **OpenCode AIDevOps.app**, not the unwrapped application, to wait for the
owner before Desktop's initial protocol probe. Select the service URL in Desktop's
Servers UI and add the project using that server row's folder-plus **Add project**.
The same project path must be used by the TUI. Save the server as Desktop's default
where supported by the installed Desktop version.

OpenCode Desktop 1.18.32 has no supported CLI option/deep link for setting its
default server. The launcher deliberately does not edit Electron's private state.
Consequently this is **not yet zero-touch Desktop onboarding**. The wrapper also
cannot force a running Desktop instance to change its selected server. Existing
local Desktop history remains separate and accessible by selecting Local.

If Desktop first probed while the owner was offline, fully quit and reopen it once
the service is healthy. A green status alone does not prove correct API routing or
that the project is open. See the cross-client acceptance procedure in
[OpenCode maintenance](opencode-maintenance.md).

### Opt-in connection requests for capable Desktop builds

```bash
aidevops opencode-desktop --connect-managed --dir ~/Git/repo --dry-run
aidevops opencode-desktop --connect-managed --dir ~/Git/repo
```

This path requires a Desktop build advertising `connect-project: 1` in its public
`Contents/Resources/capabilities.json`. Desktop 1.18.32 does not advertise that
capability and is rejected with manual-selection guidance, including in dry-run.
The associated OpenCode source change adds an `opencode://connect` request carrying
only the verified loopback service URL and explicit project directory. It is not a
claim that released Desktop versions already implement the interface.

Desktop displays the server and folder for confirmation before connecting. Confirming
opens a draft on that server; cancelling changes nothing. Existing default-server
choices, saved connections, credentials and histories are preserved. No private
Desktop preferences are read or edited. The launcher does not silently enable a
disabled service or install one, and dry-run does not start it. Regular setup/update
and Desktop launches remain unchanged unless this option is supplied. This is guided
onboarding, not unattended default-server replacement or proof of live continuity.

## Lifecycle, updates and rollback

```bash
aidevops opencode service stop     # graceful stop; next managed launch can start it
aidevops opencode service start
aidevops opencode service disable  # persistent opt-out, including across setup/update
aidevops opencode service enable
```

Stop/start only when sessions are idle. No helper forcibly restarts an active
owner during setup/update. An unchanged definition is reconciled without replacing
the process. Changed definitions require an explicit stop before reinstalling;
CLI/server version mismatch blocks new attaches until an idle stop/start updates
the owner. Existing open clients are not killed. A failed first installation
disables itself instead of leaving a restart loop.

Configuration: `~/.config/aidevops/opencode-service.json` (0600). It stores identity,
routing and executable paths, not credentials. The owner helper and launcher are
staged under `~/.aidevops/.agent-workspace/work/opencode-service/runtime/`; service
definitions point there, not at a disposable worktree or a replaceable framework
bundle. Setup refreshes this small runtime without restarting the owner. Shared
safety tools still load through `~/.aidevops/agents/scripts/`. This also preserves
owner startup when an older framework without the new CLI commands is deployed.
For that recovery case, use:

```bash
python3 ~/.aidevops/.agent-workspace/work/opencode-service/runtime/opencode-service-helper.py status
aidevops opencode attach http://127.0.0.1:49036 --dir ~/Git/repo
```

Credentials continue through the existing auth file/provider
configuration; arbitrary interactive shell environment and overlays are not
inherited. Provider setups depending only on shell-exported keys need a supported
secure credential/configuration source available to the service.

Readiness verifies the service-manager PID, shard lock, listener process ancestry,
health response and exact CLI/server version. An unrelated healthy listener is
never adopted. Dead owner locks can recover after a crash/reboot only when the old
PID is gone and no process holds database files; uncertain or reused PIDs fail
closed. There is no fallback to a second local conversation.

macOS definition: `~/Library/LaunchAgents/sh.aidevops.opencode-server.plist`.
Logs: `~/.aidevops/logs/opencode-server.{out,err}.log` (private). Linux unit:
`~/.config/systemd/user/aidevops-opencode-server.service`; inspect it with
`journalctl --user -u aidevops-opencode-server.service`. Do not publish raw logs.

Rollback is `service disable`, then `--direct` for the original TUI history and
Local in Desktop. All databases and saved managed conversations remain untouched.
Set `AIDEVOPS_OPENCODE_SERVICE=0` to skip setup reconciliation; this alone does not
stop an already-enabled service. Disable it explicitly first.

## Platform and verification boundaries

- **macOS:** launchd lifecycle and real attached-client acceptance tested locally.
  The service runs in the logged-in user's GUI domain, not before login.
- **Linux/WSL2:** systemd unit generation and lifecycle contracts have mocked tests;
  no live systemd or WSL2 execution has been verified in this change. Requires a
  working `systemctl --user`, Python 3.9+, and `lsof`. No cron fallback. A user
  service normally ends at logout; lingering is an explicit administrator choice.
- **Native Windows:** unsupported; no Windows service is installed and no Windows
  test claim is made. Use WSL2. Windows Desktop-to-WSL loopback forwarding has not
  been validated here.

Focused checks:

```bash
python3 .agents/scripts/tests/test_opencode_service.py
/bin/bash .agents/scripts/tests/test-opencode-server-launcher.sh
/bin/bash .agents/scripts/tests/test-opencode-launcher-helper.sh
```

Runtime acceptance must additionally demonstrate a completed Build+ model/tool
request, shared session IDs/messages, client reopen, an idle owner restart with
history retained, and zero attached-TUI session-database handles. A health check
or an agent-selector entry alone is not sufficient.

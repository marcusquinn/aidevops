## What

Add a reusable `cloudron-helper.sh nginx-http2 <off|on|status> <server>` subcommand that turns HTTP/2 off on a Cloudron host's managed nginx during an HTTP/2 CVE window, keeps it off when Cloudron regenerates configs, reports state, and restores HTTP/2 exactly afterwards. Optionally `--sctp-block` / `--sctp-unblock` for the SCTP escalation step.

## Why

During the nginx2root response (advisory `nginx2root-2026-11`, t19117 / GH#39093) the interim mitigation had to be invented by hand per host. Observed traps that a one-line `sed` gets wrong, all on Cloudron 10.1.6 / Ubuntu 26.04:

- Vhosts in `/etc/nginx/applications/<app-id>/*.conf` use both `http2 on;` and the legacy `listen 443 ssl http2;`. The legacy form enables HTTP/2 for the whole address:port.
- Cloudron rewrote 1–2 vhosts per host about 2 minutes after a reboot, so a one-off edit reverts silently. A guarded re-apply from `/etc/cron.d` every 2 minutes was needed.
- `/etc/nginx` is a symlink into Cloudron's `platformdata/nginx`. `tar -C / etc/nginx` archives only the link, so the backup must target `readlink -f /etc/nginx`.
- An exact revert needs a record of which files used the legacy listen form. `box` regeneration after reboot does not rewrite every vhost.
- The `turn` container (coturn) holds kernel SCTP sockets, so SCTP blocking needs a modprobe.d entry plus a reboot.

Next nginx/HTTP/2 CVE, users should run one command instead of rebuilding this.

## How

- EDIT: `.agents/scripts/cloudron-helper.sh`. Add a `nginx-http2` case next to `"health" | "fleet-health")`, reusing `health_check`'s server lookup (`jq .servers.<name>.ip/ssh_port` from `$CONFIG_FILE`) and its `ssh -o BatchMode=yes` pattern.
- The remote side is a small embedded script installed to `/usr/local/sbin/aidevops-nginx-http2` and run by `/etc/cron.d/aidevops-nginx-http2` (every 2 min). The `apply` mode:
  - edits only when `http2\s+on\s*;` or `listen[^;]*\shttp2` is present;
  - backs up the real directory (0600, keeping 10);
  - appends legacy-listen files to `/var/lib/aidevops-nginx-http2/legacy-listen-files.txt`;
  - runs `nginx -t`, restoring the backup if it fails, otherwise reloads;
  - logs via `logger -t aidevops-nginx-http2`.
- `status` prints KEY=VALUE: `h2_on_files`, `h2_off_files`, `legacy_listen_recorded`, `cron`, `sctp_blocked`, `sctp_loaded`, and `running_new_binary` (`/proc/<nginx master>/exe` not `(deleted)`).
- The `on` (revert) mode:
  - removes the cron;
  - turns `http2 off;` back into `http2 on;`;
  - restores the `http2` parameter after `ssl` on `listen ... 443 ssl` lines of recorded files only (yielding `listen ... 443 ssl http2`);
  - runs `nginx -t` (rollback on failure), then `systemctl restart nginx`.
- `--patched-marker CVE-ID` (optional): `apply` becomes a no-op once `zgrep -q <CVE> /usr/share/doc/nginx-common/changelog.Debian.gz` matches, and `on` refuses until it matches unless `--force`.
- Reference implementation (private, working, ShellCheck-clean): the session's host script had `apply|status|revert` modes with exactly the above logic. Re-derive from this brief; do not copy host-specific paths.
- EDIT: `.agents/services/hosting/cloudron.md`. In "nginx security releases" (added by t19117), point the mitigation bullets at the new subcommand, and add it to the Quick Reference `Commands` list.

### Files Scope

- `.agents/scripts/cloudron-helper.sh`
- `.agents/services/hosting/cloudron.md`

## Acceptance

- `cloudron-helper.sh nginx-http2 status <server>` prints the KEY=VALUE state, read-only.
- `off` leaves zero files matching either HTTP/2 form, installs the cron, and `nginx -t` passes. External `curl -sI --http2 --resolve <fqdn>:443:<ip> https://<fqdn>/` shows `HTTP/1.1`.
- `on` restores both forms byte-identically for recorded files (diff against the pre-`off` backup shows no `listen`/`http2` differences) and removes the cron.
- ShellCheck zero violations; every function has explicit `return`; `local var="$1"` style.

## Verification

- `shellcheck .agents/scripts/cloudron-helper.sh`
- Run `status` against a test Cloudron server, or run the embedded remote script against a scratch copy of `applications/*.conf` (both forms). Confirm `off` → `on` round-trips byte-identically.
- `npx --no-install markdownlint-cli2 .agents/services/hosting/cloudron.md`

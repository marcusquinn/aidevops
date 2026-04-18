---
name: cloudron-server-ops
description: "Manage apps on a Cloudron server using the cloudron CLI"
mode: subagent
imported_from: external
tools:
  read: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron Server Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging/cli](https://docs.cloudron.io/packaging/cli) | **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills)
- **Install**: `sudo npm install -g cloudron` (on your PC/Mac, NOT the server)
- **Login**: `cloudron login my.example.com` (browser-based; 9.1+ uses OIDC/passkey)
- **CI/CD**: `--server <domain> --token <api-token> --no-wait` (token from `https://my.<domain>/#/profile`); e.g. `cloudron update --server my.example.com --token <token> --app blog.example.com --image user/image:tag`
- **Token**: `~/.cloudron.json` | **Self-signed TLS**: `--allow-selfsigned`
- **App targeting**: `--app` accepts FQDN, subdomain, or app ID; auto-detected from `CloudronManifest.json`
- **Global flags**: `--server`, `--token`, `--allow-selfsigned`, `--no-wait`
- **Also see**: `cloudron-helper.sh` for multi-server management via API

<!-- AI-CONTEXT-END -->

## Commands

### Listing and Inspection

```bash
cloudron list                  # all installed apps (-q for IDs only, --tag <tag> to filter)
cloudron status --app <app>    # app details (status, domain, memory, image)
cloudron inspect               # raw JSON of the Cloudron server
```

### App Lifecycle

```bash
cloudron install               # install app (on-server build or --image)
cloudron update --app <app>    # update app (rebuilds or uses --image)
cloudron uninstall --app <app>
cloudron repair --app <app>    # reconfigure without changing image
cloudron clone --app <app> --location new-location
```

Flags for `install`/`update`: `--image <repo:tag>`, `--no-backup`, `-l <subdomain>`, `-s <secondary-domains>`, `-p <port-bindings>`, `-m <memory-bytes>`, `--versions-url <url>`

**On-server build (9.1+)** — directory with `CloudronManifest.json` + `Dockerfile`:

```bash
cloudron install --location myapp   # upload source, build on server, install
cloudron update --app myapp         # upload source, rebuild, update
```

### Run State and Logs

```bash
cloudron start --app <app>
cloudron stop --app <app>
cloudron restart --app <app>
cloudron cancel --app <app>            # cancel pending task
cloudron logs --app <app>              # recent logs (-f follow, -l N last N lines)
cloudron logs --system                 # platform logs (--system mail for specific service)
```

### Shell, Exec, and Debug

```bash
cloudron exec --app <app>                              # interactive shell
cloudron exec --app <app> -- ls -la /app/data          # run a command
cloudron exec --app <app> -- bash -c 'echo $CLOUDRON_MYSQL_URL'
cloudron debug --app <app>             # debug mode: pauses app, r/w filesystem
cloudron debug --app <app> --disable   # exit debug mode
```

### File Transfer

One-off file copy with `push`/`pull`:

```bash
cloudron push --app <app> local.txt /tmp/remote.txt
cloudron push --app <app> localdir /tmp/
cloudron pull --app <app> /app/data/file.txt .
cloudron pull --app <app> /app/data/ ./backup/
```

Directory sync with `cloudron sync` (rsync-style, changed files only):

```bash
cloudron sync push --app <app> ./local/ /app/data       # contents of ./local -> /app/data (trailing slash)
cloudron sync push --app <app> ./local /app/data        # ./local itself into /app/data/local (no slash)
cloudron sync push --app <app> file.txt /app/data       # single file -> remote
cloudron sync pull --app <app> /app/data/ ./local       # contents of /app/data -> ./local
cloudron sync pull --app <app> /app/data ./local        # /app/data itself into ./local/data
cloudron sync push --app <app> ./local/ /app/data --delete   # also delete remote-only files
cloudron sync pull --app <app> /app/data/ ./local --delete   # also delete local-only files
cloudron sync push --app <app> ./local/ /app/data --force    # remove files blocking directory creation
```

Trailing slash on the source syncs its contents; without it, the directory itself is placed inside the destination (`rsync` convention). `--delete` removes files present only on the destination side. `--force` removes files blocking directory creation.

**Rule of thumb:** for directory transfers, prefer `cloudron sync`; keep `cloudron push`/`pull` for one-off file copy and stream-oriented use cases.

### Environment Variables and Configuration

```bash
cloudron env list --app <app>
cloudron env get --app <app> MY_VAR
cloudron env set --app <app> MY_VAR=value OTHER=val2    # restarts app
cloudron env unset --app <app> MY_VAR                   # restarts app
cloudron set-location --app <app> -l new-subdomain      # change subdomain
cloudron set-location --app <app> -s "api.example.com"  # secondary domain
cloudron set-location --app <app> -p "SSH_PORT=2222"    # port binding
```

### Backups

```bash
cloudron backup create --app <app>
cloudron backup list --app <app>
cloudron restore --app <app> --backup <backup-id>
cloudron export --app <app>
cloudron import --app <app> --backup-path /path
cloudron backup decrypt <infile> <outfile> --password <pw>     # local offline
cloudron backup decrypt-dir <indir> <outdir> --password <pw>   # local offline
cloudron backup encrypt <infile> <outfile> --password <pw>     # local offline
```

### Utilities

```bash
cloudron open --app <app>       # open app in browser
cloudron init                   # create CloudronManifest.json + Dockerfile
cloudron completion             # shell completion (source the output)
```

## Common Workflows

**Check and restart a misbehaving app:**

```bash
cloudron status --app <app>
cloudron logs --app <app> -l 100
cloudron restart --app <app>
```

**Debug a crashing app** (pauses the app, makes filesystem writable):

```bash
cloudron debug --app <app>
cloudron exec --app <app>       # inspect filesystem, test manually
cloudron debug --app <app> --disable
```

**Backup and restore:**

```bash
cloudron backup create --app <app>
cloudron backup list --app <app>              # note the backup ID
cloudron restore --app <app> --backup <id>
```

**Set env vars for an app** (auto-restarts):

```bash
cloudron env set --app <app> FEATURE_FLAG=true DEBUG=1
cloudron logs --app <app> -f                  # watch the restart
```

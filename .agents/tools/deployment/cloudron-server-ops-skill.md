---
description: "Manage apps on a Cloudron server using the cloudron CLI"
mode: subagent
imported_from: external
tools:
  read: true
  bash: true
  webfetch: true
---

# Cloudron Server Operations

The `cloudron` CLI manages apps on a Cloudron server. All commands operate on apps, not the server itself.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Manage installed Cloudron apps via CLI (logs, exec, backups, env vars, lifecycle)
- **Docs**: [docs.cloudron.io/packaging/cli](https://docs.cloudron.io/packaging/cli)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-server-ops`)
- **Install CLI**: `sudo npm install -g cloudron`
- **Login**: `cloudron login my.example.com` (opens browser for auth; 9.1+ uses OIDC)
- **CI/CD**: Use `--server` and `--token` flags for non-interactive use
- **Also see**: `cloudron-helper.sh` for multi-server management via API

<!-- AI-CONTEXT-END -->

## Setup

```bash
sudo npm install -g cloudron      # install on your PC/Mac, NOT on the server
cloudron login my.example.com     # opens browser for authentication
```

Token is stored in `~/.cloudron.json`.

For self-signed certificates: `cloudron login my.example.com --allow-selfsigned`

### 9.1+ OIDC Login

In Cloudron 9.1+, the CLI uses OIDC login (browser-based) to support passkey authentication. For automated pipelines, use a pre-obtained API token from the dashboard with `--token`.

## App Targeting

Most commands require `--app` to specify which app:

```bash
cloudron logs --app blog.example.com              # by FQDN
cloudron logs --app blog                           # by subdomain/location
cloudron logs --app 52aae895-5b7d-4625-8d4c-...   # by app ID
```

When run from a directory with `CloudronManifest.json` and a previously installed app, the CLI auto-detects the app.

## Commands

### Listing and Inspection

```bash
cloudron list                  # all installed apps
cloudron list -q               # quiet (IDs only)
cloudron list --tag web        # filter by tag
cloudron status --app <app>    # app details (status, domain, memory, image)
cloudron inspect               # raw JSON of the Cloudron server
```

### App Lifecycle

```bash
cloudron install               # install app (on-server build or --image)
cloudron update --app <app>    # update app (rebuilds or uses --image)
cloudron uninstall --app <app>
cloudron repair --app <app>    # reconfigure app without changing image
cloudron clone --app <app> --location new-location
```

`cloudron install` and `cloudron update` accept:

- `--image <repo:tag>` -- use a pre-built Docker image
- `--no-backup` -- skip backup before update
- `-l, --location <subdomain>` -- set the app location
- `-s, --secondary-domains <domains>` -- secondary domain bindings
- `-p, --port-bindings <bindings>` -- TCP/UDP port bindings
- `-m, --memory-limit <bytes>` -- override memory limit
- `--versions-url <url>` -- install a community app from a CloudronVersions.json URL

### On-Server Build and Deploy (9.1+)

```bash
# From a package directory with CloudronManifest.json + Dockerfile:
cloudron install --location myapp    # uploads source, builds on server, installs
cloudron update --app myapp          # uploads source, rebuilds, updates
```

Source is part of the app backup. On restore, the app rebuilds from the backed-up source. Requires Dockerfiles to be deterministic.

### Run State

```bash
cloudron start --app <app>
cloudron stop --app <app>
cloudron restart --app <app>
cloudron cancel --app <app>     # cancel pending task
```

### Logs

```bash
cloudron logs --app <app>              # recent logs
cloudron logs --app <app> -f           # follow (tail)
cloudron logs --app <app> -l 200       # last 200 lines
cloudron logs --system                 # platform system logs
cloudron logs --system mail            # specific system service
```

### Shell and Exec

```bash
cloudron exec --app <app>                              # interactive shell
cloudron exec --app <app> -- ls -la /app/data          # run a command
cloudron exec --app <app> -- bash -c 'echo $CLOUDRON_MYSQL_URL'  # with env vars
```

### Debug Mode

When an app keeps crashing, `cloudron exec` may disconnect. Debug mode pauses the app (skips CMD) and makes the filesystem read-write:

```bash
cloudron debug --app <app>             # enter debug mode
cloudron debug --app <app> --disable   # exit debug mode
```

### File Transfer

```bash
cloudron push --app <app> local.txt /tmp/remote.txt    # push file
cloudron push --app <app> localdir /tmp/                # push directory
cloudron pull --app <app> /app/data/file.txt .          # pull file
cloudron pull --app <app> /app/data/ ./backup/          # pull directory
```

### Environment Variables

```bash
cloudron env list --app <app>
cloudron env get --app <app> MY_VAR
cloudron env set --app <app> MY_VAR=value OTHER=val2    # restarts app
cloudron env unset --app <app> MY_VAR                   # restarts app
```

### Configuration

```bash
cloudron set-location --app <app> -l new-subdomain
cloudron set-location --app <app> -s "api.example.com"  # secondary domain
cloudron set-location --app <app> -p "SSH_PORT=2222"    # port binding
```

### Backups

```bash
cloudron backup create --app <app>                      # create backup
cloudron backup list --app <app>                        # list backups
cloudron restore --app <app> --backup <backup-id>       # restore from backup
cloudron export --app <app>                             # export to backup storage
cloudron import --app <app> --backup-path /path         # import external backup
```

Backup encryption utilities (local, offline):

```bash
cloudron backup decrypt <infile> <outfile> --password <pw>
cloudron backup decrypt-dir <indir> <outdir> --password <pw>
cloudron backup encrypt <infile> <outfile> --password <pw>
```

### Utilities

```bash
cloudron open --app <app>       # open app in browser
cloudron init                   # create CloudronManifest.json + Dockerfile
cloudron completion             # shell completion
```

## CI/CD Integration

Use `--server` and `--token` to run commands non-interactively. Get API tokens from `https://my.example.com/#/profile`:

```bash
cloudron update \
  --server my.example.com \
  --token 001e7174c4cbad2272 \
  --app blog.example.com \
  --image username/image:tag
```

## Global Options

| Option | Purpose |
|--------|---------|
| `--server <domain>` | Target Cloudron server |
| `--token <token>` | API token (for CI/CD) |
| `--allow-selfsigned` | Accept self-signed TLS certificates |
| `--no-wait` | Do not wait for the operation to complete |

## Common Workflows

### Check and Restart a Misbehaving App

```bash
cloudron status --app <app>
cloudron logs --app <app> -l 100
cloudron restart --app <app>
```

### Debug a Crashing App

```bash
cloudron debug --app <app>
cloudron exec --app <app>
# inspect filesystem, check logs, test manually
cloudron debug --app <app> --disable
```

### Backup and Restore

```bash
cloudron backup create --app <app>
cloudron backup list --app <app>
# note the backup ID
cloudron restore --app <app> --backup <id>
```

### Install a Community Package (9.1+)

```bash
# From a CloudronVersions.json URL
cloudron install --versions-url https://example.com/CloudronVersions.json --location myapp
```

### Set Env Vars for an App

```bash
cloudron env set --app <app> FEATURE_FLAG=true DEBUG=1
# app restarts automatically
cloudron logs --app <app> -f
```

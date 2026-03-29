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

# Cloudron Server Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: [docs.cloudron.io/packaging/cli](https://docs.cloudron.io/packaging/cli)
- **Upstream skill**: [git.cloudron.io/docs/skills](https://git.cloudron.io/docs/skills) (`cloudron-server-ops`)
- **Install**: `sudo npm install -g cloudron` (on your PC/Mac, NOT the server)
- **Login**: `cloudron login my.example.com` (browser-based; 9.1+ uses OIDC/passkey)
- **CI/CD**: `--server <domain> --token <api-token> --no-wait` (token from `https://my.example.com/#/profile`); example: `cloudron update --server my.example.com --token <token> --app blog.example.com --image user/image:tag`
- **Token stored**: `~/.cloudron.json`; self-signed TLS: add `--allow-selfsigned`
- **Also see**: `cloudron-helper.sh` for multi-server management via API

<!-- AI-CONTEXT-END -->

## App Targeting

`--app` accepts FQDN, subdomain, or app ID. Auto-detected from `CloudronManifest.json` in the current directory.

```bash
cloudron logs --app blog.example.com   # by FQDN
cloudron logs --app blog               # by subdomain
cloudron logs --app 52aae895-...       # by app ID
```

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
cloudron repair --app <app>    # reconfigure without changing image
cloudron clone --app <app> --location new-location
```

`install` and `update` key flags: `--image <repo:tag>`, `--no-backup`, `-l <subdomain>`, `-s <secondary-domains>`, `-p <port-bindings>`, `-m <memory-bytes>`, `--versions-url <url>`

**On-server build (9.1+):** From a directory with `CloudronManifest.json` + `Dockerfile`:

```bash
cloudron install --location myapp   # upload source, build on server, install
cloudron update --app myapp         # upload source, rebuild, update
```

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
cloudron logs --app <app> -l 200       # last N lines
cloudron logs --system                 # platform system logs
cloudron logs --system mail            # specific system service
```

### Shell and Exec

```bash
cloudron exec --app <app>                              # interactive shell
cloudron exec --app <app> -- ls -la /app/data          # run a command
cloudron exec --app <app> -- bash -c 'echo $CLOUDRON_MYSQL_URL'
```

### Debug Mode

When an app keeps crashing, `exec` may disconnect. Debug mode pauses the app (skips CMD) and makes the filesystem read-write:

```bash
cloudron debug --app <app>             # enter debug mode
cloudron debug --app <app> --disable   # exit debug mode
```

### File Transfer

```bash
cloudron push --app <app> local.txt /tmp/remote.txt
cloudron push --app <app> localdir /tmp/
cloudron pull --app <app> /app/data/file.txt .
cloudron pull --app <app> /app/data/ ./backup/
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
cloudron backup create --app <app>
cloudron backup list --app <app>
cloudron restore --app <app> --backup <backup-id>
cloudron export --app <app>
cloudron import --app <app> --backup-path /path

# Encryption utilities (local, offline):
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

## Global Options

| Option | Purpose |
|--------|---------|
| `--server <domain>` | Target Cloudron server |
| `--token <token>` | API token (CI/CD) |
| `--allow-selfsigned` | Accept self-signed TLS |
| `--no-wait` | Don't wait for operation to complete |

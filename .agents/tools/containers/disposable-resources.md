---
description: Disposable Docker resources - owner labels, teardown, reaping, pressure report and address-pool fixes
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Disposable Docker Resources

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/docker-resource-helper.sh` (`labels`, `compose-labels`, `inventory`, `teardown`, `reap`, `report`)
- **Rule**: every container, network and volume a session starts for testing, plugin checks or review sites carries the six `sh.aidevops.*` owner labels
- **Teardown**: removing a linked worktree (`worktree-helper.sh remove`, post-merge cleanup, `worktree-helper.sh clean`) removes the labelled resources for that worktree
- **Reaping**: the pulse runs `reap`, which is report-only until `AIDEVOPS_DOCKER_REAP=1`
- **Never removed automatically**: resources without `sh.aidevops.owner=1`. They are only counted by `report`. Remove them only with the user's go-ahead.

## Owner labels

| Label | Value |
|-------|-------|
| `sh.aidevops.owner` | `1` |
| `sh.aidevops.repo` | `owner/repo` (default: `origin` remote) |
| `sh.aidevops.ref` | `GH#N` or `PR#N` (default: `WORKER_ISSUE_NUMBER`, else `ghN` in the branch name) |
| `sh.aidevops.worktree` | absolute worktree path (default: `git rev-parse --show-toplevel`) |
| `sh.aidevops.created` | epoch seconds at label time |
| `sh.aidevops.ttl-hours` | hours before the TTL rule applies (default `AIDEVOPS_DOCKER_TTL_HOURS`, else 72) |

## Starting a labelled stack

`labels` prints one `--label=key=value` per line. Read it into an array so worktree paths with spaces survive:

```bash
helper=~/.aidevops/agents/scripts/docker-resource-helper.sh
labels=()
while IFS= read -r l; do labels+=("$l"); done < <("$helper" labels --ref GH#123 --ttl-hours 24)

docker network create "${labels[@]}" site-gh123
docker volume create "${labels[@]}" site-gh123-db
docker run -d "${labels[@]}" --name site-gh123-db --network site-gh123 \
  -v site-gh123-db:/var/lib/mysql -e MARIADB_ROOT_PASSWORD=[placeholder] mariadb:11
"$helper" inventory   # the three resources are listed
```

For Compose, paste the generated snippet under each service, network and volume (`--indent` matches the nesting):

```bash
"$helper" compose-labels --ref PR#456 --indent 4
```

`compose-labels` stamps the current time into `created`. Regenerate the snippet for each new stack, and don't commit it to a shared Compose file.

`wp-plugin-release-helper.sh` labels its plugin-check network, volume and containers this way. It still removes them on exit through `wprh_pc_cleanup`.

## Teardown, reap and report

```bash
"$helper" teardown --worktree /path/to/worktree --dry-run   # list what would go
"$helper" teardown --worktree /path/to/worktree             # remove (worktree must be gone)
"$helper" teardown --worktree /path/to/worktree --force     # remove even if it still exists
"$helper" reap                                              # report-only candidates
"$helper" reap --apply --max-seconds 30 --verbose           # remove candidates, explain keeps
"$helper" report                                            # counts, sizes and reclaim commands; deletes nothing
```

`reap` removes a labelled resource only when all of these hold:

1. It was created more than 30 minutes ago, so a stack another session is starting is safe.
2. Either:
   - its worktree path is gone **and** its issue/PR is closed or merged (one `gh` lookup per ref per run, and a failed lookup means "keep"), or
   - its TTL has expired and it is not running or used by a running container.
3. For networks and volumes: no container that is staying is still attached.

Removal goes containers first, then networks, then volumes. "No such object" errors from a parallel run are ignored, so repeated runs converge.

## Environment

| Variable | Default | Effect |
|----------|---------|--------|
| `AIDEVOPS_DOCKER_REAP` | `0` | `1` lets the pulse run `reap --apply`; otherwise the pulse is report-only |
| `AIDEVOPS_DOCKER_TEARDOWN` | `1` | `0` disables teardown on worktree removal |
| `AIDEVOPS_DOCKER_TTL_HOURS` | `72` | default `ttl-hours` label and report threshold |
| `PULSE_DOCKER_CLEANUP_MAX_SECONDS` | `30` | time budget for the pulse reap step |
| `AIDEVOPS_DOCKER_TIMEOUT_SECONDS` | `5` | daemon probe timeout |
| `AIDEVOPS_DOCKER_CMD_TIMEOUT_SECONDS` | `30` | per-command timeout |

If Docker is missing or the daemon doesn't answer within the probe timeout, every entry point logs one line and exits 0. Pulse and merge cleanup never fail because of Docker.

## Address-pool exhaustion

Symptom: `docker network create` (or `docker compose up`) fails with `all predefined address pools have been fully subnetted`. The default pools give about 30 bridge networks, and leftover test stacks use them up.

1. Run `"$helper" report` and look at the "Custom networks with no containers" section.
2. Remove only those networks: `docker network prune` removes networks with no containers, or use `docker network rm <name>` for individual names from the report. Networks still attached to a container are kept.
3. Optional: to get about 256 `/24` networks instead of about 30, set `default-address-pools` in the daemon config. Use Docker Desktop/OrbStack settings, or `/etc/docker/daemon.json` on Linux:

   ```json
   { "default-address-pools": [ { "base": "10.200.0.0/16", "size": 24 } ] }
   ```

   Restart the daemon afterwards. Choose a `base` that doesn't overlap your LAN or VPN ranges. Existing networks keep their subnets.

## Related

- `tools/containers/orbstack.md`: macOS Docker runtime and destructive-op cautions
- `scripts/system-cleanup.sh`: non-Docker workspace cleanup that the same pulse step runs

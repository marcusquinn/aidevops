<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GitHub Self-Hosted Runner Operations

Operational runbook for the self-hosted GitHub Actions runner pool used by the
repository CI when jobs need isolated Docker builds on the local server.

The goal is that any maintainer can answer three questions without private chat
history: what is running, how to prove whether it is healthy, and what to change
when a runner is offline or mis-sized.

## Current deployment

Verified on the server during the 2026-06-20 inspection. Concrete repository,
image, and environment names are represented with placeholders so this public
framework documentation does not expose private deployment identifiers.

| Item | Value |
|------|-------|
| Service template | `/etc/systemd/system/github-runner-dind@.service` |
| Service instances | `github-runner-dind@1.service` through `github-runner-dind@12.service` |
| Container names | `github-runner-dind-1` through `github-runner-dind-12` |
| Target repository | `<OWNER>/<REPO>` |
| Runner image | `<OWNER>/github-runner:<TAG>` |
| Runner profiles | small, medium, large |
| Container isolation mode | `--privileged` |
| Docker storage driver inside runner | `overlay2` preferred; `vfs` only as a temporary fallback |
| Environment file | `/etc/github-runner/<REPO>.env` |

The runner containers are started by systemd, run with Docker-in-Docker support,
and are removed before each start with `docker rm -f github-runner-dind-%i`.
Completed ephemeral jobs are replaced after the `RestartSec=5` delay.

## Runner profiles

The launch script assigns profiles by service instance number:

| Profile | Instances | CPU | Memory | Extra labels | Intended jobs |
|---------|-----------|-----|--------|--------------|---------------|
| small | `1`-`6` | 2 | 4 GiB | `small` | lint, docs, formatting, small unit tests |
| medium | `7`-`10` | 3 | 8 GiB | `medium` | application tests, builds, integration tests |
| large | `11`-`12` | 4 | 12 GiB | `large`, `docker` | Docker-heavy builds, browser/e2e, service stacks |

Workflow jobs should target the smallest profile that satisfies the job:

```yaml
runs-on: [self-hosted, linux, small]
```

Use `medium` or `large` only when the job has measured CPU, memory, or Docker
needs that justify the larger slot.

## Files and responsibility boundaries

| Path | Purpose | Change policy |
|------|---------|---------------|
| `/etc/systemd/system/github-runner-dind@.service` | systemd service template for each runner instance | Change only when lifecycle, restart, or dependency behaviour changes. |
| `/usr/local/sbin/github-runner-dind-start` | runner container launch script and resource limits | Change when image, labels, CPU, memory, or registration logic changes. |
| `/etc/github-runner/<REPO>.env` | private repository URL, labels, and GitHub access token | Never print or commit values; rotate credentials after exposure. |
| `github-runner-dind@N.service` | enabled runner instances | Scale by enabling or disabling numbered instances. |

Infrastructure changes should update this runbook in the same PR or operational
handoff note, including the command used to verify the new state.

## Architecture

```text
GitHub Actions job
  -> repository self-hosted runner registration
  -> systemd github-runner-dind@N.service
  -> privileged runner container
  -> inner dockerd using the overlay2 storage driver
  -> job checkout, build, test, and container operations
```

This design gives each runner its own Docker daemon instead of sharing the host
Docker socket with workflow jobs. The trade-off is that `--privileged` is still a
high-trust mode and must be treated as sensitive infrastructure.

## Service model

The systemd unit template has this shape:

```ini
[Unit]
Description=Ephemeral Docker GitHub Actions runner %i for <OWNER>/<REPO>
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/github-runner/<REPO>.env
Restart=always
RestartSec=5
TimeoutStopSec=90
ExecStartPre=/bin/sh -c 'out=$(/usr/bin/docker rm -f github-runner-dind-%i 2>&1); rc=$?; [ $rc -eq 0 ] || printf "%s\n" "$out" | grep -qE "No such container|No such object"'
ExecStart=/usr/local/sbin/github-runner-dind-start %i
ExecStop=/bin/sh -c 'out=$(/usr/bin/docker stop github-runner-dind-%i 2>&1); rc=$?; [ $rc -eq 0 ] || printf "%s\n" "$out" | grep -qE "No such container|No such object"'

[Install]
WantedBy=multi-user.target
```

Keep real environment values out of documentation, issue comments, and PRs. The
environment file should contain only server-local configuration and secrets such
as repository URL, runner labels, and runner registration credentials.

The `ExecStartPre` and `ExecStop` commands intentionally treat a missing
container as success. Ephemeral runner containers are started with
`docker run --rm`, so a completed job can remove the container before systemd
runs `ExecStop`. Running `docker rm -f` or `docker stop` directly and filtering
only the expected missing-container errors avoids a time-of-check/time-of-use
race while still letting real Docker errors surface.

The launch script should end by replacing the shell with a foreground Docker
client, for example `exec docker run ...` without `-d` or `--detach`, rather
than starting Docker as a child or background process. This lets systemd deliver
stop signals to the Docker client directly and reduces the risk of orphaned
runner containers, restart loops, or later container-name conflicts.

## Health checks

Use read-only commands first:

```bash
systemctl list-units --type=service --all --no-pager | rg -i 'github-runner|docker'
docker ps --filter name=github-runner-dind --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
systemctl show 'github-runner-dind@1.service' --property=Id,Description,ActiveState,SubState,NRestarts,ExecMainStatus --no-pager
```

Expected healthy state:

- `docker.service` is `active/running`.
- `github-runner-dind@1.service` through `github-runner-dind@12.service` are
  loaded and running or restarting after an ephemeral job exit.
- `docker ps` shows one `github-runner-dind-N` container for each active service.
- GitHub shows the self-hosted runners online for the target repository.

Ephemeral runners can restart after completing a job, so a short-lived
`activating auto-restart` state is not automatically a failure. Treat it as a
failure only when the same instance keeps restarting without becoming online in
GitHub or without creating a replacement container.

Verify resource limits on a specific container:

```bash
docker inspect github-runner-dind-1 \
  --format '{{.Name}} CPUs={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} Privileged={{.HostConfig.Privileged}}'
```

Expected resource values by profile:

| Profile | CPU inspect value | Memory inspect value |
|---------|-------------------|----------------------|
| small | `CPUs=2000000000` | `Memory=4294967296` |
| medium | `CPUs=3000000000` | `Memory=8589934592` |
| large | `CPUs=4000000000` | `Memory=12884901888` |

## Operations

Restart one runner after a failed or stale job:

```bash
sudo systemctl restart github-runner-dind@1.service
```

Restart the whole pool:

```bash
sudo systemctl restart 'github-runner-dind@*.service'
```

Scale the pool to a new size by enabling or disabling numbered instances:

```bash
sudo systemctl enable --now github-runner-dind@7.service github-runner-dind@8.service
sudo systemctl disable --now github-runner-dind@9.service
```

Change per-runner CPU, memory, or inner Docker storage-driver settings in
`/usr/local/sbin/github-runner-dind-start`, then restart instances gradually.
Canary one instance before rotating the whole pool when CI is active. Prefer
`overlay2` for the inner daemon; treat `vfs` as a short-term fallback because it
does not use copy-on-write and can consume disk quickly.

Stop one runner before maintenance:

```bash
sudo systemctl stop github-runner-dind@1.service
```

Inspect recent service logs when journal access is available:

```bash
journalctl -u github-runner-dind@1.service -n 100 --no-pager
```

Inspect a running container without printing secrets:

```bash
docker inspect github-runner-dind-1 \
  --format 'Image={{.Config.Image}} Privileged={{.HostConfig.Privileged}} CPUs={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} Network={{.HostConfig.NetworkMode}}'
```

## Updating the runner image

1. Build and publish the replacement image under the expected image tag.
2. Restart one service instance and confirm it registers successfully in GitHub.
3. Run a workflow that uses the self-hosted labels.
4. Restart the remaining services only after the canary runner passes.

Do not rotate all runners at once unless the current pool is already broken.

## Security notes

- Treat this pool as trusted CI infrastructure for the target repository only.
- Do not expose the runner environment file or registration token values.
- `--privileged` means jobs have a larger blast radius than ordinary
  GitHub-hosted runners; restrict repository access and workflow authorship.
- Prefer ephemeral registration tokens and rotate credentials after suspected
  compromise.
- Keep untrusted pull request workflows away from privileged self-hosted labels
  unless the repository has an explicit maintainer approval gate.
- Avoid binding the host Docker socket into jobs; this deployment uses an inner
  Docker daemon instead.

## Troubleshooting

| Symptom | Check | Likely action |
|---------|-------|---------------|
| Runner offline in GitHub | `systemctl status github-runner-dind@N.service` | Restart the affected service and verify registration credentials. |
| Service restarts repeatedly | `systemctl show ... NRestarts ExecMainStatus` | Check image entrypoint, registration token freshness, and network access. |
| Docker commands fail inside workflow | Container process list for inner `dockerd` | Confirm the runner container is privileged and inner Docker daemon started. |
| Builds are slow or disk-heavy | Inner Docker storage driver and job cache usage | Confirm `overlay2` is active for the inner daemon; migrate off `vfs`, then clean stale job artifacts and review image layers. |
| Container name conflict | `docker ps -a --filter name=github-runner-dind-N` | The unit already removes stale containers before start; restart the service. |

## Repair checklist

1. Identify the affected instance number from GitHub or `systemctl` output.
2. Confirm whether the instance is genuinely stuck or only between ephemeral jobs.
3. Check the systemd state, current container, and recent logs.
4. Restart only the affected instance first.
5. If registration fails, rotate the registration/access credential in the
   private environment file without printing it to the terminal transcript.
6. If container startup fails, verify the image tag and resource flags in the
   launch script.
7. After repair, confirm GitHub shows the runner online and run a workflow that
   targets the self-hosted labels.

## Documentation hygiene

When copying this runbook to a project repository, replace private repository
names, hostnames, paths, labels, and image names with placeholders unless the
destination is private and approved for operational detail.

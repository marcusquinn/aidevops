<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GitHub Self-Hosted Runner Operations

Operational runbook for the self-hosted GitHub Actions runner pool used by the
repository CI when jobs need isolated Docker builds on the local server.

The goal is that any maintainer can answer three questions without private chat
history: what is running, how to prove whether it is healthy, and what to change
when a runner is offline or mis-sized.

## Org-scoped GitHub App runners (recommended)

Model: one GitHub App per org (only the `organization_self_hosted_runners: write`
permission, webhook inactive, installable only on that org), one org runner group
restricted to selected private repos with public repositories disallowed, and
ephemeral JIT-registered runners (one container per job) whose registration
tokens come from App installation tokens. A key compromise is limited to one org,
and fork PRs on public repos can never reach the host. Public repos keep free
GitHub-hosted minutes.

`runs-on` guidance: private repos use `[self-hosted, linux, <POOL_LABEL>]`;
public repos stay on GitHub-hosted runners.

The server-side pool (systemd, rootless or DinD containers, JIT registration) is
operator-owned. `github-runner-org-helper.sh` prepares and verifies its inputs.

One-time onboarding per org:

1. In the GitHub web UI, create the App (permission above, webhook inactive,
   installable only on `<ORG>`), install it on `<ORG>`, and generate a private key.
2. Store the key: `aidevops secret set <ORG>_RUNNERS_APP_KEY` (never paste it in chat).
3. Create or reconcile the private-only runner group (needs `admin:org` on `gh`):
   `github-runner-org-helper.sh group-ensure --org <ORG> --name <GROUP> --repos all-private --dry-run`,
   then rerun without `--dry-run`. It refuses any public repo.
4. Verify the key, App owner and installation permissions:
   `github-runner-org-helper.sh verify-key --org <ORG> --app-id <APP_ID> --secret <ORG>_RUNNERS_APP_KEY`
5. Deliver the key to the runner host (mode 600, fingerprint compared):
   `github-runner-org-helper.sh push-key --secret <ORG>_RUNNERS_APP_KEY --host <USER>@<HOST> --dest <KEY_PATH>`
6. Start the pool for the group, then check it:
   `github-runner-org-helper.sh status --org <ORG> --group <GROUP>`

The helper reads the key only from an env var injected by
`aidevops secret NAME -- ...`; it never prints it, puts it in argv or writes it to
a local file. Only the public-key SHA-256 is displayed.

## Current deployment (legacy repo-scoped pool)

Verified on the server during the 2026-06-20 inspection. Concrete repository,
image, and environment names are represented with placeholders so this public
framework documentation does not expose private deployment identifiers.

| Item | Value |
|------|-------|
| Service template | `/etc/systemd/system/github-runner-dind@.service` |
| Service instances | `github-runner-dind@1.service` through `github-runner-dind@8.service` enabled; higher numbers disabled unless deliberately scaling |
| Container names | `github-runner-dind-1` through `github-runner-dind-8` |
| Target repository | `<OWNER>/<REPO>` |
| Runner image | `<OWNER>/github-runner:<TAG>` |
| Runner capacity | 8 large-capacity runners, each 4 CPU / 12 GiB |
| Container isolation mode | `--privileged` |
| Docker storage driver inside runner | `overlay2` preferred; `vfs` only as a temporary fallback |
| Environment file | `/etc/github-runner/<REPO>.env` |

The runner containers are started by systemd and run with Docker-in-Docker
support. A container with the target name must not exist before `ExecStart`; an
existing container is a state conflict and should fail the start instead of being
removed implicitly. Completed ephemeral jobs are replaced after the
`RestartSec=5` delay.

## Runner capacity and labels

### Stale queued workflow watchdog

Pulse runs `.agents/scripts/pulse-stale-queued-runs.sh` as a bounded optional
stage, at most once per hour per Pulse-managed repository. It skips local-only,
maintenance-disabled and contributor repositories and verifies repository write
permission before touching Actions runs. The token must also have Actions write
permission; denied API calls are non-fatal and raw responses are never logged.

| Setting | Default | Behaviour |
|---------|---------|-----------|
| `AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS` | `8` | Minimum queued age in whole hours; `0` disables the stage. |
| `AIDEVOPS_STALE_QUEUED_RUN_DELETE_EMPTY` | `1` | Deletes ghosts (409 from both cancellation endpoints) only when a fresh read shows zero jobs and the logs endpoint returns 404/410; logged as `deleted-empty-ghost`. Any API error keeps the run. `0` disables. |
| `AIDEVOPS_STALE_QUEUED_RUN_DELETE` | `0` | Only `1` allows deletion of stale ghosts that return HTTP 409 from both cancellation endpoints and have jobs or logs. |

Each scan requests one page (up to 100 stale queued runs), rechecks status and
age before writes, requests cancellation, and tries force-cancellation if the
first request returns 409 or leaves the run queued. Logs contain run ID, workflow
name, age in seconds and outcome. A successful request is not reported as a
confirmed cancellation until a subsequent read observes a cancelled conclusion;
a run that started meanwhile is reported as `no-longer-queued` instead.
Cancellation can be asynchronous; `cancellation-pending` is retried next hour.
Reruns (`run_attempt > 1`) are excluded: their original creation timestamp does
not establish the current attempt's queue age. Age is conservatively based on
the original run's `created_at`, not runner capacity or job count.

Unkillable ghosts are logged once per repository/run ID and left alone by default,
except job-less runs with no logs, which hold no work and are deleted.
Deleting runs with jobs or logs removes history: enable it only deliberately. Cadence and
ghost records live under `~/.aidevops/.agent-workspace/pulse/stale-queued-runs/`.
The stage respects Pulse stop/rate-limit flags, the circuit breaker, REST budget
admission and the wrapper's stage timeout. Standalone execution uses the same
quota guard:

```bash
bash .agents/scripts/pulse-stale-queued-runs.sh
```

For operational verification, compare queued Actions runs before and after an
hourly scan and inspect watchdog outcomes. `pulse-wrapper.sh --dry-run` does not
cancel or delete runs. A scan is limited to 100 candidates; additional old runs
are handled by rotating through up to ten pages (GitHub's 1,000-result filtered
search limit) on later scans, even if the first page contains permanent ghosts.
The owner-PID lock is released on normal exit or stage termination and a dead
owner is reclaimed on the next scan.

The launch script supports the enabled service instance numbers only:

| Instances | CPU | Memory | Runner label | Intended jobs |
|-----------|-----|--------|--------------|---------------|
| `1`-`8` | 4 | 12 GiB | `large` | repository CI, Docker-heavy builds, browser/e2e, service stacks |

Repository workflows should not depend on capacity-profile labels. Target the
stable capability labels instead:

```yaml
runs-on: [self-hosted, Linux, X64, dind]
```

The live runners may still carry a `large` label for operator visibility, but CI
should not require it. This keeps scheduling independent from future pool sizing
changes.

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
ExecStartPre=/bin/sh -c 'if /usr/bin/docker inspect github-runner-dind-%i >/dev/null 2>&1; then echo "Refusing to start: container github-runner-dind-%i already exists" >&2; exit 1; fi'
ExecStart=/usr/local/sbin/github-runner-dind-start %i
ExecStop=/bin/sh -c 'out=$(/usr/bin/docker stop github-runner-dind-%i 2>&1); rc=$?; [ $rc -eq 0 ] || { printf "%%s\n" "$out" | grep -qE "No such container|No such object" || { printf "%%s\n" "$out" >&2; exit $rc; }; }'

[Install]
WantedBy=multi-user.target
```

Keep real environment values out of documentation, issue comments, and PRs. The
environment file should contain only server-local configuration and secrets such
as repository URL, runner labels, and runner registration credentials.

`ExecStartPre` is an invariant check, not cleanup. A runner container with the
target name should not exist before `ExecStart`; if it does, startup should fail
so the operator investigates the conflicting state. The launch script performs
the actual container start via `ExecStart`.

`ExecStop` intentionally treats a missing container as success. Ephemeral runner
containers are started with `docker run --rm`, so a completed job can remove the
container before or during `ExecStop`. Do not preflight with `docker inspect`:
that reintroduces a time-of-check/time-of-use race between the existence check
and the stop command. Run `docker stop` directly, then ignore only Docker's
missing-container/object errors so other stop failures still surface. Escape
literal percent signs as `%%` in the systemd unit so systemd does not treat shell
`printf` formats as unit specifiers.

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
- `github-runner-dind@1.service` through `github-runner-dind@8.service` are
  loaded and running or restarting after an ephemeral job exit.
- `docker ps` shows one `github-runner-dind-N` container for each active service.
- GitHub shows the self-hosted runners online for the target repository.

These process checks are necessary but insufficient. A runner can remain
`active`, keep its container `running`, and log `Listening for Jobs` while its
GitHub broker session no longer accepts compatible work. Diagnose that state by
correlating old compatible jobs that remain unassigned (`runner_id: 0` and no
runner name), GitHub runner busy/online state, and local listener state:

```bash
BROKER_HEALTH_REPO=<OWNER>/<REPO> github-runner-broker-health-helper.sh diagnose
```

The helper distinguishes `HEALTHY`, `BUSY_CAPACITY`, `NO_MATCHING_RUNNER`,
`STALE_BROKER_SUSPECTED`, and fail-closed `UNKNOWN_*` results. Reading runner
inventory can require repository administration or fine-grained Actions runner
permission. Permission, network, empty-result, or local-observability failures
never authorize recovery. Repository values and API errors are not printed.

Ephemeral runners can restart after completing a job, so a short-lived
`activating auto-restart` state is not automatically a failure. Treat it as a
failure only when the same instance keeps restarting without becoming online in
GitHub or without creating a replacement container.

Verify resource limits on a specific container:

```bash
docker inspect github-runner-dind-1 \
  --format '{{.Name}} CPUs={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} Privileged={{.HostConfig.Privileged}}'
```

Expected resource values for the enabled runner pool:

| Instances | CPU inspect value | Memory inspect value |
|-----------|-------------------|----------------------|
| `1`-`8` | `CPUs=4000000000` | `Memory=12884901888` |

## Operations

Restart one runner after a failed or stale job:

```bash
sudo systemctl restart github-runner-dind@1.service
```

For suspected stale broker sessions, prefer the broker helper's opt-in canary
mode over a manual pool restart. Configure a root-owned executable adapter that
accepts one validated runner name and maps it to the corresponding service;
then run:

```bash
BROKER_HEALTH_REPO=<OWNER>/<REPO> \
  BROKER_HEALTH_RESTART_ADAPTER=<APPROVED_LOCAL_ADAPTER> \
  github-runner-broker-health-helper.sh repair
```

Recovery acquires a host-local lock, re-reads both evidence planes, rejects any
ambiguous or busy candidate, and restarts at most one idle runner. It succeeds
only when the runner has a fresh GitHub registration ID and the old unassigned
queue shrinks. Cooldown, lock contention, permission loss, or failed canary
verification stops the cycle; never continue with another runner. A new process
or container PID alone is not proof of recovery.

The default cooldown is 30 minutes and the default old-job threshold is 15
minutes. Override them locally with `BROKER_HEALTH_COOLDOWN_SECONDS` and
`BROKER_HEALTH_QUEUE_AGE_SECONDS`. Disable scheduled repair by removing its
explicit adapter/configuration; diagnosis remains read-only. To reset local
cooldown after operator review, remove
`~/.aidevops/cache/github-runner-broker-health.json`. Reverting the helper does
not alter existing runner services.

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

`DISABLE_AUTO_UPDATE=true` is safe only when the canonical runner Docker image is
rebuilt before GitHub deprecates the embedded `actions/runner` version. If the
image is not maintained, ephemeral runners can register but then refuse work
because the bundled runner binary is too old.

1. Check the latest upstream `actions/runner` release before maintenance.
2. Build and publish the replacement `<OWNER>/github-runner:<TAG>` image with
   that runner version under the expected image tag.
3. Restart one canary service instance:

   ```bash
   sudo systemctl restart github-runner-dind@1.service
   ```

4. Verify the canary in GitHub before rotating the pool:

   ```bash
   gh api repos/<OWNER>/<REPO>/actions/runners \
     --jq '.runners[] | {name, status, busy, labels, runner_group_name}'
   ```

   The canary should be `status=online`, not busy unless it picked up a job, and
   should report the current runner version in the GitHub UI/API detail surface
   used by the project.
5. Run a workflow that uses the self-hosted labels.
6. Restart the remaining services only after the canary runner passes.

Do not rotate all runners at once unless the current pool is already broken.

Monitor runner freshness as part of image maintenance. Alert when every runner in
the repository is offline, and separately when OpenCode Agent workflow runs stay
queued longer than the project threshold (for example, 10-15 minutes during an
active work session). A full-pool offline state plus growing queued runs is a CI
capacity incident, not ordinary job latency.

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
| Runner registers, then logs `Runner version vX is deprecated and cannot receive messages` | Runner image tag and embedded `actions/runner` release | Rebuild and publish the runner image with the current upstream runner version, then canary one instance before rotating the pool; do not treat this as a token or network failure. |
| Docker commands fail inside workflow | Container process list for inner `dockerd` | Confirm the runner container is privileged and inner Docker daemon started. |
| Builds are slow or disk-heavy | Inner Docker storage driver and job cache usage | Confirm `overlay2` is active for the inner daemon; migrate off `vfs`, then clean stale job artifacts and review image layers. |
| Container name conflict | `docker ps -a --filter name=github-runner-dind-N` | Startup should fail before replacing the container; inspect whether a job is still running, then remove only verified stale containers manually. |

## Repair checklist

1. Identify the affected instance number from GitHub or `systemctl` output.
2. Confirm whether the instance is genuinely stuck or only between ephemeral jobs.
3. Check the systemd state, current container, and recent logs.
4. Restart only the affected instance first.
5. If registration fails, rotate the registration/access credential in the
   private environment file without printing it to the terminal transcript.
6. If the runner registers but GitHub rejects it as deprecated, rebuild the
   runner image with the current `actions/runner` release instead of rotating
   credentials.
7. If container startup fails, verify the image tag and resource flags in the
   launch script.
8. After repair, confirm GitHub shows the runner online and run a workflow that
   targets the self-hosted labels.

## Documentation hygiene

When copying this runbook to a project repository, replace private repository
names, hostnames, paths, labels, and image names with placeholders unless the
destination is private and approved for operational detail.

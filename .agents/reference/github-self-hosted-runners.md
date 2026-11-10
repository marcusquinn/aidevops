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
public repos stay on GitHub-hosted runners by default. The narrowly scoped
public-repository exception below requires a separate pool and verified access
controls; it never permits enrolling a public repo in the private org pool.

Shared or template workflows (starters synced into public and private repos)
should keep one file for both: `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}`,
and pass the same expression as `runner:` to aidevops reusable workflows. Set
`CI_RUNNER=<POOL_LABEL>` only on private repos in the runner group whose
fork pull-request workflows are off, unless every public-exception prerequisite
below has been verified. The unguarded shared expression above is **not** suitable
for that public exception:

- Use a repository variable (`gh variable set CI_RUNNER --repo <ORG>/<REPO> --body <POOL_LABEL>`).
  On the GitHub Free plan, organization variables are listed for private repos but
  are not passed to their workflows, so the job falls back to `ubuntu-latest`.
- Check fork workflows: `gh api repos/<ORG>/<REPO>/actions/permissions/fork-pr-workflows-private-repos`
  must show `"run_workflows_from_fork_pull_requests":false`.
- Verify: `gh api repos/<ORG>/<REPO>/actions/runs/<RUN_ID>/jobs --jq '.jobs[] | "\(.name): \(.runner_name)"'`
  shows the pool's runner names.

The server-side pool (systemd, rootless or DinD containers, JIT registration) is
operator-owned. `github-runner-org-helper.sh` prepares and verifies its inputs.

### Public repository exception: trusted aidevops CI

Issue #37499 authorizes a dedicated pool for trusted `marcusquinn/aidevops`
jobs, not general public-repository enrollment. This personal-account repository
needs repository-level registration; organization runner groups and
`github-runner-org-helper.sh repo-ensure` do not apply. Keep the private-only
group restrictions above unchanged.

**Checkpoint, not deployed capacity:** Code Quality Analysis has guarded
`vars.CI_RUNNER` selectors for its 11 eligible jobs. The required ShellCheck
matrix name stays unchanged; the Ubuntu 22.04 model-replay boundary verifier
stays hosted because its host policy is part of the verification. Other workflows
and reusable `inputs.runner` hooks remain unchanged pending their own trust audit.
No runner registration, host disk check, variable activation, live routing result,
or 24-hour queue improvement is established by these repository changes.

#### Trust boundary before activation

A `runs-on` expression is routing policy, **not an access-control boundary**.
A fork can edit workflow YAML to request a self-hosted label directly. A
repository-scoped runner will accept matching jobs; labels and `--ephemeral`
alone do not restrict which workflows may request it. First-time-contributor
approval is insufficient, and approving an external workflow does not sandbox
it. Do not enable this exception until an infrastructure owner demonstrates a
non-bypassable admission boundary for untrusted workflow changes, including an
already-approved external contributor. If the personal-account runner model
cannot enforce that boundary, keep public jobs hosted and the exception inactive.
Never use a fork PR against a registered sensitive pool as the first security test.

The selector in `.github/workflows/code-quality.yml` allows only:

| Event | Required evidence | Runner |
|-------|-------------------|--------|
| `push` | `github.ref == 'refs/heads/main'` | Dedicated pool when configured |
| `pull_request` | `toJSON(head.repo.fork) == 'false'` and `head.repo.full_name == github.repository` | Dedicated pool when configured |
| Fork PR, `pull_request_target`, unknown/missing PR metadata, other events | Not eligible | Existing GitHub-hosted fallback |

`toJSON(...fork) == 'false'` deliberately requires Boolean false: plain
`fork == false` also accepts null through Actions' numeric coercion. An empty
`CI_RUNNER` falls back to hosted. A nonempty but offline label queues jobs; it
does not automatically fall back. A same-repository branch is explicitly trusted,
including its workflow changes: restrict branch-creation and automation accounts
accordingly.

Before opting issue/comment automation or reusable jobs in, audit the content
execution path as well as the event name. Public users can open issues and post
comments. Require positive write-author evidence for the triggering action, never
execute an external issue/PR body or fork checkout on the pool, and keep
`pull_request_target` hosted regardless of approval. Put a fail-closed guard
inside the reusable workflow too; caller-provided `inputs.runner` must not let a
fork or target event bypass it. Schedules, dispatches and workflow-run events
remain hosted until separately authorized and audited. Do not mass-replace the
approximately 106 runner expressions without these checks.

#### Isolated ephemeral pool prerequisites

The infrastructure executor must record these checks before registration:

1. Inspect the **actual runner host**, not the worker's local filesystem:
   `df -Pk / <RUNNER_DATA_PARENT> <CACHE_PARENT>` and `df -Pi /`.
   Budget free bytes/inodes for the proposed concurrency, image extraction,
   per-job Docker layers, workspace and cache growth plus an explicit reserve
   for the existing private pool. Account for different mount points and quotas.
   Record observed values, projected peak and minimum reserve; refuse capacity
   additions when the reserve is unknown or insufficient. No automatic pruning
   of other pools is authorized.
2. Use a separate unprivileged runner user, service/container names, workspaces,
   Docker storage and cache directories. Do not mount the host Docker socket,
   private caches, credentials, SSH agents, vault, or other pool directories.
   Separate users/cache paths alone do not isolate a privileged container: do not
   reuse the legacy privileged DinD host as the public security boundary. Use an
   independently isolated disposable VM/host boundary and prevent access to
   private services and registration credentials.
3. Register only to `marcusquinn/aidevops` with a unique capability label, using
   `config.sh --ephemeral --unattended` or equivalent one-job JIT registration.
   Keep the registration broker and its long-lived credential outside the job
   environment; never inject a PAT or App private key into the runner container.
   Mint short-lived registration data outside the job and discard it after use.
   Forward runner diagnostics before destruction, excluding tokens and secrets.
4. Destroy the entire execution environment after **one** job, including writable
   layers and workspace. Do not merely restart the listener. Jobs may receive
   explicitly scoped workflow secrets, but must never inherit persistent host or
   private-repository secrets. Rebuild the baseline image with the tools these
   workflows expect (Node/Bun, Docker, ShellCheck and other existing CI tools);
   a label is not proof of GitHub-hosted image compatibility.
5. Independently verify the admission boundary and disposable cleanup before
   advertising the label. Preserve evidence of both trusted-job admission and
   rejection of malicious workflow changes. Registration/listing permission is
   distinct from ordinary repository push permission; an API 403 stops this
   operational path, not a reason to reuse another pool or request a PAT in chat.

The existing `/usr/local/sbin/github-runner-dind-start` launcher is host-owned,
not a source file in this repository. Do not invent a host target or copy private
deployment configuration into an issue. Apply the prerequisites using the approved
infrastructure inventory and securely provisioned administration access.

#### Activation, acceptance evidence and rollback

Only after all prerequisites pass, set a repository variable with the dedicated
single capability label (not a JSON array):

```bash
gh variable set CI_RUNNER --repo marcusquinn/aidevops --body <PUBLIC_POOL_LABEL>
gh api repos/marcusquinn/aidevops/actions/runners \
  --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

Use `node --test .agents/scripts/tests/test-ci-runner-routing.mjs` for local
selector regression evidence. It models the expressions; it does not replace
Actions evaluation or prove host isolation. Before claiming delivery, record:

- A same-repository PR and main push whose job API reports the dedicated pool's
  runner IDs/names/labels: `gh run view <RUN_ID> --repo marcusquinn/aidevops --json jobs`
  and `gh api repos/marcusquinn/aidevops/actions/runs/<RUN_ID>/jobs`.
- A controlled fork PR with ordinary YAML showing only hosted runners, plus an
  isolated adversarial test showing modified YAML cannot gain admission. Keep
  target workflows hosted; never approve a self-hosted request to make a test pass.
- Comparable pre/post 24-hour samples with workflow/job identity, run attempt,
  creation/start timestamps, sample size and queue-wait median/p95/max. Exclude
  cancellation, provider outages and job-less runs explicitly; separate queue
  delay from execution duration. The issue's historical snapshot is not a fresh
  baseline and the 24-minute runtime is not queue-wait evidence.

Rollback routing with `gh variable delete CI_RUNNER --repo marcusquinn/aidevops`.
New eligible jobs then use hosted fallback. Already queued jobs retain their
selected label; cancel/rerun affected runs only after verifying their exact
identity and purpose. Drain existing jobs before stopping/removing the public
pool; do not touch private-pool services or caches. Keep the issue open until
provisioning, routing security and measured queue results are verified.

### New private plugin repositories

`wp-plugin-new-helper.sh create` calls `github-runner-org-helper.sh repo-ensure
--repo <ORG>/<REPO>` immediately after repository creation, before the first
identity-branch push/PR. The `quality` command also runs this check for existing
repositories. Public repositories and personal accounts are skipped.

The command discovers one private-only, selected-repository group and one custom
label common to its registered runners. It refuses ambiguous groups/labels,
inherited groups, workflow-restricted groups, or fork PR workflows that are not
explicitly disabled. It never disables fork workflows or changes group policy.
An org without selected-repository groups retains the GitHub-hosted fallback. For ambiguous
pools, rerun with `--group <GROUP> --label <POOL_LABEL>`; `--dry-run` performs
reads only and prints the commands without applying them. An empty ephemeral
pool must first register a runner so the label can be verified.

Enrollment uses the single-repository `PUT` endpoint, preserving all other group
members (do **not** use `group-ensure --repos <NEW_REPO>`, which reconciles the
entire membership list). It then sets the repository `CI_RUNNER` variable and
reads back both settings. A permission failure stops plugin creation before the
first PR, preserves the generated repository, and prints an admin retry command;
once discovery succeeds it also prints the exact membership and variable commands.
Run the retry with an authorized token (`admin:org` for classic tokens, or the
equivalent fine-grained runner-group and repository Actions-variable permissions).
After recovery, clone the preserved repository and resume customization/quality;
do not rerun `create` against an existing repository. The final runtime check is
still the first PR's job `runner_name` inspection above, not just variable presence.

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

Pulse cancels queued workflow runs older than `AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS` (default 8h), at most hourly per repository, via `.agents/scripts/pulse-stale-queued-runs.sh`; job-less, log-less ghost runs are deleted. Settings, outcomes, ghost handling and verification: `reference/github-runner-stale-queued-watchdog.md`.

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

## Registry mirror

Ephemeral inner `dockerd` instances start empty and can hit Docker Hub anonymous pull limits (`429 Too Many Requests`, Docker exit code 125). A private pull-through cache passed to the inner daemon with `--registry-mirror` avoids this. Setup, secrets, verification and the `github-runner-org-helper.sh status` mirror check: `reference/github-runner-registry-mirror.md`.


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
| `429 Too Many Requests` from `registry-1.docker.io` before tests start | Inner `docker info` mirror list, cache reachability/access logs and upstream quota | Configure or repair the shared registry mirror, or use authenticated pulls with a read-only token; repeated reruns can exhaust the same shared limit. |
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

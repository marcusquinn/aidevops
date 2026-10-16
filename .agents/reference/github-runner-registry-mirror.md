<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Runner Registry Mirror

Parent runbook: `reference/github-self-hosted-runners.md`.

Each ephemeral inner `dockerd` starts empty. Concurrent jobs sharing a public address can exhaust
Docker Hub's anonymous pull limit before tests start (`429 Too Many Requests`, Docker exit code 125).
Retrying the same workflow does not fix that shared limit.

The operator can run a persistent pull-through cache on the runner host, on the approved private network:

```bash
docker volume create github-runner-registry-cache
docker run -d --restart unless-stopped --name github-runner-registry-cache \
  -p <PRIVATE_HOST_IP>:5000:5000 \
  -v github-runner-registry-cache:/var/lib/registry \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
  registry:2
```

Replace placeholders before running. Restrict port 5000 to the runner network
with host firewall rules; never publish this cache to the internet. For plain
HTTP, use a dedicated trusted private network and explicitly configure the inner
daemon's insecure registry policy if required by its Docker version. Prefer TLS
with a trusted certificate outside that network. The cache address must be
reachable **from inside every runner container**; `localhost` there is the runner,
not the host. Do not bind-mount the host Docker socket or share inner Docker data
directories to implement caching.

In `/usr/local/sbin/github-runner-dind-start`, pass the cache address to the **inner daemon**,
retaining existing flags. This is the inner-daemon invocation fragment, not an outer `docker run`
argument (adapt the runner image's entrypoint/daemon-argument wiring):

```bash
dockerd --storage-driver=overlay2 --registry-mirror=https://<CACHE_HOST>:<TLS_PORT>
```

Use `http://<PRIVATE_HOST_IP>:5000` instead for the private HTTP example above.
Changing only the host daemon does not configure the inner daemons. Canary one
idle service instance, verify it, then rotate the remaining idle instances
gradually as described under Operations; do not interrupt active jobs.

The first cache miss still pulls from Docker Hub and can hit its upstream limit.
Optionally authenticate the cache upstream with a read-only Docker Hub token
stored via `aidevops secret set DOCKERHUB_READ_TOKEN`. Inject the token through
the approved secret-backed service configuration as `REGISTRY_PROXY_PASSWORD`
with `REGISTRY_PROXY_USERNAME`; do not put it in argv, mirror URLs, committed
files or logs. A cache with upstream credentials can serve content accessible to
that account: restrict clients and use an account without private-image access.
Monitor cache disk usage and use registry-supported maintenance, not deletion of
live cache files.

Verify from a canary workflow job, so the commands address its inner daemon:

```bash
docker info --format '{{json .RegistryConfig.Mirrors}}'
docker pull mariadb:10.6
```

On the pool host, `github-runner-org-helper.sh status --org <ORG> --group <GROUP>` reads running
`github-runner-dind-N` containers' inner mirror lists using `docker exec ... docker info`.
It uses the current Docker context, is not group-filtered, and does not discover or SSH to hosts.
It warns for verified empty lists; missing Docker access, containers or readable daemons yield `UNKNOWN`.
Configured does not mean healthy: confirm cache access logs, then pull the same image from a fresh
runner to verify reuse. Finally run a workflow pulling at least ten images across its jobs without 429s.

Alternative: authenticate each job with `docker login --password-stdin` and a secret-store read-only token.
This raises the limit, but fresh daemons still download every image; mirrors avoid repeated upstream downloads.
Neither guarantees unlimited pulls. Mirrors cover Docker Hub, not arbitrary registries or separate BuildKit
daemons; configure those separately. Cache provisioning, secret injection and rolling runner restarts remain
operator-owned, not actions performed by `status`.

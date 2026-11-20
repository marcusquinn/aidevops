# SRT provider-only backend — synthetic prototype (GH#35043)

This is optional qualification tooling, **not an enabled extraction runtime or a
production security certification**. No defaults, worker routes, application
enrichment, credentials or publication paths are changed. Do not configure it for
real workloads until the remaining qualification gates below are closed.

## Contract and dependency

`scripts/worker-egress-srt/backend.mjs` implements the existing backend interface:

```text
probe --policy /absolute/provider-policy.json
run --policy /absolute/provider-policy.json --worker-id ID -- COMMAND [ARG...]
```

The only accepted network policy is `network-tier-helper.sh export-provider-policy
PROVIDER`: one exact hostname, HTTPS/443, default/raw-IP/private-network/loopback
denied. Wildcards, IP literals, multiple hosts and the general worker policy are
rejected. Do not create a parallel allowlist to accommodate a provider client.

The optional package directory pins `@anthropic-ai/sandbox-runtime` **0.0.83**
(Apache-2.0) and every transitive package by npm lock integrity. It is deliberately
not a root dependency and not installed by framework setup. To acquire it in a
reviewed, non-writable-by-workloads location, use `npm ci --ignore-scripts` from
that package directory. Run `npm audit --omit=dev` there, not at the repo root.
Node >=22.12 is required. The package includes architecture-specific static
seccomp helpers; no local build or install scripts are needed.

**Dependency finding, 2026-11-16, resolved by override:** npm audit reported
high-severity GHSA-mrhx-c7xc-m3w5 (Zod collection-validation memory exhaustion)
through `zod@3.25.76`. GH#39020 (#39021) pinned `overrides: { zod: "4.6.6" }`;
`npm audit --omit=dev` now reports 0 vulnerabilities. SRT imports `zod/v3`, which
loads through Zod 4's compatibility subpath; real probes on Ubuntu, NixOS x64 and
macOS arm64 exercised it. That layer has seen synthetic probes only. Do not
suppress advisories, and re-audit at every SRT bump. The adapter bounds
configuration files to 32 KiB and path lists to 64.

## Operator-owned filesystem envelope

Set `AIDEVOPS_SRT_ENVELOPE` to an absolute, non-symlink JSON file owned by the
operator, mode 0600. Do not accept an envelope from a project, issue body or model.
Example shape (all paths are placeholders requiring review):

```json
{
  "schema": "aidevops.srt-envelope.v1",
  "cwd": "/owned/new-output",
  "read": ["/reviewed/executable-closure", "/reviewed/synthetic-input"],
  "write": ["/owned/new-output"],
  "timeoutSeconds": 30,
  "tools": {
    "shell": "/trusted/bin/bash",
    "python": "/trusted/bin/python3",
    "rg": "/trusted/bin/rg",
    "coreutils": "/trusted/bin/env",
    "procps": "/trusted/bin/ps",
    "bwrap": "/trusted/bin/bwrap",
    "socat": "/trusted/bin/socat",
    "setsid": "/trusted/bin/setsid",
    "which": "/trusted/bin/which"
  }
}
```

There is exactly one private, owned, initially empty output directory. Inputs
belong in separate read-only paths. `cwd` is inside output. The backend, its
package, manifest and executables cannot be under a writable root. Broad `/`,
home, `/etc`, `/Users` grants are refused; this does not make other operator-chosen
read roots intrinsically safe. Review them for ambient credentials, evaluator
material, sibling cases, symlinks and executable dependencies before releasing
any data. Do not put secrets in the Nix store. Use fresh output per invocation.

`coreutils` and `procps` identify the packages supplying host-side supervisor
commands; they are executable paths (`env`, `ps`), not directory paths. The
sanitized host PATH is built only from the explicit tools' directories. The
underlying supervisor also needs the usual coreutils commands, including `wc`,
`sleep`, `date`, `dirname`, `rm`, and `tr`. Missing closure members fail the probe.
`bwrap`, `socat`, and `setsid` are Linux-only fields; omit them on macOS.
The Linux canary uses Python 3.12+'s `os.unshare`.

`which` is required on every platform. SRT resolves each dependency by spawning
the external `which(1)` rather than testing the configured absolute path, so an
unreachable `which` makes every lookup report the tool as missing — including
tools that are present and already configured by absolute path. On FHS
distributions this is invisible because the tools share `/usr/bin` with
`which(1)`; on NixOS each package has its own `bin` directory, so omitting this
field fails the probe with `dependencies-not-ready`.

The child inherits no broad host environment, credential files or agent sockets.
The workload runs through `env -i` (the envelope's `coreutils` tool) with an
explicit allowlist copied from the sandbox shell: `PATH`, `HOME`, `TMPDIR`,
`LANG`, and the names SRT 0.0.83 sets itself (the `*_PROXY`/`*_proxy` family,
`NO_PROXY`, `SANDBOX_RUNTIME`, `SRT_SSH_PROXY_COMMAND`, `GIT_SSH_COMMAND`,
`GIT_CONFIG_PARAMETERS`, `CLOUDSDK_PROXY_*`, `DOCKER_HTTP(S)_PROXY`,
`GRPC_PROXY`, `RSYNC_PROXY`, `JAVA_TOOL_OPTIONS`). Framework constants exported
by the supervisor's sourced helpers are therefore not visible to the workload.
The canary check `env-allowlisted` fails if any other name is present, apart from
`PWD`, `SHLVL` and `__CF_USER_TEXT_ENCODING`. SRT's own proxy configuration is generated, never inherited from HTTP_PROXY or
other ambient proxy variables. The workload sees only the owned proxy bridge
sockets on Linux; AF_UNIX creation is denied by the seccomp helper. The backend
keeps its event loop running while children execute so the proxy remains live.
This prototype supplies **no provider authentication**, TLS interception or
credential rewriting. It is not a ready-to-use model-client launch command.

## Platform implementation and qualification

| Platform | Implementation | Evidence / qualification |
| --- | --- | --- |
| Ubuntu/Linux x64 | Explicit bwrap/socat, namespaces, shipped seccomp helper, strict host-side proxy | Real synthetic checks run on Ubuntu 24.04.5, bwrap 0.9.0; see below |
| NixOS x64 | Same Linux backend; tools resolved to explicit immutable store paths, no `/usr/bin/bwrap` assumption | Real synthetic checks run on NixOS 26.05, kernel 6.18.60, bubblewrap 0.12.0, socat 1.8.1.3, no AppArmor profile needed; see below |
| NixOS arm64 | Same Linux backend | No host execution yet; do not infer from x64 |
| macOS arm64 | SRT Seatbelt profile with explicit Mach-service allows removed, IPC grants narrowed, no Apple Events / local binding / weaker isolation | Real synthetic checks, DNS/Mach review and hostile cancellation run on macOS 26.6.2 (GH#38861); `ready: true`, `synthetic-only`; see below |
| macOS x64 | Same Seatbelt backend | Refused: `macos-x64-qualification-pending`; no host execution; do not infer from arm64 |

### Ubuntu / other Linux

Namespace permission is a runtime prerequisite, not implied by a bwrap binary.
Ubuntu 24.04's restricted unprivileged-userns policy can allow creating a userns
while withholding capabilities, causing SRT's nested helper to fail at
`/proc/self/setgroups`. A local bwrap AppArmor profile enabled the complete
namespace sequence on the investigated host. This is **host-specific evidence**,
not permission to install that profile or disable the sysctl on other machines.
The real probe exercises the installed helper. It must fail instead of switching
to weaker nesting, disabling seccomp or falling back to trusted-local.

### NixOS

Supply real tool paths and the reviewed Nix runtime closure in `read`; never
grant the entire `/nix/store` as a convenience. Include dynamic loader/library
and Python standard-library store outputs, plus the shipped seccomp helper.
Use native nixpkgs packages for Node, bash, Python, ripgrep, bubblewrap, socat,
coreutils, procps, util-linux and which. This prototype is not a nixpkgs
derivation.

The 64-entry `read` bound is the binding constraint, because a Nix closure is
structurally larger than an FHS one. On the qualified host the naive closure of
the eight tools is 94 paths and is refused with `bounded-path-list-required`.
Dropping Node, preferring `coreutils` over `coreutils-full` and `util-linuxMinimal`
for `setsid` reduces it to 44 closure paths; with nine tool paths, the seccomp
vendor directory, `which`'s `bin` directory and the three FHS roots that exist on
NixOS (`/usr`, `/bin`, `/lib64` — `/lib` and `/etc/ld.so.cache` do not) the
envelope holds 57 of 64 entries. Treat the remaining margin as small: a nixpkgs
bump that grows the coreutils or Python closure can exceed the bound. Trim the
closure rather than raising the bound, and never substitute `/nix/store`.

`bwrap` and `socat` are absent from a stock NixOS system profile and are not
setuid-wrapped. An unprivileged `nix build` is sufficient and keeps them as
root-owned immutable store paths, but unreferenced store paths are deleted by
`nix-collect-garbage` regardless of age — root them, or install them into the
system profile, before relying on them. `which` is already part of the base
system profile. Record store paths and the nixpkgs `narHash`, not build commands:
the registry can be pinned to a store-path flake whose outputs change after a
`nixos-rebuild`.

### macOS

Upstream SRT's ordinary profile permits system services that can perform DNS on
behalf of a child. Simply blocking outbound TCP is not provider-only containment.
The prototype removes the pinned profile's `allow mach-lookup` rules (including
opendirectoryd libinfo and SecurityServer), then adds explicit denials. Unknown
profile/command shapes fail closed; it does not assume broad denies override
specific allows. Shared-memory, semaphore and preference IPC grants are removed
as well. The host proxy remains outside Seatbelt and resolves the allowed host.
Proxy addresses passed to the child use numeric loopback, not system DNS.

The readiness probe checks eight resolver, network-configuration and trust Mach
services (`macResolverServices` in `backend.mjs`), `getaddrinfo` and the
`/var/run/mDNSResponder` dns_sd socket. Each must work on the host (positive
control) and fail inside the sandbox. Missing services, bootstrap symbols or
system libraries make the probe not-ready.

**Qualification, GH#38861 (macOS 26.6.2 arm64, 2026-11-19):** a wider review
probe found every resolver path refused in the sandbox (`EAI_NONAME`, dns_sd
`EPERM`). Raw UDP/TCP to owned loopback and own-LAN listeners was refused and
nothing was received. All 15 host-reachable services of 18 probed returned
`BOOTSTRAP_NOT_PRIVILEGED`. The sandboxed task held 9 send and 7 receive Mach
rights against 27/8 on the host, and only fds 0–2. Evidence: GH#38861 comments.

**Send-right attribution, GH#39362 (macOS 26.6.2 arm64, 2026-11-20).** The 9
send rights in the sandboxed workload's name space are:

| Right | How it is identified | Receiver |
| --- | --- | --- |
| Task control port | `mach_task_self` | Kernel (own task) |
| Thread control port | `task_threads` | Kernel (own thread) |
| Host name port | `mach_host_self` (unprivileged name port, not `host_priv`) | Kernel |
| System clock service | `host_get_clock_service(SYSTEM_CLOCK)` returns the same name | Kernel |
| Bank voucher | `host_create_mach_voucher` bank-create recipe returns the same name (vouchers are deduplicated) | Kernel |
| Semaphore | Same kernel object type as a freshly created semaphore | Kernel |
| Bootstrap port | `bootstrap_port` | launchd; every lookup returns 1100 |
| 2 self-owned ports, one registered as `TASK_DEBUG_CONTROL_PORT` | Same name also holds the receive right | The workload itself |

Send rights coalesce per port in a name space, so a call that returns an
existing name proves what that name is. Kernel object-type numbers vary between
releases and are not used. The 7 receive rights, including the two self-owned
ports, have the workload as receiver; a receive right cannot reach another
process. The host process additionally holds notifyd
(`com.apple.system.notification_center`, connected at libSystem start-up), plus
any service it looks up. Inside the sandbox those connections are refused.

The probe enforces this. `mach-send-rights-attributed` fails if any send right
in the sandbox is not one of the rows above. The host control looks up the eight
resolver services and requires every returned right to be flagged as
unattributed, which proves that the classifier detects foreign rights. Both
paths were mutation-checked: an injected unknown right gives
`primitive-check-failed`, and a classifier that accepts every right gives
`mach-positive-control-unavailable`.

Rights not held at start but obtainable on request are a residual, not a
regression. These are the task name, inspect and read ports (kernel, own task),
`TASK_ACCESS_PORT` and the `EXC_RESOURCE`/`EXC_CORPSE_NOTIFY` exception handler.
The last two are send rights to other processes that launchd sets at spawn;
neither is a resolver or network service.

**Open finding: launchd introspection through the bootstrap port.** Lookups are
refused, but launchd still answers read-only `launchctl print` requests from the
sandbox. On the qualified host, `print gui/<uid>` returned the same 2,908 lines
as on the host, including service names and per-job environments.
`launchctl getenv` returned no value, and `submit` and `setenv` were refused.
The host control for `submit` created a harmless `/usr/bin/true` job, which was
then removed. In an experiment, setting the bootstrap port to `MACH_PORT_NULL` before
`exec` made `print` fail ("Reentrancy avoided") while Python still ran. That
mitigation is not implemented; see "Before promotion".

No macOS PID namespace exists, and macOS has no `setsid(1)`, so the supervisor
has no child process group there and relies on descendant snapshots. Cleanup
takes a final snapshot before signalling anything; without it, a cancellation
inside the 0.5 s poll interval orphaned the workload to launchd (fixed in
GH#38861). Parent, `setsid` child and double-forked grandchild are reaped on
timeout and on SIGTERM cancellation.

macOS arm64 therefore returns `ready: true` with `qualification: synthetic-only`
and `provider_connectivity: not-tested`, at the same level as Linux. Intel Macs
return `ready: false`, exit 126, `macos-x64-qualification-pending`. There is no
environment-variable bypass for either hold.

**Homebrew closure.** Homebrew binaries load dylibs through
`/opt/homebrew/opt/<keg>` symlinks. `loadEnvelope()` realpaths every `read`
entry, and SRT re-allows `file-read-metadata` only for directories, so a link
node is readable only if the real directory `/opt/homebrew/opt` is granted.
Grant it plus the Cellar directory of each tool's keg and every runtime
dependency (`brew deps --installed --union bash python@<v> ripgrep`). Python's
`_ssl` needs openssl, mpdecimal, sqlite, xz and zstd. Granting
`/opt/homebrew/opt` exposes link names and targets only, not keg contents; it
reveals which packages are installed (maintainer-accepted, GH#38861). Without
the closure the probe fails with `primitive-check-failed` and no recorded checks,
because sandbox stderr is withheld; this is easy to misread as a sandbox defect.

## Checks and scope of a readiness result

Every probe and run rebuilds settings from the immutable-in-memory policy bytes,
checks the installed SRT version and rejects all dependency errors/warnings. It
then exercises synthetic readable/forbidden files, denied writes, IPv4/IPv6 and
Unix-socket listeners with positive host controls, descendant argv preservation,
Linux nested-userns denial or macOS Mach/resolver denial and send-right
attribution, and a live proxy 403 for
a denied reserved hostname. The probe makes **no positive model-provider request**.

One manual, unauthenticated provider check has run (GH#35043, macOS arm64,
2026-11-19). It sent `GET https://api.openai.com/v1/models` through `run` with no
credential in the request or sandbox, and the allowed host answered HTTP 401. In
the same run, `https://example.com/` got the proxy's 403. That proves the allowed
path is live end to end; it is not authenticated provider qualification. The run
also showed that the supervisor's exported framework constants (`shared-constants.sh`
colours, `CI_*`, `AIDEVOPS_REAL_GIT_BIN`) reach the workload environment. They are
not credentials, but they are not yet stripped either (follow-up tracked on GH#35043).

On Linux, a read-denied region can be replaced with private tmpfs. Writing a new
shadow file there can succeed without touching the host. The canary checks the
host file's original contents from outside the sandbox; it does not incorrectly
equate a successful shadow write with a host write. Read-only input writes must
be refused and the input's host contents are checked too.

A successful report binds `policy_sha256` and `envelope_sha256`, uses enforcement
`equivalent` (kernel isolation plus user-space hostname policy), and reports
`qualification: synthetic-only`, `provider_connectivity: not-tested`. These extra
fields are informative: the legacy v1 contract does not enforce them. Therefore
do not set the global `AIDEVOPS_WORKER_EGRESS_BACKEND` to this prototype. Any later
integration must use `required`, never `auto`, and require the full qualification
evidence before releasing credentials or inputs. No extraction role is added.

Commands are argv-quoted, not evaluated as model-generated shell text. The
existing `_sandbox_exec_with_pgkill` supervises foreground execution and owned
descendants. Timeout is 1–60 seconds (default 60); inherited RLIMIT_FSIZE caps each
workload-written file, including captured stdout/stderr, at 8 MiB. This is not an
aggregate disk, RAM, CPU or cost cap. SRT cleanup/reset and owned scratch removal
are attempted independently. No persistent proxy or daemon is installed.

Scoped checks, from the repository worktree:

```bash
node --test .agents/scripts/tests/test-worker-egress-srt.mjs
bash .agents/scripts/tests/test-worker-network-egress.sh
bash .agents/scripts/tests/test-sandbox-command-policy.sh
shellcheck .agents/scripts/sandbox-exec-helper.sh .agents/scripts/tests/test-worker-network-egress.sh
```

Real primitive checks are explicit opt-in, not a new CI gate:

```bash
AIDEVOPS_SRT_REAL_CHECK=1 node --test .agents/scripts/tests/test-worker-egress-srt.mjs
```

They use native tool discovery to build a synthetic envelope and ephemeral local
listeners, never a provider call. `AIDEVOPS_SRT_TEST_SOCAT` can identify a reviewed
non-privileged socat binary; `AIDEVOPS_SRT_TEST_READ` can supply a JSON array of
reviewed extra runtime closure paths for NixOS/macOS. Without it, macOS
Homebrew tools get the closure above computed with `brew deps`. An incomplete
closure must fail, not widen itself. On NixOS, native discovery alone exceeds the 64-entry
bound: supply the trimmed closure described above through `AIDEVOPS_SRT_TEST_READ`
and keep the minimal coreutils and util-linux variants ahead of the system
profile on `PATH`. Inspect bounded-operation cleanup receipts as well as
test exit status; child exit alone does not establish absence of descendants.

## Proxy resolved-address, redirect and protocol qualification (GH#39361)

Synthetic and offline; no real DNS, `/etc/hosts` or network. SRT 0.0.83 has no
resolver option, but its resolved-address guard calls `node:dns` `lookup` when
the guard is built. The tests in `tests/test-worker-egress-srt.mjs` swap that
function (plus `syncBuiltinESMExports()`) for a fixture mapping the allowed test
name to chosen addresses, start the real `SandboxManager` proxies with
`settings()`, and drive the HTTP and authenticated SOCKS5 ports directly. They
run on Linux or macOS wherever SRT initializes (needs `rg`, plus `bwrap` and
`socat` on Linux) and are not part of the opt-in real-platform run. Result of a
real Linux x64 run:

| Case | Result |
|------|--------|
| Allowed name resolving to 10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7, 127/8, `::1`, 169.254/16, fe80::/10, 0.0.0.0, or IPv4-mapped loopback, RFC 1918 and link-local | CONNECT 403 and SOCKS reply 2 (not allowed) for every class |
| Positive control: a test-only variant that carves owned loopback listeners out of the guard | Allowed name reaches the owned listener, proving the fixture resolver and dial path |
| HTTP 302 from the allowed host to another host | Follow-up request to the other host is refused with 403 |
| Allowed name on ports 80, 22, 25, 8443 or any other non-443 port, via CONNECT, plain HTTP or SOCKS | Refused (403 / SOCKS reply 2) |
| Raw non-TLS bytes on an allowed authority | Documented behaviour: tunnelled opaquely. SRT does not inspect or terminate TLS here, so the only refusal is by host and port; the bytes reach only the one allowed host on 443 |

Loopback, unspecified and link-local are denied by SRT 0.0.83 by default
(`DENIED_CLASSES` in its resolved-address guard, including IPv4-mapped forms).
`settings()` also lists them in `deniedResolvedAddresses` so the policy does not
depend on that default; the policy unit test asserts it.

## Before promotion

NixOS x64 host testing is complete under
[GH#38701](https://github.com/marcusquinn/aidevops/issues/38701), a sub-issue of
GH#35043. macOS arm64 synthetic qualification is complete under
[GH#38861](https://github.com/marcusquinn/aidevops/issues/38861). Neither
qualifies the other architecture.

Still required, tracked as GH#35043 follow-ups: NixOS arm64 and macOS x64
evidence; closing launchd introspection through the inherited macOS bootstrap
port (send rights attributed under GH#39362); independent review
of filesystem composition; minimal credential handling and an explicit
extraction-role envelope. Model/settings, wall-time/resources/cost, input release
and comparison-attempt approval remain separate decisions.

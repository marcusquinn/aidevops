---
description: Project-scoped local prospecting REST and read-only MCP service
---

# Prospecting service

The prospecting service exposes the same private project and ranked-lead read
model used by `prospecting-project-helper.py`. It also projects stored Reddit
evidence, bounded competitor/themes, local activity, and recorded usage. Every
data route requires an explicit project-scoped credential. The only anonymous
route is non-sensitive `/v1/health`.

The service is local and optional. It does not use Lurk, AnyAPI, hosted identity,
remote tracking, or automatic assistant configuration. Evidence and matching
phrases are untrusted data, not agent instructions.

## Components and versions

- REST schema: `configs/prospecting-openapi.json`, API
  `aidevops.prospecting-api/v1`.
- REST runtime: Python standard library plus the existing prospecting domain
  modules; no optional dependency is needed.
- MCP runtime: the official Python `mcp` SDK pinned in
  `configs/prospecting-requirements.txt`. The adapter uses FastMCP over stdio and
  calls the loopback REST API, so MCP and REST preserve one authorization and
  response contract.
- Auth metadata has its own schema version and private mode-0600 SQLite file.
  It does not weaken or migrate the prospecting store.

The official SDK is intentionally optional because REST-only operators should
not inherit an MCP dependency graph. Install the requirements in an isolated
virtual environment only after reviewing the pin. The adapter fails closed when
the SDK or bearer credential is absent.

## Start locally

```bash
python3 .agents/scripts/prospecting-service-helper.py --help
python3 .agents/scripts/prospecting-service-helper.py \
  --store PRIVATE_DIR start --bind 127.0.0.1 --port 8765
```

`serve` runs in the foreground; `start` writes only to a private service log and
starts the same command. `stop` validates the recorded PID against the service
command before signalling it. Loopback is the default. A non-loopback bind is
rejected unless `--allow-external`, a TLS certificate, and a TLS key are all
explicitly supplied. That technical gate is not a public-launch approval.

Optional UI assets are served only from an explicit `--ui-dir`. The handler
allows `.html`, `.css`, `.js`, `.json`, and `.svg`, rejects symlinks and path
escape, sends `nosniff`, and applies a same-origin CSP. No remote asset is
allowed.

## Credentials

Provisioning writes the secret once to a new mode-0600 output file; it never
prints the secret to stdout. Move the value into the normal secure credential
store, then remove the one-time file according to local policy.

```bash
python3 .agents/scripts/prospecting-service-helper.py --store PRIVATE_DIR \
  key-create --project PROJECT_ID --output PRIVATE_OUTPUT.json

python3 .agents/scripts/prospecting-service-helper.py --store PRIVATE_DIR \
  session-create --project PROJECT_ID --ttl 3600 \
  --output PRIVATE_OWNER_OUTPUT.json
```

Read keys contain only `read` permission and explicit project IDs. Rotation
creates a new key and revokes the prior non-secret credential ID atomically.
`revoke CREDENTIAL_ID` invalidates a key or owner session immediately.

Owner sessions are created only by this local operator command. HTTP clients
cannot turn a boolean into owner approval or mint credentials. Mutations require
the owner cookie, matching CSRF header, loopback Host, and same-origin Origin.
Sessions expire after at most 24 hours.

## REST boundaries

Read routes cover:

- projects and non-secret project detail;
- filtered, cursor-paginated leads and lead detail;
- stored Reddit observations with explicit ranking coverage;
- bounded competitors/themes with source coverage;
- disposition/job activity and usage/cost records.

Out-of-scope and unknown project IDs return the same `404`. Queries are
parameterized, result counts and response bytes are bounded, and failures are
sanitized. Read requests do not update the store, reserve budgets, or start jobs.

Owner routes support project creation, profile/discovery compare-and-swap edits,
lead disposition compare-and-swap edits, local alert settings, and typed manual
job requests. Job kinds and budgets are validated server-side and request IDs
are idempotent. A request records intent only; execution remains a separate
routine authority boundary. There is no generic URL, filesystem, SQL, shell,
post, DM, or command endpoint.

## MCP client

Set `AIDEVOPS_PROSPECTING_API` to the loopback service URL and inject
`AIDEVOPS_PROSPECTING_AUTH` from secure local storage as the complete `Bearer …`
header value. Start:

```bash
python3 .agents/scripts/prospecting_mcp.py
```

The MCP server provides only `list_projects`, `get_project`, `list_leads`,
`get_lead`, `get_reddit_seo`, `get_insights`, `get_activity`, and `get_usage`.
Each tool has official read-only, non-destructive, idempotent, closed-world
annotations. Python signatures and the SDK reject extra arguments. The adapter
rejects non-loopback API URLs and has no mutation or paid-job tools.

Configure the command manually in the chosen assistant. Do not put the bearer
value in command arguments or committed runtime configuration, and do not
enable/register this server automatically.

## Verification and recovery

```bash
python3 .agents/scripts/prospecting-service-helper.py --help
python3 .agents/scripts/tests/test-prospecting-api.py
.agents/scripts/linters-local.sh --changed
```

Tests use synthetic credentials and isolated stores. They cover project scope,
unknown-project non-disclosure, pagination, malicious source text remaining
data, immediate revocation, denied read-key writes, CSRF/Origin checks,
idempotent bounded job requests with no execution/spend, SSRF rejection, static
path traversal, an actual loopback HTTP service, and the MCP REST adapter.

If auth or domain schema versions are unsupported, startup fails instead of
migrating to weaker behavior. Preserve the private stores for audit. Revoke
credentials before explicit teardown; removing service code does not alter
prospecting evidence or operator dispositions.

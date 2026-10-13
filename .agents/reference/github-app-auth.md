# GitHub App Auth and API Budget Routing

## Goal

User-owned GitHub Apps give aidevops a separate GitHub auth principal per installation. The framework uses that principal for REST-equivalent reads/searches while preserving PAT/`gh` auth for native GitHub CLI operations and GraphQL-only semantics.

## Configuration

The configuration below is the existing global routing policy. For opt-in,
read-only Pulse authentication per repository, use the named profiles described
under **Repository-scoped Pulse reads**; do not enable global routing just to use
a named profile.

Copy `.agents/configs/github-app-auth.json.txt` to `~/.config/aidevops/github-app-auth.json` and fill only non-secret identifiers:

```json
{
  "enabled": true,
  "app_id": "123456",
  "installation_id": "987654",
  "private_key_path": "$HOME/.config/aidevops/keys/github-app.pem"
}
```

Private key material must never be committed. Store the PEM outside repositories with `chmod 600`, or store only the key path with `aidevops secret set GITHUB_APP_PRIVATE_KEY_PATH` and set `private_key_path_secret` in the JSON template.

Environment overrides are available for automation:

- `AIDEVOPS_GITHUB_APP_ENABLED=1`
- `AIDEVOPS_GITHUB_APP_ID=<app-id>`
- `AIDEVOPS_GITHUB_APP_INSTALLATION_ID=<installation-id>`
- `AIDEVOPS_GITHUB_APP_PRIVATE_KEY_PATH=<pem-path>`
- `AIDEVOPS_GITHUB_APP_REST_FIRST=0|1`

## Permission matrix

Use least privilege and add scopes only when a workflow proves it needs them.

| Permission | Minimum | Used for |
| --- | --- | --- |
| Metadata | Read | Repository identity and installation lookup |
| Issues | Read/write | Issue list/view/comment/edit/status label routes |
| Pull requests | Read/write | PR list/view/create metadata routes |
| Contents | Read by default; write only for app-scoped push automation | Repository metadata, future app-scoped content writes |
| Checks | Read | Check suites and check runs |
| Commit statuses | Read | Status contexts |
| Actions | Read when enabled | Workflow run/check log inspection |

## Routing policy

`github-app-auth-helper.sh` classifies operations by semantics before choosing a pool:

| Operation class | Examples | Pool | Auth preference |
| --- | --- | --- | --- |
| GraphQL-only | node IDs, sub-issue mutation, Project v2 | GraphQL | `gh`/PAT unless a caller explicitly uses an app token |
| REST core | issue/pr view/list, labels, comments, statuses, checks | REST core | GitHub App when configured; otherwise `gh`/PAT REST fallback |
| REST search | issue search/list with `--search` | REST search | GitHub App when configured; otherwise `gh`/PAT search fallback |
| Native `gh` fallback | high-level create/edit/merge flows | `gh`/PAT | Existing `gh` auth first, REST fallback on GraphQL exhaustion |

Default policy is REST-first for REST-equivalent operations when app auth is configured. Set `AIDEVOPS_GITHUB_APP_REST_FIRST=0` to route through REST only when the live GraphQL budget is below `AIDEVOPS_GH_REST_FALLBACK_THRESHOLD`.

## Runtime behavior

- Installation tokens are cached under `~/.aidevops/cache/github-app/` with `0600` files and refreshed before expiry.
- Rate-limit snapshots are cached per auth principal and pool for `AIDEVOPS_GITHUB_APP_RATE_LIMIT_CACHE_TTL` seconds.
- `gh-api-instrument.sh` records path, caller, auth mode, API pool, route decision, and remaining budget.
- When no app is configured, all existing PAT/`gh` behavior remains unchanged.

## Commands

```bash
aidevops github-app-auth status --json
aidevops github-app-auth route issue-list --json
aidevops github-app-auth rate-limit --json
```

Status and route commands never print tokens or private key material. The `token` subcommand refuses to print an installation token unless `AIDEVOPS_GITHUB_APP_ALLOW_TOKEN_STDOUT=1` is set for an automation context that captures stdout.

## Verification

Run the focused tests after changing this area:

```bash
python3 .agents/scripts/tests/test_pulse_repo_auth.py
bash .agents/scripts/tests/test-github-app-auth-helper.sh
bash .agents/scripts/tests/test-gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh
shellcheck .agents/scripts/github-app-auth-helper.sh .agents/scripts/gh-api-instrument.sh .agents/scripts/shared-gh-wrappers.sh .agents/scripts/shared-gh-wrappers-rest-fallback.sh .agents/scripts/shared-gh-wrappers-status.sh
```

## Repository-scoped Pulse reads

For the user setup agreement, naming, CLI and explicit migration, see
[Repository GitHub authorization](github-auth.md). This section documents the
runtime boundary; the earlier global helper is a separate integration.

Keep the existing `pulse` boolean and scheduling fields in `repos.json`. Configure
`github_auth.pulse.read` and `github_auth.pulse.write` inside the selected entry.
This stage supports only App reads and inherited writes. It does not change
scheduling, GitHub permissions or interactive identity.

In `~/.config/aidevops/github-auth.json`, add a named profile (non-secret
identifiers and a local key reference only):

```json
{
  "profiles": {
    "team-pulse": {
      "app_id": "123456",
      "client_id": "YOUR_APP_CLIENT_ID",
      "private_key_path": "$HOME/.config/aidevops/keys/team-pulse.pem",
      "permissions": {
        "metadata": "read",
        "issues": "read",
        "pull_requests": "read"
      }
    }
  }
}
```

The private key must be a current-user-owned regular file with no group/other
permissions (use `0600`). Symlink keys are rejected. Each trusted operator may
use a different key of the same App: all such keys have App-wide authority;
they are not per-user permission boundaries. Keep keys out of Git and chat.

```bash
aidevops github auth set OWNER/REPO --consumer pulse --operation read --profile team-pulse --installation-id 987654
aidevops github auth status OWNER/REPO
aidevops github auth check OWNER/REPO --consumer pulse
aidevops github auth usage --consumer pulse --since 1h
```

`set` validates local configuration and atomically updates the registry under
its existing lock. It does not install an App, mint a token, enable Pulse or
alter other repository settings. `status` is offline. `check` mints/reuses a
scoped installation token and performs a repository metadata read through the
same gh shim as Pulse. No command prints a token or private key. Configuration
errors, duplicate repository entries and unsupported providers fail closed.
`usage` summarises `gh-api-calls.log` for the window by credential
(`by_auth_mode`) and by route reason (`by_auth_reason`, below); it reads only
local metadata and never contacts GitHub.

### Quota model

Installation access tokens use the installation's own primary rate limit
(15,000/h on GitHub Enterprise Cloud organizations), separate from the
maintainer's personal 5,000/h budget shared by PATs, `gh auth` and user-to-server
App tokens. The budget is per installation, not per App or token: one App
installed in two organizations, or two Apps in one organization, have separate
budgets; every token minted for one installation, on any host or OS user,
shares it. Secondary limits still apply. Source: GitHub "Rate limits for the REST API",
sections "Primary rate limit for authenticated users" and "Primary rate limit
for GitHub App installations".

### Read/write boundary

`pulse-wrapper-config.sh` enables the repository resolver; every process that
loads Pulse configuration (wrapper, merge routine, merge webhook receiver,
complexity scan, cleanup helpers) inherits it, so all their child gh commands
are routed. Normal interactive gh commands are
unaffected. The resolver runs before shim
quota probes and REST translations and then re-enters the same shim, retaining
its existing safety policies and instrumentation.

- Native issue/PR lists/views and supported repository, search, workflow, run
  and release reads use the selected App. REST GET/HEAD and explicit GraphQL
  query documents are reads; GraphQL POST is not automatically a write.
- Recognized writes and mutations retain the caller's existing auth path. This
  is operation routing, not a fallback after an App failure. Git transport is
  not changed. The profile rejects write permissions.
- Account-level `/user` reads retain the maintainer identity. Unscoped
  `/rate_limit` probes retain the existing account budget; use explicit
  `AIDEVOPS_PULSE_REPO` context to inspect an installation's budget instead.
  These are explicit account operations, not repository-read fallbacks.
- Explicit App reads never retry with personal auth on mint failure, 401, 403
  or rate limiting. Missing keys fail even if a token remains in the cache.
- An App read requires one explicit repo: `--repo/-R`, a
  `/repos/OWNER/REPO/...` REST endpoint, explicit GraphQL `owner`/`name`
  variables, or `AIDEVOPS_PULSE_REPO=OWNER/REPO` for a repository-scoped
  caller. CWD is not an authority source.
- Every invocation that cannot be proven an App read keeps the existing auth,
  unchanged, and is labelled in `gh-api-calls.log` field 18 so coverage gaps
  stay visible without breaking unrelated Pulse stages:

  | Reason | Meaning |
  |--------|---------|
  | `app` | Repository App installation token |
  | `write` / `local` / `account` | Classified non-read operation |
  | `unclassified` | Unknown command form, extension or GraphQL `--input` |
  | `unscoped` | Read without exactly one repository (conflicts, global search) |
  | `not-configured` | Repository has no App read selection, or explicitly inherits credentials |
  | `other-host` / `absolute-url` / `explicit-auth` / `verbose` | Caller pinned transport the App read cannot honour |

  Empty field 18 (`unrouted` in reports) means the resolver was not enabled.
  This is operation routing, never a fallback: once a read is selected for the
  App, failure does not retry with personal auth.

### Lifetime and rollback

Signing and exchange are shared with the legacy helper through
`github_app_auth.py`; JWTs use a Bearer header held in memory, not process argv.
The resolver verifies App/installation/owner identity before minting and narrows
tokens to one repository and the profile's read permissions. It supplies a token
only to the child gh process, with an empty temporary gh configuration and no
personal credential fallback. Authentication selection happens per invocation,
not once at startup of the long-lived scheduler.

Tokens are cached in `0600` files in a `0700` directory. The key includes App,
installation, repository, permissions and key-material digest. Refresh starts
with less than two minutes remaining. A bounded Python lock serializes refresh;
its non-inheritable descriptor closes before starting gh. API budgets remain
installation-scoped, not per token, repository or operator. A single long gh
invocation does not renew credentials mid-request. No HTTP retries or new
cross-host coordination system are introduced.

Rotate a key by generating and securely deploying a replacement, running
`auth check`, then retiring the old key. Removing a key does not revoke tokens
already issued with it. Cache refresh is not evidence of server-side revocation.

Explicit rollback:

```bash
aidevops github auth clear OWNER/REPO --consumer pulse --operation read
```

This resets only the read route to explicit `inherit`, restoring its existing routing;
it does not revoke tokens or change the `pulse` flag. Disable Pulse separately
if automation must stop. There is no automatic rollback to personal credentials.

### Verification evidence and boundaries

The development POC exercised a single selected repository and read-only App
installation. With a deliberately invalid personal token in the parent, native
issue/PR reads and the real `gh_issue_list` shared wrapper passed through the new
resolver. After revocation, a direct REST request returned 401 and the shim
failed; invalid cached credentials and a missing key also failed. Test tokens
were revoked and the temporary configuration/cache removed. No production
Pulse configuration, App permissions or repository content was changed.

Focused tests cover operation/scope classification, unchanged write credentials,
no personal retry, registry preservation, cache refresh/rotation/scope separation
and private-file/lock safety. This does not establish full scheduler readiness:
global/unscoped queries, additional permission needs, git operations, worker
actor assumptions and multi-host claims require separate verification before
cutover. An earlier pre-resolver revocation probe returned success immediately
after revocation; its cause was not established and is not attributed to a
personal fallback. The isolated resolver probe above supplies the current
negative-path evidence.

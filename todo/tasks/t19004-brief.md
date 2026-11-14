<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Discovery pass: no manifest-flow or bulk-bind command exists (`rg app-manifests|bind` in `github_auth*.py`); related merged work GH#38150 (actions:read) and GH#38273 (advisory) left setup manual.
- [x] Tier: `tier:standard`. Additive CLI over existing signing, exchange, profile and route validation.

## What

Add a near-zero-attention setup path for Pulse GitHub App read routing:

1. `aidevops github auth app create --owner OWNER [--name NAME]` — GitHub App Manifest flow. A loopback-only page (127.0.0.1, random port, one-time `state`) auto-posts a read-only manifest to GitHub; the operator clicks **Create GitHub App**; the CLI exchanges the one-time code (`POST /app-manifests/{code}/conversions`), writes the PEM to `~/.config/aidevops/keys/<slug>.pem` (0600, O_EXCL, never printed), creates the named profile with the existing profile code, and prints the install URL.
2. `aidevops github auth app bind --profile NAME [--owner OWNER] [--dry-run]` — discovers the App's installations with a JWT, lists each installation's covered repositories, and binds only covered, pulse-enabled, non-local registry entries (read → github-app, write → inherit) in one locked registry write. Uncovered repos keep inherited auth.

## Why

Evidence from one runner, 24h to 2026-11-14T20:30Z:

- `aidevops github auth advise --since 24h`: 80,868 routable REST attempts; `routable_known_quota_cost` 63,338 of 77,093 (82%); `rest_core_min_remaining` 0; all 5 pulse owners lack App read routing; 0 of 70 pulse repos bound.
- `pulse.log`: 13 deferrals of `dispatch_max` at `rest=emergency:0/5000`; 8 of 33 cycles ended `blocked/rest-core-quota` with zero dispatch while 121 ready `auto-dispatch` issues waited (parent GH#38332 phase 4).
- The binding machinery exists (GH#38150, GH#38273) but setup is manual: create App in the web UI, choose 7 permissions, generate and move a PEM, copy App ID and installation ID, then `aidevops github auth set` once per repository (70 here). That is the barrier, not the routing.

## How

- New modules: `.agents/scripts/github_auth_setup.py` (parser, create orchestration), `.agents/scripts/github_auth_app_manifest.py` (loopback Manifest flow, conversion, key save), `.agents/scripts/github_auth_app_bind.py` (installation discovery, planner, locked bind). Split to stay under qlty file-complexity and parameter/return smells. Wire `app create|bind` into `.agents/scripts/github_auth_cli.py` (`repo_free_action`).
- Reuse: `github_app_auth.jwt/exchange/api/atomic_json/private_read`, `DEFAULT_PULSE_READ_PERMISSIONS`, `github_auth_profiles.manage_profile`, `github_auth_config.registry/registry_lock/settings`, `github_auth_policy.validate_routes`.
- Manifest: `public: false`, no webhook (`hook_attributes.active: false`), `default_permissions` = read for `DEFAULT_PULSE_READ_PERMISSIONS`, no events, `redirect_url` = loopback callback. Org owners post to `https://github.com/organizations/<org>/settings/apps/new`, users to `https://github.com/settings/apps/new`.
- Bind skips: legacy `pulse_auth` entries (needs `migrate`), `local_only`, non-pulse, owners without an installation, repos outside a `selected` installation, suspended installations. Report each skip reason.
- Docs: add a "Fast path" section to `.agents/reference/github-auth.md`.

## Files Scope

- .agents/scripts/github_auth_setup.py
- .agents/scripts/github_auth_app_manifest.py
- .agents/scripts/github_auth_app_bind.py
- .agents/scripts/github_auth_cli.py
- .agents/reference/github-auth.md
- TODO.md

## Acceptance

- `app bind --dry-run` with a valid profile lists per-repo decisions and writes nothing.
- `app bind` writes routes only for covered repos; `aidevops github auth check OWNER/REPO --consumer pulse` reports `read_check: passed` for a bound repo.
- Negative: bind refuses an unknown profile; never overwrites a legacy `pulse_auth` entry; never binds a repo absent from a `selected` installation; PEM is never echoed and an existing key file is never overwritten.
- `app create` refuses a mismatched or missing `state` and binds only to 127.0.0.1.

## Verification

- `python3 -m py_compile .agents/scripts/github_auth_setup.py .agents/scripts/github_auth_app_manifest.py .agents/scripts/github_auth_app_bind.py .agents/scripts/github_auth_cli.py`
- `qlty smells --no-snippets` on the three new modules reports no smells.
- `bash .agents/scripts/tests/test-github-app-auth-helper.sh`
- Operator-run end-to-end: `app create`, install, `app bind`, `auth check`, then `aidevops github auth usage --since 1h` shows App-mode reads.

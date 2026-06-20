<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI helper/API contract

## Status

Accepted for planning. This contract defines how the aidevops GUI local API wraps
existing aidevops helpers and configuration surfaces. It does not implement new
helper commands.

## Goals

- Keep aidevops helpers, config files, git platforms, and secret backends as the
  sources of truth.
- Make the first dashboard read-only with typed JSON responses.
- Define the write-action shape before any GUI route can mutate local state.
- List helper JSON and validation gaps as follow-up issue candidates.

## Sources of truth

The GUI API is an adapter layer over the source-of-truth map in
`docs/gui/control-plane.md`. It must not keep a second mutable copy of helper
state.

| Surface | Current authority | GUI reads | GUI writes |
|---------|-------------------|-----------|------------|
| Setup/status | `setup.sh`, `aidevops status`, version files, deployed agent paths | Installed versions, path health, helper availability, update posture | Later: invoke setup helpers through a dry-run/validate/apply action |
| Settings/config | `settings-helper.sh`, `config-helper.sh`, `~/.config/aidevops/settings.json`, config templates | Effective settings, precedence source, validation errors | Later: validated settings changes through `settings-helper.sh set` |
| Repo registry | `~/.config/aidevops/repos.json`, repo helpers, git platforms | Registered repos, parent dirs, repo health, sync status | Later: validate, back up, atomically replace, then reconcile |
| Secrets | `secret-helper.sh`, gopass, Vaultwarden, OS keychains, credential files | Backend status and secret names/status only | Write-only entry/rotation flows; never return values |
| Routines | routine definitions, scheduler helpers, TODO/routine docs | Definitions, schedules, next/last run summaries, failure class | Later: plan, install, pause, resume, edit through routine adapters |
| OpenCode | generated OpenCode config, aidevops plugin, session DB/log refs | Runtime version, generated config state, session summaries | Edit upstream aidevops config only; never edit generated entries directly |
| Cloudron | `cloudron-helper.sh`, Cloudron app/package state, Cloudron API | Login/server/app/package status and deployment mode | Later: scoped Cloudron actions with explicit confirmation |
| Git platforms | `github-cli-helper.sh`, `gitlab-cli-helper.sh`, `gitea-cli-helper.sh`, `git-platforms-helper.sh` | Auth state, repo/issue/PR summaries, runner/check status | Later: create guided briefs/PRs through existing git workflows |

Configuration precedence must be preserved in every response:

1. Environment variables.
2. User config under `~/.config/aidevops/`.
3. Built-in defaults and deployed framework templates.

When a value is generated, such as OpenCode plugin config, the response must
identify the upstream editable input and mark the generated file as read-only.

## Local API boundary

The browser talks only to the typed local or Cloudron API. The API talks to
allowlisted adapters that build exact argument vectors for helpers. Routes must
not accept shell strings, helper names, environment variables, or arbitrary paths
from the browser.

Every route declares:

- operation ID;
- read, write, or destructive classification;
- accepted parameter schema;
- source-of-truth surface;
- helper adapter and exact command pattern;
- redaction policy;
- audit fields;
- follow-up issue if the helper lacks JSON or validation output.

## Shared response envelope

Read routes return this envelope. Empty or partial data is valid when the source
is not configured.

```json
{
  "ok": true,
  "operation_id": "setup.status.read",
  "source": {
    "surface": "setup",
    "authority": "aidevops helpers",
    "path_refs": ["~/.config/aidevops/settings.json"]
  },
  "data": {},
  "warnings": [],
  "errors": [],
  "redactions": ["secret_values"],
  "observed_at": "2026-06-21T00:00:00Z"
}
```

Errors use stable non-secret classes such as `missing_config`,
`helper_unavailable`, `invalid_json`, `auth_missing`, `rate_limited`,
`permission_denied`, and `unknown_state`. Raw helper stderr may be stored as a
local evidence pointer after redaction, but API responses should return concise
classes plus remediation guidance.

## Read-only dashboard commands

These routes are enough for the first dashboard. Helpers without JSON output
should gain JSON/status modes in later child issues; the first scaffold may use
fixtures or strict parsers until those helper upgrades land.

| Route | Operation ID | Adapter command pattern | Response data |
|-------|--------------|-------------------------|---------------|
| `GET /api/status` | `setup.status.read` | `aidevops status` plus version/path checks | aidevops version, runtime versions, deployed path health, update posture |
| `GET /api/settings` | `settings.effective.read` | `settings-helper.sh list --json` | effective setting values, source, defaults, validation state |
| `GET /api/config` | `config.effective.read` | planned `config-helper.sh status --json` | config files, template drift, precedence, validation errors |
| `GET /api/repos` | `repos.registry.read` | planned `repo registry/status --json` adapter over `repos.json` | repos, parent dirs, git remotes, dirty/default-branch/sync status |
| `GET /api/secrets/status` | `secrets.status.read` | `secret-helper.sh status` plus planned `list --json` | backend, configured names, missing/unknown health, no values |
| `GET /api/routines` | `routines.status.read` | planned `routine-helper.sh status --json` | routine definitions, scheduler backend, next/last run, failure class |
| `GET /api/opencode` | `opencode.status.read` | plugin/version/session adapters | OpenCode version, plugin state, generated config health, session count refs |
| `GET /api/cloudron` | `cloudron.status.read` | planned `cloudron-helper.sh status --json` | server auth state, app/package state, deployment mode, non-secret errors |
| `GET /api/git-platforms` | `git.platforms.status.read` | planned platform helpers with `--json` | provider auth state, repo visibility, checks/runners summary |
| `GET /api/capabilities` | `capabilities.read` | agent/source index helpers | capability cards with doc refs, setup requirements, verification refs |

Secrets are status-only from the browser perspective. API responses may show
that a secret named `GITHUB_TOKEN` is configured, missing, stale, or unchecked,
but must not return values, prefixes, suffixes, diffs, clipboard payloads, or raw
credential file content.

## Future write-action contract

All writes use action manifests instead of direct helper endpoints.

```json
{
  "action_id": "repos.registry.update",
  "risk": "high",
  "mode": "dry_run",
  "target": {"surface": "repos", "path_ref": "~/.config/aidevops/repos.json"},
  "params": {},
  "confirmation": null
}
```

Write actions must support the same lifecycle:

1. **Dry-run:** resolve the target, show the intended diff or operation summary,
   classify risk, and report required confirmation.
2. **Validate:** schema-check parameters and current on-disk state before any
   mutation. Reject unknown fields and secret-shaped values where not allowed.
3. **Backup:** write an atomic timestamped backup for file-backed state before
   applying changes.
4. **Apply:** call the exact helper adapter or perform an atomic replace with
   restrictive permissions. Never use browser-provided command strings.
5. **Verify:** re-read the source of truth and prove the expected state changed.
6. **Rollback:** restore from the backup or provide precise manual rollback
   instructions when automatic rollback is unsafe.
7. **Audit:** emit a redacted audit event with actor, operation ID, risk, target,
   helper adapter, outcome, timestamps, and evidence pointer.

High-risk or destructive actions require server-enforced confirmation tied to
the resolved action, target, and risk class. Confirmation text from the browser
is not authorization by itself.

### Repo registry writes

`repos.json` writes are high risk because they affect worker routing, repo sync,
and progress dashboards. The GUI must:

- validate the full file against the registry schema before and after changes;
- refuse to mutate invalid current JSON until the user chooses a recovery path;
- create a backup in the aidevops config backup location;
- write to a temporary file, fsync where available, then atomically rename;
- preserve unknown fields unless the schema explicitly migrates them;
- verify the changed repo entry by re-reading `repos.json` and checking the git
  remote or local path when available;
- emit a redacted audit event.

## Helper gap list for child issues

Create later child issues for these helper/API gaps before the dashboard depends
on live parsing:

- Add `--json` output to setup/status surfaces with versions, paths, and helper
  availability.
- Add `config-helper.sh status --json` and validation output for effective config
  and template drift.
- Add a dedicated repo registry JSON adapter for reading, validating, backing up,
  atomically applying, and rolling back `repos.json` changes.
- Add `secret-helper.sh status --json` and `list --json` that return only names,
  backend, and health classes.
- Add `routine-helper.sh status --json`, plus validate/apply modes for schedule
  edits.
- Add OpenCode plugin status JSON for generated config health, runtime version,
  and session references without transcript content by default.
- Add `cloudron-helper.sh status --json` and fix help/status error handling so
  status checks never require secret values in logs.
- Add JSON status modes to GitHub, GitLab, Gitea/Forgejo, and
  `git-platforms-helper.sh` auth/repo/check summaries.
- Add a shared redacted audit-event writer for GUI action adapters if the
  existing audit helpers do not cover the needed fields.

## Verification

Planning-only changes to this contract should run:

```bash
git diff --check
npx --yes markdownlint-cli2@0.22.0 docs/gui/helper-api-contract.md docs/gui/control-plane.md
```

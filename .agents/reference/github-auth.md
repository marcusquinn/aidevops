# Repository GitHub authorization

## Contract: this stage enables App reads only

Configure **which identity Pulse uses for a repository**, not GitHub permissions
or the scheduler. Supported routes are `read: github-app|inherit` and
`write: inherit`. App write routes are rejected, including hand-edited JSON.
Interactive `gh` authentication is unchanged. Do not export Pulse's consumer
context in your interactive shell profile.

`inherit` keeps the credentials already available to the process; it does not
guarantee a particular human account. App read failures never retry as that
account. Unscoped requests, account probes and unsupported command forms retain
the existing routing described in [the routing reference](github-app-auth.md#readwrite-boundary).
This is not a claim that every request from a Pulse process uses the App.

## Naming and ownership agreement

- Name each participant's App `<org>-agent-<alias>`, for example
  `example-agent-operator`. Use the same name for the local profile and PEM file.
- Keep the App name within GitHub's 34-character limit and globally unique.
  Shorten the participant alias when necessary; record the full GitHub login in
  the App description. Do not include host names, versions or `poc`.
- Use a separate App per participant when independent bot identities and
  installation budgets are required. A participant may use their App on several
  hosts; tokens and keys for the same installation share its primary API budget.
  Secondary limits still apply. Separate keys do not create separate budgets.
- Prefer a separate private key of the same App for each trusted host so keys
  can be rotated independently. Each key still has App-wide authority.

## Fast path

```bash
aidevops github auth app create --owner OWNER [--install-on OTHER_OWNER ...]
aidevops github auth app bind --profile NAME [--owner OWNER] [--dry-run] [--replace]
```

`app create` runs GitHub's App Manifest flow. It serves a one-time page on
`127.0.0.1` that posts a read-only manifest: the permissions in
`DEFAULT_PULSE_READ_PERMISSIONS`, no webhook and no events. The owner clicks
**Create GitHub App** and then **Install**. The CLI exchanges the one-time code
and writes the key to `~/.config/aidevops/keys/<slug>.pem` with mode 0600. It
never prints the key and never overwrites an existing file. It creates the
profile named after the App slug, waits for the installations, then runs
`app bind`. A personal-account App can only be created by that account.
`--install-on` makes the App public so it can be installed on other accounts you
control. Each installation keeps its own primary rate limit.

`app bind` lists the App's installations with a JWT. For selected-repository
installations it also lists the covered repositories. In one locked registry
write it sets `read` to the App for each covered pulse repository and preserves
`write`. Each repository it skips reports a reason: `no-installation`,
`not-in-selected-installation`, `installation-suspended`, `local-only`,
`legacy-binding-run-migrate`, `bound-to-other-app` (rebind with `--replace`) or
`already-bound`. Skipped repositories keep inherited auth. A `read_check` then
runs for one bound repository per owner.

The manual steps below remain the reference for organizations whose policy
forbids the manifest flow.

## Create and install the App

1. In the intended GitHub account/organization settings, open **Developer
   settings → GitHub Apps → New GitHub App**. Organization policy may require
   an owner to create, approve or install the App.
2. Use the naming agreement above and a real homepage belonging to the project.
   This integration uses installation tokens: it needs no user OAuth callback.
   Disable webhooks unless another integration explicitly requires them.
3. Start with repository permissions **Metadata: read**, **Issues: read** and
   **Pull requests: read**. Do not request write permissions, organization
   administration or permission to change workflows for this stage.
4. Restrict where the App can be installed to the intended account when possible.
   Install it using **Only select repositories**, selecting the target repository.
5. Record the **App ID**, optional **Client ID**, and the **installation ID** from
   the installed App's configuration page. These are distinct identifiers.
6. Generate a private key. Transfer the PEM through an authenticated secure
   channel to `~/.config/aidevops/keys/<app-name>.pem`. Never paste its contents
   into chat, commit it or pass the contents as a CLI argument.

```bash
chmod 700 ~/.config/aidevops/keys
chmod 600 ~/.config/aidevops/keys/example-agent-operator.pem
```

The key must be a regular file owned by the current OS user; symlink keys are
rejected. The directory must already exist at the intended location before
placing the key. Repository registration and GitHub App installation are
separate prerequisites; `auth set` does neither.

## Create the local profile

After installing the updated aidevops runtime:

```bash
aidevops github auth profile set example-agent-operator \
  --app-id 123456 \
  --client-id YOUR_APP_CLIENT_ID \
  --private-key-path ~/.config/aidevops/keys/example-agent-operator.pem
aidevops github auth profile list
aidevops github auth profile show example-agent-operator
```

Profiles live in `~/.config/aidevops/github-auth.json`, written with mode `0600`.
The command stores only metadata and the key path. It requests the three read
permissions above. An existing name requires explicit `--replace`; do not rotate
a shared profile without considering every repository that references it.

Additional supported read operations may need more read permissions, such as
Actions or Checks. Grant only permissions justified by actual requests, approve
the installation's updated permissions, and explicitly add matching read entries
to the profile's `permissions`. A `403` is not a reason to enable broad writes.

## Bind the repository

For an already registered repository without a legacy binding:

```bash
aidevops github auth set OWNER/REPO --consumer pulse --operation read \
  --profile example-agent-operator --installation-id 987654
aidevops github auth set OWNER/REPO --consumer pulse --operation write --inherit
aidevops github auth status OWNER/REPO
aidevops github auth check OWNER/REPO --consumer pulse
```

The first `set` initializes the other route to `inherit`. Both routes are then
explicit in the repository entry in `~/.config/aidevops/repos.json`:

```json
{
  "github_auth": {
    "pulse": {
      "read": {
        "provider": "github-app",
        "profile": "example-agent-operator",
        "installation_id": "987654"
      },
      "write": {"provider": "inherit"}
    }
  }
}
```

`--consumer` and `--operation` are required for `set` and `clear`; this release
supports only `pulse`. `--profile` and `--inherit` are mutually exclusive.
Do not add `access`, `operations` or a second flat `pulse_auth` binding.

`status` is offline. `check` issues a repository metadata read through the App
route and reports `read_check: passed`; it does not test every endpoint or perform
any write. An inherited route is not reported as verified App access. No command
changes `pulse`, `maintenance`, scheduling, interactive login or Git credentials.

## Local usage, not a cross-host quota report

```bash
aidevops github auth usage --since 1h
aidevops github auth usage --consumer pulse --since 30m
```

Reports read the local `gh-api-calls.log` via the existing aggregator without
contacting GitHub. `requests` counts attempted requests, `failed` counts failed
attempts, and `events` counts logged events; these are not interchangeable.
`app_repositories` lists **current** App-read bindings, not historical attribution.

Consumer is recorded separately from caller and auth mode in optional TSV field
19. Older records remain readable as `unknown`; a consumer-filtered report excludes
them rather than guessing. Zero filtered events may mean the updated runtime has
not emitted tagged records yet. Other hosts' calls and remaining GitHub quota are
not inferred from this report. A failed aggregator is reported as an error.

`usage` also reports `app_routing_opportunity`: attempts and known quota cost
with auth reason `not-configured` (reads an App binding would route), the
total known quota cost, their `routable_share`, the window's REST-core
`rest_core_min_remaining`, and `owners_without_app_read` (owners with a
pulse-enabled repository lacking an App read route). Missing per-reason cost
data yields `routable_share: null`. `rest_core_cost_per_hour` is logged
REST-core known cost scaled to one hour; `rest_core_saturation` divides it by
`rest_core_limit`, read from the Pulse probe cache
(`AIDEVOPS_PULSE_REST_CORE_CACHE`, default
`~/.aidevops/cache/pulse-rest-core.json`). Without that cache both are `null`.

```bash
aidevops github auth advise [--since 24h] [--write-advisory]
```

`advise` computes the same object offline. With `--write-advisory` it writes
`~/.aidevops/advisories/github-app-read-routing.advisory` only when the
routable share is at least 0.5, at least one pulse owner lacks an App read
binding, and REST-core is constrained: `min_remaining` reached 0, fell below
the pulse hard floor, or `rest_core_saturation` is at least 0.75. The
saturation test exists because the transport governor paces requests before
quota reaches zero. Otherwise it removes that file. The session-start advisory
display shows its first line once, and `aidevops security dismiss
github-app-read-routing` suppresses it. Pulse refreshes it in the background at
most every 6 hours (`AIDEVOPS_GITHUB_APP_ADVISE_INTERVAL`), at cycle start and
when REST quota defers a progress stage; failures never affect the pulse.

## Upgrade and migration

1. Stop old Pulse processes and old config writers. Install the new runtime on
   this host before changing the schema. A process restart without a runtime
   update is insufficient.
2. Run:

   ```bash
   aidevops github auth migrate --confirm-stopped
   aidevops github auth status OWNER/REPO
   aidevops github auth check OWNER/REPO --consumer pulse
   ```

3. Resume automation only after checking the routes and confirming no old runtime
   still uses this registry. Repeat for each host with its own config files.

Migration validates the entire registry under its existing lock before writing.
It moves flat `pulse_auth` to `github_auth.pulse.read` and adds explicit
`write: inherit`; unrelated fields and scheduler settings are preserved. Conflicting
old/new bindings fail without a partial registry rewrite. Repeating migration is
safe. Configuration-changing commands refuse legacy bindings until this explicit
migration is performed; ordinary reads never rewrite configuration.

The named-profile file is copied to `github-auth.json` if necessary. The old
`github-app-auth.json` is retained because it may also configure the separate
legacy global helper. Do not delete it or enable global App routing casually.
The new reader uses the canonical file when present and accepts the old file only
when it is absent. `AIDEVOPS_GITHUB_AUTH_CONFIG` overrides the profile location;
the old `AIDEVOPS_GITHUB_APP_CONFIG` remains a compatibility alias with lower
precedence. `AIDEVOPS_REPOS_CONFIG` overrides the registry path.

Old CLI/import entry points are compatibility adapters, not a second implementation.
They do not make old deployed executables understand the new schema. Keep the
runtime and configuration versions together when rolling back.

## Disable or rotate

To intentionally restore inherited credentials for reads:

```bash
aidevops github auth clear OWNER/REPO --consumer pulse --operation read
```

`clear` resets only that route to explicit `inherit`; it does not delete the
profile/key, revoke a token or disable Pulse. This is an operator-selected change,
never an automatic fallback. To stop automation, disable its scheduler separately.

Rotate a host's key by generating and securely deploying a replacement, updating
the profile with `--replace`, checking access, then revoking the old key in GitHub.
Do not transfer token caches to another host. Revoking a signing key does not
itself prove that every previously issued installation token is invalid.

## Implementation boundary

`github_auth_cli.py` owns CLI dispatch, `github_auth_config.py` locked registry
updates, `github_auth_policy.py` schema/legacy normalization,
`github_auth_routing.py` command selection, `github_auth_runtime.py` isolated
execution, `github_auth_profiles.py` profile management,
`github_auth_migration.py` explicit migration, and `github_auth_usage.py` reporting.
`github_app_auth.py` remains the shared App token backend.

The read-only stage does not introduce App comments, merges, workflow dispatch,
git pushes, bot trust changes or write permission expansion. Those require a
separate implementation and explicit operator configuration.

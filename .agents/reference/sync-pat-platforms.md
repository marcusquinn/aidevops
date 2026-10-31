<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SYNC_PAT — Platform Matrix

Canonical reference for the `SYNC_PAT` secret used by the `issue-sync`
workflow across supported git platforms. Consumed by `/setup-git` to
generate platform-specific PAT-creation URLs and secret-set instructions.

## What `SYNC_PAT` is

A purpose-scoped platform personal access token distributed as a repository
secret named `SYNC_PAT` (not necessarily a distinct token per repository).
The `issue-sync` reusable workflow uses it to authenticate as the
maintainer (instead of the platform's bot identity) when:

- Creating issues from `TODO.md` entries that lack `ref:GH#NNN`
- Pushing back the auto-injected `chore: sync ref:GH#NNN to TODO.md [skip ci]`
  commit after the issue is created

When unset, the workflow falls back to the platform's default token (`GITHUB_TOKEN`
on GitHub Actions). Issues are then authored by the bot, which:

1. Reports `author_association: NONE` (or platform equivalent), tripping the
   t2449 worker-briefed auto-merge gate.
2. Cannot push to a branch-protected default branch on most platforms. The
   workflow routes terminal GH006 rejection through one deterministic PR; if
   Actions PR creation is disabled, the job token cannot open that PR either.

`SYNC_PAT` does not weaken or bypass default-branch protection. Direct GH006
rejection still routes through review and required checks. The PAT is used as
the bounded PR API fallback only after the job token fails and concurrent-PR
recovery finds nothing.

## Security posture (cross-platform)

Three rules apply on every platform:

1. **One token per owner and purpose**, reusable across explicitly selected
   repositories where the platform supports it. Keep sync separate from release
   credentials; extend the existing token's repository list, not its purpose.
2. **Fine-grained / scoped to specific repos**, never "all repos" or
   "classic / personal scope". Most platforms now have a fine-grained option;
   use it.
3. **Save once in gopass at creation time** with
   `aidevops secret set SYNC_PAT_OWNER_KEY`. Replace `OWNER_KEY` throughout these
   instructions with a distinct key for the owner using uppercase letters,
   digits, and underscores (for example, `SYNC_PAT_EXAMPLE_ORG`). Keep the
   repository secret name `SYNC_PAT` unchanged.
   Most platforms only show the token once. Set each repository secret from
   that stored value. Rotation reminders (90 days default) belong in the
   password manager entry. Local secret-age advisories supplement, but do not
   replace, the known expiration date.

## Platform Matrix

| Platform | Status | Native CLI | Secret Storage | Notes |
|----------|--------|------------|----------------|-------|
| GitHub | **Primary** (Phase 1) | `gh` | `gh secret set` | Fine-grained PAT, query-string scope encoding |
| GitLab | Stub (Phase 2) | `glab` | `glab variable set` | Project-scoped PAT, manual scope selection |
| Gitea | Stub (Phase 2) | `tea` | Manual repo secret UI | Token + repo-secret; no native query-string encoding |
| Bitbucket | Stub (Phase 2) | (none) | Repository variables UI | App passwords; no native CLI; setup is fully manual |

---

## GitHub (Primary, Phase 1 implemented)

### PAT creation URL

First reuse the owner's existing purpose-scoped `SYNC_PAT`, if present. Only
when none exists, create one fine-grained PAT for sync. The page accepts
query-string parameters that pre-fill the form. Substitute placeholders as marked:

```text
https://github.com/settings/personal-access-tokens/new
  ?name=aidevops-sync-<OWNER>
  &description=aidevops%20issue-sync%20PAT%20for%20<OWNER>
  &expires_in=90
  &target_name=<OWNER>
  &contents=write
  &issues=write
  &pull_requests=write
```

Where:

- `<OWNER>` — the org/user that owns the repo

The operator still has to:

- Set **Repository access → Only select repositories** to every repository
  needing sync under this owner (the URL pre-selects `target_name` but doesn't
  auto-pick repositories from the dropdown)
- Click Generate
- Save the token once in gopass with `aidevops secret set SYNC_PAT_OWNER_KEY` in a terminal
  **before** closing the page; never paste the value into chat

### Required scopes

Minimum scopes for the `issue-sync.yml` workflow:

| Scope | Why |
|-------|-----|
| `contents: write` | Push the `chore: sync ref:GH#NNN` commit back to default branch |
| `issues: write` | Create issues from TODO.md entries |
| `pull_requests: write` | Open the deterministic protected-branch fallback PR when Actions PR creation is disabled; update PR metadata during follow-ups |
| `metadata: read` | Required by all fine-grained PATs (auto-applied) |

Do NOT add `actions: read/write` (workflow can't trigger itself), `secrets`
(only repo admins should manage secrets), or any account-wide scope.

### Setting the secret

```bash
# Replace OWNER_KEY in both names and OWNER/REPO with the target repository:
# gh reads the value from stdin; the local name differs from the repo secret.
aidevops secret SYNC_PAT_OWNER_KEY -- sh -c 'printf %s "$SYNC_PAT_OWNER_KEY" | gh secret set SYNC_PAT --repo OWNER/REPO'
```

**Add a repository:** in GitHub **Settings → Developer settings → Fine-grained
tokens**, edit the existing sync token and add the repository to **Only select
repositories** if needed. The value is unchanged. Run the command above for the
new repository; do not mint another token. GitHub user accounts have no
account-level Actions secrets, so set the secret per repository from gopass.

**Value lost:** regenerate the existing token (permissions and repository list
are retained), save the new value with `aidevops secret set SYNC_PAT_OWNER_KEY`, then re-set
the secret in **every listed repository**. Regeneration revokes the old value,
invalidating all existing copies. Do not put values in command arguments or logs.

### Verification

```bash
gh secret list --repo <SLUG> | grep SYNC_PAT
# Or via the helper:
~/.aidevops/agents/scripts/setup-debt-helper.sh verify-secret <SLUG> SYNC_PAT
```

The helper never reads the secret value — it only confirms presence.

### Rotation / expired token

A non-empty secret can still be expired or revoked. The checkout symptom is:

```text
fatal: could not read Username for 'https://github.com': terminal prompts disabled
The process '/usr/bin/git' failed with exit code 128
```

All four issue-sync jobs validate a configured PAT against the repository API
before checkout. HTTP 200 selects the PAT; 401 reports expired/revoked, while
403/404 reports missing repository access. Transport errors and other statuses
also fall back safely. This is a repository-access probe, not proof of every
write permission (or Git transport availability).

Invalid tokens emit one `SYNC_PAT invalid` error annotation per job, but the
probe returns success: **green-with-error-annotation** is intentional when the
remaining work succeeds. This lets `GITHUB_TOKEN` checkout and read-only closing
hygiene continue. TODO.md publication still uses the existing protected-branch
PR path; it can fail if Actions cannot open the PR. No branch protection or token
permissions are weakened.

To rotate:

1. Regenerate the fine-grained token in GitHub settings. Regeneration retains its
   permissions and selected repositories, but **revokes the old value everywhere**.
   Save the replacement in the password manager and update every secret using it.
   See **Setting the secret** above: inventory all consumers before rotation,
   rather than assuming an existing token is unused or creating duplicate tokens.
2. In a separate terminal, set each affected secret using the interactive prompt
   (never put the value in chat, command arguments, or shell history):

   ```bash
   gh secret set SYNC_PAT --repo <SLUG>
   ```

3. Rerun failed jobs and verify the probe, checkout and closing hygiene:

   ```bash
   gh run rerun <id> --repo <SLUG> --failed
   ```

   Green runs with degradation annotations have no failed jobs to rerun; rerun
   the whole run (omit `--failed`) to verify rotation.

Local Phase 7 checks use `gh secret list --json name,updatedAt`, never the secret
value. A secret updated **76 or more days ago** produces a "may expire" advisory
(90-day default minus 14 days); this is a heuristic because actual expiry periods
vary. A latest failed `issue-sync.yml` run with a failed SYNC_PAT-backed checkout
also produces an advisory, even for a fresh secret or an unprotected repository.
Unrelated failed steps do not trigger it. API metadata cannot prove token validity;
the in-workflow probe is authoritative. Existing advisory dismissal still applies.

### Detection of need

`security-posture-helper-repo.sh` Phase 7 (`_check_sync_pat_need`) determines
whether a repo needs `SYNC_PAT` based on:

1. Does `.github/workflows/issue-sync.yml` exist, or does an active workflow
   `uses:` line call `loc-badge-reusable.yml`? Metrics caller filenames may vary.
   (Neither → not needed.)
2. Is the default branch protected (classic protection OR rulesets, t2806)?
   (No → not needed.)
3. Can GitHub Actions create the deterministic fallback PR? (Yes → not needed
   for protected publication.)
4. Is `SYNC_PAT` already set? (Yes → configured.)

When issue-sync or Repository Metrics exists, protection blocks direct publication, Actions cannot
create the fallback PR, and the secret is absent, an advisory is written at
`~/.aidevops/advisories/sync-pat-<SLUG_SAFE>.advisory`. The
`setup-debt-helper.sh` aggregator picks it up for the toast warning and
`/setup-git` walkthrough.

`aidevops security dismiss sync-pat-*` is an operator opt-out/defer path for a
known setup-debt warning. Treat dismissal as local risk acceptance or scheduling
debt, not as evidence that `_check_sync_pat_need` is wrong. Do not suppress the
advisory solely because approval count is zero; a pull-request or required-check
rule can still reject the direct publication path.

---

## GitLab (Stub — Phase 2)

GitLab personal access tokens are configured at:

```text
https://gitlab.com/-/user_settings/personal_access_tokens
```

(Self-hosted: substitute the host.)

GitLab's URL accepts a `name` and `scopes` query string but the form is more
restrictive than GitHub's — pre-filling does not auto-select scope checkboxes
in all UI versions. The Phase 2 implementation will:

- Detect platform from `repos.json`
- Emit the URL with `name=aidevops-sync-<SLUG_SAFE>` pre-filled
- List required scopes textually for the operator to tick:
  - `api`
  - `read_repository`
  - `write_repository`
- Use `glab variable set --repo <SLUG> SYNC_PAT` for the secret-set step

Until Phase 2 lands, treat GitLab as manual-setup. The `security-posture-helper.sh`
detection layer is GitHub-only today; GitLab CI uses different auth primitives
and the issue-sync workflow doesn't yet have a GitLab equivalent.

---

## Gitea (Stub — Phase 2)

Gitea tokens are configured per-instance at:

```text
https://<GITEA_HOST>/user/settings/applications
```

Required scopes: `write:repository`, `write:issue`. There is no native
query-string encoding — the operator picks scopes from a UI list.

Setting a repo secret via the `tea` CLI:

```bash
tea token create --name aidevops-sync-<SLUG_SAFE>
# Then add to repo via UI: Settings → Secrets → New
```

Until Phase 2 lands, treat Gitea as manual-setup.

---

## Bitbucket (Stub — Phase 2)

Bitbucket uses **App passwords** rather than fine-grained PATs:

```text
https://bitbucket.org/account/settings/app-passwords/new
```

Required permissions: `Repositories: Write`, `Issues: Write`,
`Pull requests: Write`. There is no native CLI for setting Pipelines
secured variables — the operator does it via:

```text
Repository → Settings → Repository variables → Add variable
```

with the name `SYNC_PAT` and "Secured" enabled.

Until Phase 2 lands, treat Bitbucket as manual-setup. Phase 2 will add a
guided URL flow but cannot automate the variable-set step (no CLI exists).

---

## Phase 2+ TODO

- Detect platform from `repos.json::platform` field and route in
  `setup-debt-helper.sh` and `/setup-git`
- Generate GitLab URL with `name=` query param + scope hint
- Add Gitea + Bitbucket guided walkthroughs (URL + manual instructions)
- Add `setup-debt-helper.sh verify-secret` GitLab/Gitea/Bitbucket backends
- Read actual token expiry from secret-manifest.json when available; the
  implemented 76-day secret-age advisory is only a 90-day-default heuristic

## Cross-references

- `scripts/commands/setup-git.md` — slash command spec (this matrix is its source of truth)
- `security-posture-helper.sh::_check_sync_pat_need` — detection layer
- `security-posture-helper.sh::_emit_sync_pat_advisory` — advisory writer
- `aidevops-update-check.sh::_check_advisories` — advisory aggregation
- `setup-debt-helper.sh` — count + slug aggregation for toast/CLI
- `reference/auto-dispatch.md` — t2374 SYNC_PAT detection origin
- `reference/auto-merge.md` — t2449 worker-briefed auto-merge gate
- `aidevops/onboarding.md` — per-account auth (the sister command)

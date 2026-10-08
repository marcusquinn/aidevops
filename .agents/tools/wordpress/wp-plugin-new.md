---
description: Create a new WordPress plugin from the latest WP Plugin Starter release, with the user's saved maker details, as a private GitHub repo
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# New WordPress Plugin

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use for**: "make/create/start a new WordPress plugin". Command: `/new-wp-plugin`.
- **Source**: the latest release of the public starter `wpallstars/wp-plugin-starter-template-for-ai-coding` (settings screen, Read Me tab, GitHub updater, release/check scripts, CI). Not `wp scaffold plugin`, unless the user asks for a bare plugin.
- **Helper**: `~/.aidevops/agents/scripts/wp-plugin-new-helper.sh` — `defaults`, `save-defaults`, `create [--dry-run]`.
- **Result**: a private GitHub template repo `<owner>/<slug>`, cloned to the standard path (`reference/repo-organization.md`), registered with aidevops, with identity changes committed in a linked worktree and pushed through the first PR. The template default branch must match the latest release. Local-only creation retains starter release history and commits identity changes on a linked branch without publishing. The plugin starts at version 0.1.0 with a changelog of its own (starter v1.0.4+).
- **Maker defaults**: `wordpress.plugin_defaults` in `~/.config/aidevops/settings.json` (`reference/settings.md`). They belong to this user only.

<!-- AI-CONTEXT-END -->

## Workflow

1. **Read the saved defaults**: `wp-plugin-new-helper.sh defaults` prints `saved` (this user's maker details) and `github_login`.
2. **Ask** in one message, numbered, with the suggested answer for each:
   - Plugin name (required).
   - One-line description, at most 150 characters (WordPress.org's limit); offer a draft if the user described the plugin.
   - Slug: suggest the name in lower case with dashes; it becomes the folder, main file, text domain and repo name. Check `wordpress.org/plugins/<slug>/` is not taken if it may go to WordPress.org.
   - Maker details, **only those missing from `saved`**: author name, author website, WordPress.org username(s) for Contributors, donate link (or none), GitHub owner (suggest `github_login`).
   - When every maker detail is saved, show them in one line and ask only for name and description; the user can say what to change.
3. **Save new maker details** the user gave, unless they say this plugin is a one-off: `wp-plugin-new-helper.sh save-defaults --author "…" --author-uri "…" --contributors "…" --donate none --github-owner "…"`.
4. **Dry run**: `wp-plugin-new-helper.sh create --name "…" --description "…" [--slug …] --dry-run`. Show the plan; it fails closed if the folder or repo exists.
5. **Create**: same command without `--dry-run`. Add `--public` only if asked. Output includes `PLUGIN_PATH=` (the editable identity worktree), `PLUGIN_CANONICAL_PATH=` (the read-only clone), `PLUGIN_BRANCH=`, `PLUGIN_REPO=` and `STARTER_TAG=`. Creation opens the first identity PR; verify and merge it through the normal full-loop gates, never write identity changes directly to canonical `main`. Failures preserve both paths for recovery; do not rerun creation over an existing repo.
   - If an older helper stops after init with `rename-plugin: commit or put away your changes first`, inspect the generated diff in `PLUGIN_PATH`, then stage and commit the init output there as `chore: initialize aidevops code-quality`. Resume the starter's `scripts/rename-plugin.sh` with the original identity/maker flags, then the remaining badge cleanup, lock update and publication steps from the helper; use `chore: <plugin name> names and maker details` for both the identity commit and PR title. Never commit the recovery in `PLUGIN_CANONICAL_PATH`.
6. **Make it the plugin's own** in a linked worktree of the new repo, through a PR (README "Start a plugin" step 3): rewrite `README.md` **preserving its `<!-- aidevops:badges:start -->` / `<!-- aidevops:badges:end -->` block and markers**, `readme.txt` (description, tags, FAQ), `changelog.txt`, `AGENTS.md` and `LAUNCH.md`; the banner (`.wordpress-org/banner.svg`, then `scripts/build-banner.sh`); keep the **Built with AI** credit.
   - Verify `LAUNCH.md` states this plugin's real launch state, not the starter's: by default, private, no release, no branch protection or rulesets, hosted reviewers deferred to owner-approved public launch, and not submitted to WordPress.org. Record any verified exceptions (such as explicitly requested public creation), not assumed starter settings.
   - Starters containing the fix for `wpallstars/wp-plugin-starter-template-for-ai-coding#390` have `scripts/rename-plugin.sh` write a fresh pre-launch `LAUNCH.md`; verify it. Older starters need the inherited file rewritten in this PR.
   - Then build the features the user described (`includes/features/`, `STANDARDS.md`).
7. **Verify**: `composer install`, `scripts/lint.sh`, `scripts/smoke-test.sh` (Docker).
8. **Onboard quality in that first PR**: follow the checklist below; do not call a repo finished with missing app access or starter metrics.

## Code Quality Onboarding

Creation registers the canonical clone with plain `aidevops repos add` when starter metadata exists, then runs `aidevops init code-quality` in the clean linked worktree **before** staging identity renames. This records `features: ["code-quality"]` in `repos.json` and generates the normal quality configuration without accidentally committing staged renames separately from their content edits. If init leaves changes, the helper commits them as `chore: initialize aidevops code-quality` in that linked worktree before the starter's clean-tree rename check; an already clean tree needs no extra commit. Include those generated files in the first customization PR. Verify the registration; a missing `aidevops` command or failed initialization stops creation with recoverable paths. The daily sweep additionally requires existing `maintenance != false` and `pulse: true` registration (`reference/repos-json-fields.md`); verify this automation opt-in rather than assume features alone enable dispatch. Creation removes unavailable Codacy, SonarCloud, CodeFactor and latest-release badges, not the markers or working CI/license/metrics badges.

In the **linked worktree**, after customization and before finishing the first PR:

```bash
wp-plugin-new-helper.sh quality --repo OWNER/SLUG --path "$PWD" --pr PR_NUMBER
```

Use `--dry-run` to inspect the plan without writes. The helper reads the actual repository visibility (never changes it), regenerates `docs/metrics/` via `repo-metrics-helper.sh generate .`, and inspects both check runs and legacy statuses on the exact first-PR head. Commit the README and generated metrics in this PR; keep `.github/workflows/repo-metrics.yml` for subsequent updates. Run metrics again after significant code changes. Local-only creation skips hosted registration; run `repo-metrics-helper.sh generate .` in its first local worktree instead.

For **public repos**:

- **Codacy**: inject `CODACY_API_TOKEN` securely (`aidevops secret set CODACY_API_TOKEN`), then run `quality`. It adds the repository with API v3 `POST /repositories` (`provider: gh`, `repositoryFullPath: OWNER/SLUG`), tolerates an already-added 409, fetches `GET /organizations/gh/OWNER/repositories/SLUG`, and restores the badge from `data.badges.grade`, never a copied project ID. Missing token, access or pending badge is reported; rerun after recovery.
- **SonarCloud**: inject `SONAR_TOKEN`, optionally `SONAR_ORGANIZATION` / `SONAR_PROJECT_KEY` when they differ from the GitHub owner / `OWNER_SLUG`; verify they match this plugin's scanner configuration, not another repo's environment. The helper provisions a public project when missing and only restores its badge after a quality-gate measure exists. **Project creation and measures do not prove GitHub binding**: the current published Web API exposes no GitHub import endpoint. The sole SonarCloud human fallback is: [Import a project](https://sonarcloud.io/projects/create) — an org admin imports this GitHub repo and configures its analysis method, then the AI reruns `quality`. For starter v1.0.7+ with `.github/workflows/sonarcloud.yml`, keep **Automatic Analysis off** and configure the repository `SONAR_TOKEN` securely for the Actions scanner (see the copied `DEVELOPMENT.md` "Services setup"); older copies without the scanner may enable Automatic Analysis. Never run both methods or claim binding from project existence alone.
- **Apps**: Codacy and CodeFactor must appear on the first PR; also verify CodeRabbit, Qlty and Socket. A check/status proves integration visibility, not a passing result. The helper reports each missing service; the AI diagnoses existing app selection and configuration, and an app admin grants repository access only if necessary. Do not silently accept missing public Codacy/CodeFactor checks. The helper restores CodeFactor's badge only after its public endpoint serves a grade SVG; restore a latest-release badge only after an actual release exists.
- **Full review**: after the plugin is its own, create/deduplicate the **Code Audit Routines** issue using the signed framework issue wrapper and dashboard pattern in `scripts/stats-quality-sweep-issues.sh` (`_ensure_quality_issue`). Include repo scripts, scope and verification; mention `@coderabbitai` to request a **full codebase review**, not merely the PR diff (`tools/code-review/coderabbit.md`, "Daily Code Quality Review"). Confirm the review request was accepted; report app/plan limitations rather than inventing a review.

For **private repos**, run local Composer/PHPCS/PHPStan, ShellCheck and Docker checks and generate metrics now. Defer hosted onboarding by default: Codacy and CodeFactor free tiers are public-only; the current starter documents limited private SonarCloud free-plan capacity (50,000 organization-wide lines), so verify current organization limits before using an existing entitlement. Do not assume all hosted services are free for private code. CodeRabbit, Qlty and Socket work only when their installed app's repository selection and plan allow private repos; verify actual first-PR checks/statuses, not assumed free access. Do not purchase plans or make the repo public to fix missing checks. At owner-approved public launch, repeat this checklist (`wp-plugin-release.md`).

## Rules

- Never fill another user's plugin with someone else's details. The starter's own author, links and Contributors are wpallstars'; the helper replaces every one, and refuses to run without author, author website and Contributors.
- Keep the repo private while in development; making it public, and releasing, need the user's say (`RELEASING.md`, `wp-plugin-release.md`).
- Plugins made from the starter pick up later starter fixes with `scripts/sync-core.sh` (`--check` lists what differs).
- If `create` says the starter release has no maker flags, the starter needs a release with `scripts/rename-plugin.sh --author-uri`; do not edit the copy by hand.

## Related

- `wp-dev.md` — development and debugging
- `wp-plugin-standards.md` — plugin coding standards and lint mapping
- `wp-plugin-release.md` — release builds, WordPress.org preflight, Plugin Check
- `reference/settings.md` — `wordpress.plugin_defaults`

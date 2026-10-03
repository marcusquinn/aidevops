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
- **Result**: a private GitHub repo `<owner>/<slug>`, cloned to the standard path (`reference/repo-organization.md`), registered with aidevops, with a fresh history of two commits.
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
5. **Create**: same command without `--dry-run`. Add `--public` only if asked. Output ends with `PLUGIN_PATH=`, `PLUGIN_REPO=` and `STARTER_TAG=`.
6. **Make it the plugin's own** in a linked worktree of the new repo, through a PR (README "Start a plugin" step 3): replace `README.md`, `readme.txt` (description, tags, FAQ), `changelog.txt` and `AGENTS.md`; the banner (`.wordpress-org/banner.svg`, then `scripts/build-banner.sh`); keep the **Built with AI** credit. Then build the features the user described (`includes/features/`, `STANDARDS.md`).
7. **Verify**: `composer install`, `scripts/lint.sh`, `scripts/smoke-test.sh` (Docker).

## Rules

- Never fill another user's plugin with someone else's details. The starter's own author, links and Contributors are wpallstars'; the helper replaces every one, and refuses to run without author, author website and Contributors.
- Keep the repo private while in development; making it public, and releasing, need the user's say (`RELEASING.md`, `wp-plugin-release.md`).
- Plugins made from the starter pick up later starter fixes with `scripts/sync-core.sh` (`--check` lists what differs).
- If `create` says the starter release has no maker flags, the starter needs a release with `scripts/rename-plugin.sh --author-uri`; do not edit the copy by hand.

## Related

- `wp-dev.md` — development and debugging
- `wp-plugin-release.md` — release builds, WordPress.org preflight, Plugin Check
- `reference/settings.md` — `wordpress.plugin_defaults`

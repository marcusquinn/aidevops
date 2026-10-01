---
description: WordPress plugin release builds, WordPress.org preflight, Plugin Check, and submission guide
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Plugin Release & WordPress.org Preflight

<!-- AI-CONTEXT-START -->

## Quick Reference

| Need | Use |
|------|-----|
| Build two channel zips from a Git ref | `wp-plugin-release-helper.sh build [--ref REF] [--out DIR]` |
| WordPress.org + Git Updater compatibility gate | `wp-plugin-release-helper.sh preflight [--ref REF] [--strict] [--offline]` |
| Run the official Plugin Check plugin in disposable Docker | `wp-plugin-release-helper.sh plugin-check [--ref REF] [--keep-output DIR]` |
| General plugin/theme development | `wp-dev.md` |

`wp-plugin-release-helper.sh` never tags, pushes, publishes, uploads to WordPress.org, or commits to SVN. It only writes to its own `--out`/`--keep-output` directories and self-removed temp dirs. Release and WordPress.org submission need the repository owner's explicit say.

<!-- AI-CONTEXT-END -->

## Two Release Channels

1. **GitHub release** (optionally installed by end users through [Git Updater](https://git-updater.com/)): `<slug>-X.Y.Z.zip`, keeps any `GitHub Plugin URI`/`Primary Branch`/`Release Asset`/`Update URI` headers the plugin uses for self-updating.
2. **WordPress.org**: `wordpress-org-<slug>-X.Y.Z.zip`, strips those updater headers (WordPress.org forbids code that updates from outside WordPress.org — [Detailed Plugin Guidelines](https://developer.wordpress.org/plugins/wordpress-org/detailed-plugin-guidelines/) #8) and applies an optional `.distignore-wporg` on top of `.distignore`.

Both are built with `git archive <ref>`, never the working tree, so an uncommitted or unpushed change can't silently ship.

### Git Updater packaging rules

Git Updater installs the first GitHub release asset whose name **starts with the plugin slug**, and treats any tag containing letters (e.g. `v1.0.0-beta1`) as non-stable. Consequences:

- GitHub asset name: `<slug>-X.Y.Z.zip` (must start with the slug).
- WordPress.org zip name: `wordpress-org-<slug>-X.Y.Z.zip` (must **not** start with the slug, or Git Updater could try to install it).
- Never leave a pre-release `Version:` on the default branch — Git Updater compares the default branch's `Version:` header against installed copies to offer updates.
- Publish the GitHub release in the same sitting as the version-bump merge.

## Helper Usage

```bash
wp-plugin-release-helper.sh build [--ref REF] [--out DIR] [--slug SLUG] \
    [--main-file FILE] [--wporg-strip-headers 'Header A|Header B'] [--quiet]
wp-plugin-release-helper.sh preflight [--ref REF] [--slug SLUG] [--main-file FILE] \
    [--strict] [--offline] [--no-docker]
wp-plugin-release-helper.sh plugin-check [--ref REF] [--slug SLUG] [--main-file FILE] \
    [--zip FILE]... [--keep-output DIR]
```

- **Slug/main file detection**: slug defaults to the repo's top-level folder name; main file is `<slug>.php` if present, else the single root `*.php` with a `Plugin Name:` header. Override with `--slug`/`--main-file` when ambiguous.
- **`build`** writes `<slug>-X.Y.Z.zip`, `wordpress-org-<slug>-X.Y.Z.zip`, and `SHA256SUMS` to `--out` (default `dist/`). Two builds of the same ref produce identical `SHA256SUMS` (file mtimes are normalised before zipping).
- **`preflight`** builds into a temp dir and prints `ok`/`warn`/`ERROR`/`note` lines, then exits 1 on any `ERROR` (or on warnings too with `--strict`). `--offline` skips the WordPress.org slug-availability API check. Negative-test a candidate commit without touching the branch: `wp-plugin-release-helper.sh preflight --ref "$(git stash create)" --offline`.
- **`plugin-check`** builds (or accepts `--zip FILE`, repeatable) and runs the official [Plugin Check](https://wordpress.org/plugins/plugin-check/) plugin inside a disposable Docker WordPress + MariaDB stack, using `wordpress:cli-php8.3` with a raised `memory_limit` (the 128 MB default kills `wp core download`). Exits 1 if any zip has an `ERROR`-level finding or Plugin Check does not run (no `Success:`/`FILE:` output). Removes its own container, volume, and network on exit — never touches other running containers. `--keep-output DIR` saves the raw JSON per zip for inspection.

## Preflight Checks

- **Errors**: non-numeric `Version:` (including pre-release suffixes like `-beta1`); an `Update URI` header (Plugin Check: `plugin_updater_detected`); `Text Domain` not equal to the slug; `License` not GPL-compatible; a `*_VERSION` constant that differs from the `Version:` header; `readme.txt` `Stable tag` missing, `trunk`, or not equal to `Version:`; `Requires at least`/`Requires PHP` missing from the main file or mismatched between main file and `readme.txt`; a zip without exactly one `<slug>/` top-level folder; a zip missing the main file; development files in a zip (`.git`, `.github`, `.agents`, `.distignore*`, CI/VCS files, `node_modules`, `tests`, `dist`, etc.); PHP/JS syntax errors; the WordPress.org zip still containing a `.distignore-wporg` pattern or an updater header; wrong asset-name direction for either channel.
- **Warnings**: `readme.txt` over 10 KB; missing or over-length (150 char) short description; more than 5 tags; `Tested up to` below the latest WordPress release (network); no changelog entry (or a leftover `Unreleased` section) for the built version; readme title differing from `Plugin Name`; a slug derived from `Plugin Name` that differs from the detected slug; a name starting with a reserved prefix (`WordPress`/`WP`/`Woo`/`WooCommerce`/`Gutenberg`); `Plugin URI` equal to `Author URI`; a contributor without a WordPress.org profile (network); the WordPress.org build still referencing third-party update APIs or enqueuing a remote script/style; an existing `vX.Y.Z` tag pointing elsewhere.
- **Notes**: zip sizes; hosts referenced in code but not named in `readme.txt`; whether the ref is on the default branch; WordPress.org slug availability (skipped with `--offline`).

PHP/JS syntax is checked with local `php -l`/`node --check` when available (not version-matched to `Requires PHP`); `plugin-check` runs a version-matched lint inside its WordPress container.

## WordPress.org Submission Checklist

Judgement items Plugin Check and `preflight` cannot fully automate. Sources: [Detailed Plugin Guidelines](https://developer.wordpress.org/plugins/wordpress-org/detailed-plugin-guidelines/), [Planning, Submitting, and Maintaining Plugins](https://developer.wordpress.org/plugins/wordpress-org/planning-submitting-and-maintaining-plugins/), [Plugin Readmes](https://developer.wordpress.org/plugins/wordpress-org/how-your-readme-txt-works/), [How Your Plugin Assets Work](https://developer.wordpress.org/plugins/wordpress-org/plugin-assets/), [Using Subversion](https://developer.wordpress.org/plugins/wordpress-org/how-to-use-subversion/).

- The slug comes from `Plugin Name` and can change only once, before approval — state the wanted slug in the submission notes so it matches the `Text Domain`.
- Submit a complete, working plugin (guideline 16); no trademark at the start of the plugin name (17); GPL-compatible code and bundled assets (1); no trialware or artificially locked features (5); any external service documented with terms/privacy links and no tracking without consent (6, 7); no code installed or updated from outside WordPress.org, with JS/CSS shipped locally unless genuinely part of a remote service (8); affiliate links disclosed and not cloaked (12); no admin hijacking — notices contextual and dismissible, no dashboard ads (11).
- `readme.txt`: `Contributors` are case-sensitive WordPress.org usernames; short description ≤150 characters with no markup; 1–5 tags, no competitor names; `Tested up to` is major.minor only; `Stable tag` is a real version (never `trunk` for a new plugin) and must also be correct in `tags/X.Y.Z/readme.txt` after release; keep it under 10 KB and move old changelog entries to `changelog.txt`; `Requires at least`/`Requires PHP` are read from the main file since WordPress 5.8. Validate with the official readme validator before submitting.
- **Assets** (SVN `/assets/`, never in the zip): `banner-772x250` and `banner-1544x500` (png/jpg, ≤4 MB), `icon-128x128` and `icon-256x256` (png/jpg/gif, ≤1 MB, optional `icon.svg`), `screenshot-N` (png/jpg, ≤10 MB) captioned in `== Screenshots ==`. Keep asset sources in `.wordpress-org/`, excluded from the build via `.distignore`.
- Review typically takes 1–10 business days; reply from the same WordPress.org account that submitted; fix issues in the source repository, not in SVN directly.
- **SVN after approval**: `https://plugins.svn.wordpress.org/<slug>/` with `trunk/`, `tags/X.Y.Z/`, `assets/`. The SVN password is separate from the account password. Never commit zips to SVN — it holds source, not archives. A release is: commit `trunk`, `svn cp trunk tags/X.Y.Z`, and `Stable tag: X.Y.Z` in `trunk/readme.txt`. Expect a release-confirmation email from WordPress.org. An automated `svn-deploy` subcommand is intentionally out of scope for this helper until tested against a real or local SVN repository — treat it as a separate follow-up.

## Release Steps (GitHub Channel)

1. Version-bump PR (`Version:` header + `readme.txt` `Stable tag` + changelog entry), merged.
2. `wp-plugin-release-helper.sh preflight` and, when Docker is available, `plugin-check` — both clean.
3. `git tag vX.Y.Z` on the merged default-branch commit (never a branch with unmerged pre-release changes).
4. `wp-plugin-release-helper.sh build --ref vX.Y.Z --out dist` (building from the tag, not the working tree, guarantees the shipped zip matches the tagged commit).
5. `gh release create vX.Y.Z dist/<slug>-X.Y.Z.zip` — attach only the GitHub-channel zip; never attach the WordPress.org zip to a GitHub release.

Tagging, pushing, and publishing the release are explicit, owner-approved actions outside this helper.

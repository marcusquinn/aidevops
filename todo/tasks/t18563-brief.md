# t18563: fix(skill-update): authenticate GitHub lookups and route non-GitHub skill sources

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33135
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

## Why

`skill-update-helper.sh check` fails for 12 of 14 imported skills, so upstream changes (for example Remotion, synced last on 2026-01-21) go unnoticed. GH#33150 (t18574) is blocked on this fix.

## What

`skill-update-helper.sh check` fails for 12 of 14 imported skills, so upstream-synced skills have silently gone stale. `remotion` and `cloudflare-platform-skill` were last synced 2026-01-21, while upstream `remotion-dev/skills` had a commit on 2026-09-29 (`gh api "repos/remotion-dev/skills/commits?per_page=1"` → `a1b09e9`).

## Why

Imported skills (Remotion, Cloudflare, HeyGen, nothing-design, video-use, Cloudron and others) are only worth keeping if they stay current. The daily auto-update freshness path (`auto-update-freshness-lib.sh`) calls this helper non-interactively, so the failures are logged but nobody sees them.

## Root causes (verified 2026-09-30)

1. **Unauthenticated GitHub API.** `get_latest_commit()` in `.agents/scripts/skill-update-core-lib.sh:169-191` uses bare `curl` against `api.github.com`. After the first request it hits the 60/hour anonymous limit. Direct evidence: `curl -s https://api.github.com/repos/remotion-dev/skills/commits?per_page=1` returns `API rate limit exceeded`, while `gh api` returns the commit. The same pattern is in `.agents/scripts/skill-update-batch-lib.sh:110-117` and `:506-514`.
2. **Non-GitHub sources routed to the GitHub checker.** Sources on `clawdhub.com` and `git.cloudron.io` go to `_check_github_skill()` (`skill-update-core-lib.sh:503-521`). `parse_github_url` then yields `https:/`, which fails with `Could not fetch latest commit for caldav-calendar (https:/)`.
3. **`help` runs a full check.** `skill-update-helper.sh:148-198` treats a bare `help` as a skill name, so `skill-update-helper.sh help` runs `check`. Only `--help` and `-h` show help.

## How

- Prefer `gh api` (authenticated, already a framework dependency) for GitHub commit lookups. Fall back to curl with `GH_TOKEN` or `GITHUB_TOKEN` only when `gh` is unavailable. Make one shared function used by both libs.
- Route non-GitHub URLs to the existing content-hash path, the one `convos` uses successfully with `https://convos.org/skill.md`. For git hosts that are not GitHub, use `git ls-remote <url> HEAD` when the URL is a git repository.
- Accept `help` as a command alias.
- After the fix, run `skill-update-helper.sh check` and report which skills have updates. Do not auto-apply the updates in this PR; re-syncing content is separate follow-up work.

### Files Scope

- `.agents/scripts/skill-update-core-lib.sh`
- `.agents/scripts/skill-update-batch-lib.sh`
- `.agents/scripts/skill-update-helper.sh`

## Acceptance criteria

- `skill-update-helper.sh check` reports `Check failed: 0` for reachable sources on a machine with authenticated `gh`.
- Non-GitHub sources report up-to-date or update-available through the content-hash or `ls-remote` path, never `https:/`.
- `skill-update-helper.sh help` prints help and makes no network calls.
- ShellCheck is clean for all three files.

## Verification

```bash
.agents/scripts/skill-update-helper.sh check
.agents/scripts/skill-update-helper.sh help
shellcheck .agents/scripts/skill-update-core-lib.sh .agents/scripts/skill-update-batch-lib.sh .agents/scripts/skill-update-helper.sh

```

Context: found during the framework value audit (interactive session, 2026-09-30) while checking whether imported Remotion and Cloudflare skill content was current.

---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18484: Add forge image-embed helper for PR/issue screenshots without web upload

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `screenshot embed PR fork asset branch` → 1 hit — the lesson stored in this session (orphan asset branch + commit-pinned raw URL, verified on an upstream PR)
- [x] Discovery pass: `prework-discovery-helper.sh --keywords "image attachment PR comment screenshot embed forge"` → 1 recent commit on target docs (138608aa7, unrelated recovery hardening) / 0 merged related PRs / 0 open related PRs; `rg "git/blobs|user-attachments|upload.*screenshot" .agents` finds no existing guidance
- [x] File refs verified: 5 refs checked, all present at HEAD (`.agents/tools/git/github-cli.md` 115 lines, `.agents/tools/git/gitlab-cli.md` 76 lines, `.agents/scripts/screenshot-import-helper.sh` 273 lines, `.agents/reference/screenshot-limits.md`, `.agents/reference/gh-command-discipline.md`)
- [x] Tier: `tier:standard` — new helper within a decided design; worker still writes shell logic and error handling
- [x] Seeded draft PR decision recorded: skipped — the design is decided below and the helper is small; a seed would add no discovery value

## Origin

- **Created:** 2026-09-27
- **Session:** opencode:unknown-2026-09-27
- **Created by:** ai-interactive (requested by maintainer)
- **Conversation context:** Adding screenshots to an upstream draft PR needed images in the PR body, but GitHub has no REST/GraphQL API for comment/body attachments (web drag-and-drop only). The working method was: create blobs, a tree, a parentless commit and a ref on a separate asset-only branch of the contributor's fork via `gh api`, then embed commit-pinned `https://github.com/<fork>/raw/<sha>/<file>` URLs. The maintainer asked for this to become reusable framework knowledge for any git-platform post or comment.

## What

1. A new helper, `.agents/scripts/forge-image-embed-helper.sh`, that publishes one or more local images to an asset-only branch of a GitHub repository through the Git Data API, then prints ready-to-paste Markdown image embeds pinned to the commit SHA.
2. Short guidance in `.agents/tools/git/github-cli.md` (and a GitLab note in `.agents/tools/git/gitlab-cli.md`) telling agents when and how to use it, including the privacy check before publishing.

Agents that need screenshots in an issue, PR body, or comment on any GitHub repo (own or upstream) can then run one command instead of inventing the API sequence, and never need browser upload.

## Why

- GitHub exposes no API for issue/PR attachments; agents otherwise either skip screenshots (upstream CONTRIBUTING files often require them for UI changes, e.g. anomalyco/opencode "UI Changes") or ask the human to drag and drop.
- Committing screenshots into the PR branch pollutes upstream diffs; an asset-only branch keeps them out of review.
- The manual sequence is easy to get wrong in restricted shells (OpenCode Bash blocks redirects and command substitution, so base64 content must go through files and `gh api -F content=@file`).

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeleton and API sequence given; the worker writes the function bodies.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?**
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** None of the target files are in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** Decided design with a verified API sequence and a reference helper structure; the worker still implements argument parsing, validation and error handling in new shell code.

## PR Conventions

Leaf task: the PR uses `Resolves` with this task's issue number.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/screenshot-import-helper.sh` — header, `source shared-constants.sh`, `cmd_*` functions, `cmd_help`, `main` with `case` dispatch. Copy this structure.
- **Load only if:** `.agents/reference/shell-style-guide.md` — ShellCheck or complexity gate failures.
- **Why:** keeps the new helper consistent with framework shell conventions (explicit `return 0/1`, `local var="$1"`, Bash 3.2 compatible).
- **Stop when:** helper structure, API sequence below and verification commands are clear.

### Worker Quick-Start

```bash
# Verified API sequence (worked on 2026-09-27 against a public fork):
base64 -i image.png -o image.b64                         # macOS; use `base64 -w0 image.png` on GNU into a temp file
gh api repos/OWNER/REPO/git/blobs -F encoding=base64 -F content=@image.b64 --jq .sha
gh api repos/OWNER/REPO/git/trees -f "tree[][path]=image.png" -f "tree[][mode]=100644" \
  -f "tree[][type]=blob" -f "tree[][sha]=BLOB_SHA" --jq .sha   # repeat the 4 tree[] fields per file
gh api repos/OWNER/REPO/git/commits -f "message=..." -f tree=TREE_SHA --jq .sha   # parentless on first publish
gh api repos/OWNER/REPO/git/refs -f ref=refs/heads/BRANCH -f sha=COMMIT_SHA
# Embed URL (verified 200 image/png after redirect):
https://github.com/OWNER/REPO/raw/COMMIT_SHA/image.png
```

### Files to Modify

- `NEW: .agents/scripts/forge-image-embed-helper.sh` — model on `.agents/scripts/screenshot-import-helper.sh` structure.
- `EDIT: .agents/tools/git/github-cli.md:103-110` — add a `### Screenshots and Images` subsection after "Pre-Submission Checklist" (before `## See Also`).
- `EDIT: .agents/tools/git/gitlab-cli.md` — add a short "Images in issues/MRs" note: GitLab has a native uploads API (`glab api projects/:id/uploads -F file=@path` returns a `markdown` field), so the helper is not needed there.

### Complete Write Surface

- **Callers/readers:** new helper; no existing callers (`rg "forge-image-embed" .agents` is empty). Readers are agents following `github-cli.md`.
- **Writers/mutation paths:** the helper writes only to the remote repo given by `--repo`, on the branch given by `--branch` (default `aidevops-assets`), plus temp base64 files under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}` removed on exit.
- **Tests/fixtures:** N/A because no existing tests cover forge image publishing (searched `.agents/scripts/tests/` for screenshot/image helpers); verification is ShellCheck through `linters-local.sh --changed` plus the live publish below. No new test harness is requested.
- **Schemas/config:** N/A — no config keys added (`rg` of `.agents/configs` shows no image/asset settings).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*` to `~/.aidevops/agents/scripts/` automatically; no index to update (`screenshot-import-helper.sh` is referenced only from docs, not from a registry).
- **Migrations/backfills:** N/A because this is a new-file-only capability with no existing stored state to migrate.
- **Cleanup/rollback paths:** remote asset branches can be deleted with `gh api -X DELETE repos/OWNER/REPO/git/refs/heads/BRANCH`; document this. Deleting the branch eventually breaks embeds, so the doc must say to keep it while the PR/issue matters.

### Implementation Steps

1. Create the helper with commands `publish`, `help`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# forge-image-embed-helper.sh — publish images to an asset-only branch and print Markdown embeds
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# publish --repo OWNER/REPO [--branch NAME] [--message MSG] FILE [FILE...]
# stdout: one line per file: ![<basename>](https://github.com/OWNER/REPO/raw/<sha>/<basename>)
cmd_publish() { ...; return 0; }
```

   Required behaviour of `publish`:
   - Validate `--repo` as `owner/name`; require `gh` authenticated.
   - Refuse if the repo is private unless `--allow-private` is passed (private raw URLs do not render for people without access); read `gh api repos/OWNER/REPO --jq .private`.
   - Refuse if `--branch` is the head branch of any open PR on that repo (`gh pr list --repo OWNER/REPO --head BRANCH --state open`) or equals the default branch — assets must never enter a reviewed branch.
   - Per file: must exist, MIME type image/png, image/jpeg, image/gif or image/webp (`file --mime-type -b`), size ≤ 10 MB; reject duplicate basenames.
   - Create blobs, then a tree. If the branch exists: use its tip commit as `parents[]` and its tree as `base_tree`, then `PATCH refs/heads/BRANCH` with `force=false`. If not: parentless commit, then `POST refs`.
   - After publishing, check each embed URL with `curl -sIL -o /dev/null -w '%{http_code} %{content_type}'` and fail if it is not `200 image/*`.
   - Print embeds on stdout; logs on stderr via shared `log_*`.
2. `help` text lists usage, the privacy warning, and the cleanup command.
3. Add to `github-cli.md` a subsection (≤ 15 lines): GitHub has no attachment API; before publishing, view each image and confirm no secrets, private repo names or local private paths are visible (cross-link `reference/pre-push-guards.md`); run the helper against the fork you push from (for upstream PRs) or the repo itself; paste the embeds into `--body-file` content; keep the asset branch while the thread matters; never commit screenshots into the PR branch; resize large captures first (`reference/screenshot-limits.md`).
4. Add the GitLab uploads note to `gitlab-cli.md`.
5. Run ShellCheck and exercise the helper once against a test repo you own (see Verification).

### Hazards and Compatibility

- **Concurrency/atomicity:** two publishes to the same branch race on the ref update; `force=false` makes the loser fail with 422 — report it and tell the user to rerun. No local git state is touched.
- **Migration/rollback:** none; rollback is deleting the helper and the doc lines. Remote asset branches are independent.
- **Mixed-version/backward compatibility:** new file only; older deployments simply lack the helper.
- **Idempotency/retry:** rerunning creates a new commit with identical blobs (GitHub deduplicates blob storage); earlier pinned URLs keep working because commits stay reachable on the branch.
- **Partial failure/recovery:** blobs/trees/commits created before a failed ref update are unreferenced and garbage-collected by GitHub; nothing is printed on failure, so no half-valid embeds are pasted. Temp base64 files are removed by a `trap` on exit.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/forge-image-embed-helper.sh
.agents/scripts/linters-local.sh --changed
.agents/scripts/forge-image-embed-helper.sh help
# Live check against a throwaway public repo you own (not the aidevops repo):
.agents/scripts/forge-image-embed-helper.sh publish --repo <your-login>/<scratch-repo> --branch aidevops-assets-test <any-small.png>
# Negative checks:
.agents/scripts/forge-image-embed-helper.sh publish --repo <your-login>/<scratch-repo> --branch <scratch-repo-default-branch> x.png   # must refuse
.agents/scripts/forge-image-embed-helper.sh publish --repo <your-login>/<scratch-repo> README.md   # must refuse (not an image)
```

- **Surface mapping:** ShellCheck/linters prove shell conventions; the live publish proves the API sequence and URL verification; negative checks prove the default-branch/PR-branch guard and MIME validation.
- **Broad verification trigger:** Not required — new standalone helper plus two docs.

### Scope Boundaries

**Hard boundaries:** do not add image upload to `gh-write-helper.sh` or signature/PR wrappers in this task; do not add browser automation.

**AI brief owner:** maintainer interactive session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/forge-image-embed-helper.sh`
- `.agents/tools/git/github-cli.md`
- `.agents/tools/git/gitlab-cli.md`
- `TODO.md`
- `todo/tasks/t18484-brief.md`

## Acceptance Criteria

- [ ] `publish` against a public repo prints one Markdown embed per image, each URL returns `200` with an `image/*` content type, and the asset branch contains the images.

  ```yaml
  verify:
    method: codebase
    pattern: "git/blobs"
    path: ".agents/scripts/forge-image-embed-helper.sh"
  ```

- [ ] `publish` refuses (non-zero exit, nothing on stdout) when the target branch is the repo default branch or an open PR head branch, when a file is not an allowed image type, and for private repos without `--allow-private`.

  ```yaml
  verify:
    method: codebase
    pattern: "allow-private"
    path: ".agents/scripts/forge-image-embed-helper.sh"
  ```

- [ ] `github-cli.md` documents the method, the privacy check and the cleanup command; `gitlab-cli.md` documents the native uploads API.

  ```yaml
  verify:
    method: codebase
    pattern: "forge-image-embed-helper"
    path: ".agents/tools/git/github-cli.md"
  ```

- [ ] ShellCheck clean and `linters-local.sh --changed` passes.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/forge-image-embed-helper.sh"
  ```

## Context & Decisions

- Chosen: Git Data API on an asset-only branch, commit-pinned URLs. Ruled out: committing images into the PR branch (pollutes upstream diffs); gists (binary files need git push, not `gh gist create`); browser drag-and-drop automation (needs authenticated browser, fragile); third-party image hosts (privacy, link rot).
- `raw/<sha>/` URLs are used instead of branch URLs so later pushes to the asset branch cannot change what an existing comment shows.
- GitLab and Gitea have native attachment APIs; only GitHub needs the workaround.
- Prior art: this session's use on an upstream opencode PR (both embeds verified 200 image/png).

## Relevant Files

- `.agents/scripts/screenshot-import-helper.sh` — structure to copy.
- `.agents/tools/git/github-cli.md:103` — insertion point after Pre-Submission Checklist.
- `.agents/tools/git/gitlab-cli.md` — GitLab note.
- `.agents/reference/screenshot-limits.md` — resize guidance to cross-link.
- `.agents/reference/pre-push-guards.md` — private-name/path rules to cross-link.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** a public scratch repo for the live verification

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | reference helper, two docs |
| Implementation | 1h | helper + docs |
| Verification | 15m | ShellCheck, live publish, negative checks |
| **Total** | **~1.5h** | |

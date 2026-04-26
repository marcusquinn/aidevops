# t2885: exclude worktrees from macOS indexers and backup tools at creation time

## Session Origin

Interactive session 2026-04-26. User reported sustained 100% CPU during pulse worker activity on awardsapp. Investigation traced to `_dlw_restore_worktree_deps` (deployed at `pulse-dispatch-worker-launch.sh:236-262`, mirrored at `worktree-helper.sh:694` as `_restore_worktree_node_modules`) doing `cp -a` of `node_modules` per worktree. With 15 concurrent awardsapp worktrees on disk (~30 GB of duplicated `node_modules`), the dominant cost wasn't the cp itself — it was the cascade triggered by the file events:

- fseventsd 131.8% CPU (file events from every cp'd file)
- bztransmit 73.5% + 51.3% (Backblaze re-uploading every duplicate)
- mds 44.0% (Spotlight re-indexing every duplicate)
- kernel_task 126.5% (I/O + thermal mitigation)

System time hit 81.59% vs user 18.41% — kernel/filesystem-bound, not computation. The cp is a real fix for a real bug (workers crash without `node_modules` because opencode tools `import` from it), so we can't remove it. But worktrees are ephemeral by design — the canonical repo + git remote IS the backup — so backing them up and indexing them is pure waste.

## What

Add post-creation hooks to `worktree-helper.sh add` that exclude every new worktree from macOS Spotlight, Time Machine, and (where scriptable) Backblaze. Also provide a backfill mode for existing worktrees, and integrate detection + one-time setup prompts into `setup.sh` and `aidevops update`.

## Why

1. **Universal failure mode.** Every macOS aidevops user with backup/index tools running hits this identically — not specific to one machine. It's structural: parallel pulse workers × `node_modules` × OS file watchers.
2. **Worktrees are ephemeral.** Backing them up is double-counting — the persistent state lives on the git remote. The only thing worth preserving is uncommitted WIP, which is stash-recoverable on demand.
3. **Self-improvement principle (`prompts/build.txt`).** Observable failure (user CPU spike) → universal pattern → root-cause fix in framework default behaviour.

## How

### Files to modify

- **NEW:** `.agents/scripts/worktree-exclusions-helper.sh` — model on `.agents/scripts/install-hooks-helper.sh` (similar shape: detect-installed → apply → backfill).
  - Subcommands: `apply <path>` (single worktree), `backfill` (all worktrees in `~/.config/aidevops/repos.json`), `detect` (report which tools are present), `setup-backblaze` (print sudo command for manual run).
  - Apply for each worktree: `touch <path>/.metadata_never_index` (Spotlight) + `tmutil addexclusion -p <path>` (Time Machine).
  - Backblaze: NOT scripted automatically (root-only `bzexcluderules_editable.xml`, requires service restart). The `setup-backblaze` subcommand prints the rule XML and the sudo+restart commands for the user to run manually.
  - Idempotent: `tmutil isexcluded` check before adding; skip `.metadata_never_index` if file exists.
  - Source `shared-constants.sh` for color/log helpers (per shell-style rules).
  - Linux: print "not implemented yet — see GH#<linux-followup>" and exit 0 (non-fatal).

- **EDIT:** `.agents/scripts/worktree-helper.sh:1051-1063` — call `_apply_worktree_exclusions "$path"` immediately after the existing `_restore_worktree_node_modules` call. Function added to worktree-helper.sh as a thin wrapper that invokes `worktree-exclusions-helper.sh apply` with `2>/dev/null || true` (must never fail worktree creation).

- **EDIT:** `setup.sh` — add a section near the existing posture/tool-detection blocks that calls `worktree-exclusions-helper.sh detect` and prints the Backblaze sudo command if Backblaze is detected and the user hasn't already added the exclude rule. Idempotent — skip if rule already present.

- **EDIT:** `.agents/scripts/aidevops-update-check.sh` (or wherever `aidevops update` orchestrates) — same detection + advisory pattern as setup.sh. One-time advisory file in `~/.aidevops/advisories/` so it doesn't nag.

- **EDIT:** `TODO.md` — add the t2885 line with `ref:GH#NNN` (issue number filled in by claim-task-id.sh).

### Reference patterns

- Detection + idempotent apply: pattern from `.agents/scripts/install-hooks-helper.sh:install` and `.agents/scripts/install-task-id-guard.sh:install`.
- macOS sub-shell logic: `setup.sh` already uses `[[ "$(uname -s)" == "Darwin" ]]` guards.
- Advisory mechanism: `~/.aidevops/advisories/*.advisory` files documented in `prompts/build.txt` "Security" section.

### Verification

```bash
# Lint
shellcheck .agents/scripts/worktree-exclusions-helper.sh
shellcheck .agents/scripts/worktree-helper.sh

# Behaviour: create a temp worktree and confirm exclusions applied
TMPWT=$(mktemp -d)/wt
git -C ~/Git/aidevops worktree add -b chore/t2885-test "$TMPWT" main
test -f "$TMPWT/.metadata_never_index" && echo "spotlight: ok"
tmutil isexcluded "$TMPWT" | grep -q '\[Excluded\]' && echo "tmutil: ok"
git -C ~/Git/aidevops worktree remove --force "$TMPWT"

# Backfill: dry-run
worktree-exclusions-helper.sh backfill --dry-run

# Detect
worktree-exclusions-helper.sh detect
```

### Files Scope

- .agents/scripts/worktree-exclusions-helper.sh
- .agents/scripts/worktree-helper.sh
- setup.sh
- .agents/scripts/aidevops-update-check.sh
- TODO.md
- todo/tasks/t2885-brief.md

### Complexity Impact

- `worktree-helper.sh::cmd_add` grows by ~3 lines (one helper call). No risk to the 100-line function gate.
- New file `worktree-exclusions-helper.sh` is a fresh script with discrete subcommand functions, each well under the threshold.
- No existing function body grows past 80 lines.

## Acceptance

1. Creating a new worktree via `worktree-helper.sh add` (or `wt switch -c`) automatically applies Spotlight + Time Machine exclusions on macOS.
2. `worktree-exclusions-helper.sh backfill` applies exclusions to all worktrees registered across `~/.config/aidevops/repos.json` repos. Idempotent.
3. `worktree-exclusions-helper.sh detect` reports which tools are installed (Spotlight, Time Machine, Backblaze) and which ones are scripted vs require manual setup.
4. `setup.sh` and `aidevops update` detect installed backup tools and print the Backblaze sudo command once. Advisory dismissable per existing mechanism.
5. shellcheck zero violations on both modified and new files.
6. Worktree creation is never blocked by exclusion failure (all calls wrapped `|| true`).

## PR Conventions

Resolves #<filled-in-after-issue-creation>.

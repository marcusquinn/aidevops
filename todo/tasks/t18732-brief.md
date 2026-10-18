## What

Let repos opt out of aidevops README badges, and never write badges to upstream mirrors.

## Why

Weekly routine r921 runs `badges-sync-helper.sh --apply --json`, which acts on every `NO-BLOCK` repo. There's no way to say "this repo deliberately has no managed block", and repos registered with `mirror_upstream` (private mirrors synced from an upstream we don't own) are treated as owned. Next run would open badge PRs on:

- Two private mirror repos (`<owner>/<mirror-a>`, `<owner>/<mirror-b>`) whose README is kept identical to upstream for clean syncs; their repos.json notes say "Do not run pulse/dev work here".
- The maintainer's GitHub profile repo (`<owner>/<owner>`); maintainer decided to keep it without a block.

`marcusquinn/aidevops` is only protected by a hard-coded slug check in sync, and `badges-check-helper.sh` still reports it as `NO-BLOCK` with a "run: aidevops badges sync --apply" hint.

## How

- `.agents/scripts/badges-check-helper.sh`: read `mirror_upstream` and `badges` from repos.json; classify `MIRROR` (non-empty `mirror_upstream`) and `OPTED-OUT` (`badges: false`) before any README inspection; count them in the summary; neither is actionable.
- `.agents/scripts/badges-sync-helper.sh`: the read-only registry predicate also covers `mirror_upstream` and `badges: false` (defence in depth for `--repo`).
- `.agents/reference/repos-json-fields.md`: document `badges`.

### Files Scope

- `.agents/scripts/badges-check-helper.sh`
- `.agents/scripts/badges-sync-helper.sh`
- `.agents/reference/repos-json-fields.md`

## Acceptance Criteria

- With the real registry, repos with `mirror_upstream` report `MIRROR`; a repo with `badges: false` reports `OPTED-OUT`; neither appears in `badges-sync-helper.sh` dry-run actions.
- Existing `test-badges-sync-worktree.sh` passes; ShellCheck clean.

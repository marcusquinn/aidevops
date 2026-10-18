## What

Keep managed README badge blocks current automatically. Today a template fix
(e.g. GH#34145, GH#35012) only reaches a repo when someone runs
`aidevops init` or `aidevops badges sync --apply` by hand, so ~50 managed repos
kept an outdated badge block (language chart inline with badges) for weeks.

Two gaps:

1. `badges-sync-helper.sh --apply` mutates canonical checkouts:
   `git pull --ff-only` then `git checkout -q -B <branch>` in the canonical
   repo path, commit, push, then checkout back. This violates the
   linked-worktree invariant (interactive and automated sessions never switch
   or create branches in a canonical checkout) and skips any repo whose
   canonical checkout is dirty or off its default branch.
2. No routine runs drift detection + remediation. `badges-check-helper.sh`
   is only run manually.

## How

- `.agents/scripts/badges-sync-helper.sh`: create a linked worktree per repo
  from `origin/<default-branch>` (via `worktree-helper.sh add`), run
  `readme-badges-helper.sh inject` + `repo-metrics-helper.sh generate` +
  `check` inside it, commit, push, open the PR with `gh_create_pr`, then
  release the worktree. Never touch the canonical checkout.
- Add a weekly routine (pulse/maintenance path that already iterates
  maintained repos, see `test-maintenance-repo-selection.sh` for the repo
  selector) that runs `badges-check-helper.sh --json` and opens one sync PR per
  DRIFTED owned-org repo, deduplicating against an open sync PR.
- Respect owned-org scope (`badge-orgs.conf`), STARTER-OWNED, local-only and
  contributed repos exactly as today.

### Files Scope

- `.agents/scripts/badges-sync-helper.sh`
- `.agents/scripts/badges-check-helper.sh`
- `.agents/aidevops/badges.md`

## Notes

Routine registration path is not yet known: discover it during implementation
(search `reference/routines.md` and existing maintenance routines).

## Acceptance

- `--apply` leaves every canonical checkout's branch, HEAD and working tree
  unchanged.
- A drifted owned-org repo receives exactly one open sync PR per drift; re-runs
  do not duplicate it.
- A current repo produces no PR.

## Verification

Run `badges-sync-helper.sh --apply --repo <drifted test repo>` and confirm
`git -C <canonical> status -sb` is unchanged and a PR exists; run twice to
confirm idempotence; existing badge tests pass.

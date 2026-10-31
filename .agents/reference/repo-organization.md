<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repository Organization

Keep canonical clones under a Git workspace, organized by repository owner rather
than technology. The default workspace is `~/Git`.

## Default clone locations

| Repository ownership | Default path |
|----------------------|--------------|
| Personal account | `~/Git/<repo>` |
| Organization or third party | `~/Git/<owner>/<repo>` |
| Local-only, legacy, or exceptional | Explicit `repos.json` path |

Examples:

```bash
gh repo clone personal-account/project ~/Git/project
gh repo clone example-org/service ~/Git/example-org/service
```

Cloning from inside a canonical checkout is allowed when an explicit destination
resolves outside every canonical checkout and is absent or an empty directory.
This applies to `git clone` and the Git command run by `gh repo clone`. Omitted
destinations, destinations inside a canonical checkout, and non-empty targets
remain blocked there. Use the workspace layout above, or run the clone from the
destination's parent. Auxiliary template and separate-Git-directory paths must
also remain outside canonical checkouts and be absent or empty. The allowance
accepts a conservative set of clone options; unknown options and Git
configuration or environment overrides stay blocked from a canonical checkout.
GitHub CLI's credential resets and root-controlled `gh auth git-credential`
helpers are allowed so the documented `gh repo clone` command works; arbitrary
shell credential helpers are not.

Normalize new owner directory names to lowercase. Repository names retain their
upstream spelling. Configure personal aliases per Git host in `repos.json`; do
not assume that one GitHub login is the user's identity on every host:

```json
{
  "git_parent_dirs": ["~/Git"],
  "personal_owners": {
    "github.com": ["personal-account"],
    "gitlab.example": ["work-alias"]
  }
}
```

An explicit `initialized_repos[].path` and `owner/repo` slug remain authoritative.
This preserves non-GitHub hosts, offline volumes, local-only repositories,
historic layouts, and deliberate exceptions.

## Discovery boundary

Repository scans inspect direct children and one owner-directory level. They
exclude `_worktrees`, `_archive`, other underscore/dot-prefixed operational
directories, linked worktrees, submodules, and repositories nested inside an
already detected repository. Scans never recurse to arbitrary depth.

## Worktrees

Create worktrees under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`.
Root-level repositories use flat `<repo>-<branch-slug>` names; owner-nested
repositories use `<owner>-<repo>-<branch-slug>` to avoid collisions.
`worktree-helper.sh add <branch>` derives this path. Existing sibling worktrees
from older versions remain valid until cleanup removes them safely.

Examples:

| Canonical clone | Generated worktree example |
|-----------------|----------------------------|
| `~/Git/project` | `~/Git/_worktrees/project-feature-change` |
| `~/Git/example-org/service` | `~/Git/_worktrees/example-org-service-feature-change` |

## Migration safety

Setup and update never move canonical repositories. Use a separate, reviewed
transaction:

```bash
aidevops repos migrate-layout plan --workspace ~/Git --output plan.json
aidevops repos migrate-layout apply --plan plan.json --confirm <plan-sha256>
aidevops repos migrate-layout status --receipt <receipt-id>
aidevops repos migrate-layout rollback --receipt <receipt-id> --confirm <receipt-sha256>
```

`plan` is non-mutating. It inventories dirty state, branches, stashes,
submodules, linked worktrees, registrations, local consumers, and collisions.
Its summary also reports active-path consumers and the exact confirmed apply
command to resume. When a source or destination is active, save a session
checkpoint with `/checkpoint`, exit every process using either path, restart
from outside both paths, and run that resume command. The migration does not
create compatibility symlinks for a live process.
Explicit `initialized_repos[].path` entries remain excluded unless planning uses
`--include-registered-paths`; that approval is recorded in the content-hashed
plan. Repeat `--source <path>` to limit a plan to exact repositories, such as one
hosting fleet. Native consumer inventory and every apply guard still apply, and an
empty selection is refused. Apply rechecks the complete before-state, rejects cross-device moves and
active-path ambiguity, moves one repository at a time, and writes owner-private
append-only receipts. Replaying apply resumes verified steps. Rollback requires
the latest receipt hash and stops rather than overwriting post-plan changes.

Non-GitHub, local-only, unsupported, and already-conforming repositories are not
moved. Case-only and destination-inside-source moves use private same-filesystem
staging; destination collisions always fail closed.

### Follow a GitHub transfer or rename

After the transfer or rename has completed on GitHub, update a registered,
clean canonical checkout through the audited recovery helper, not a direct
`git remote set-url` in the canonical checkout:

```bash
canonical-recovery-helper.sh follow-transfer --repo /path/to/checkout \
  --slug NEW_OWNER/NEW_NAME --confirm FOLLOW_REPOSITORY_TRANSFER
aidevops repos migrate-layout plan --workspace ~/Git --output plan.json \
  --include-registered-paths --source /path/to/checkout
```

The helper verifies that the old and new GitHub slugs resolve to the same
immutable repository ID and requested canonical name. It preserves the origin
transport scheme and `.git` suffix, updates only the matching `repos.json` slug
(keeping its path and other metadata), and records authorization and completion
in `~/.aidevops/logs/canonical-recovery-audit.jsonl`. It refuses unregistered or
ambiguous identities, conflicting registrations, multiple origin URLs, explicit
push URLs, and URL rewrites. API or audit verification failures stop the operation.
If replacing the registry fails, the origin URL is restored. After an interruption
or completion-audit failure, inspect both origin and registry before retrying;
the authorization receipt remains available for recovery.

This command does not perform a GitHub transfer, fetch, change branches, or move
files. Run the printed layout plan separately; `--include-registered-paths` is
needed because the existing registration has an explicit path. Review and apply
the content-hashed plan using the migration safety workflow above. Already
conforming paths produce no move, and existing collision/active-consumer guards
still apply.

## Direct-write workspace boundary

Direct file-mutation tools may write across repositories when both identities
resolve beneath `${AIDEVOPS_GIT_WORKSPACE_ROOT:-~/Git}` and the target is a linked
worktree. Canonical checkouts remain read-only regardless of their location.
Resolved worktree, Git directory, and common-directory paths must all remain
inside the workspace, so sibling-prefix paths and symlink escapes are denied.
Sanctioned outside-Git paths remain separate: a symlink traversed from inside a
Git worktree cannot use that allowance to escape the trusted workspace.

## Related

- `workflows/worktree.md` — worktree mechanics
- `workflows/git-workflow.md` — issue/PR flow
- `tools/wordpress/wp-dev.md` — WordPress-specific development

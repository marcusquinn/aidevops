## What

Let an issue that is blocked on a third-party upstream release declare that
gate in a machine-checkable form, so Pulse unblocks it automatically once a
tagged upstream release contains the required commit.

Marker (issue body, trusted author only):

```text
<!-- aidevops:upstream-release-gate repo=OWNER/REPO commit=<40-hex SHA> -->
```

The existing stale-blocked sweep (`reconcile_stale_blocked_issues`) already
visits every open `status:blocked` issue. Extend `_der_try_unblock` so that an
issue with no native blocker and one or more gate markers is unblocked
(`status:blocked` -> `status:available`) only when every gate is satisfied:
some tag of `OWNER/REPO` contains the commit (`compare/<commit>...<tag>` is
`ahead` or `identical`). Issue-number/task blockers declared alongside the
gate must also be closed. All existing holds still win.

## Why

Observed in a managed Cloudron package repo: a worker-ready feature issue was
correctly set `status:blocked` until the upstream project (which publishes git
tags but no GitHub Releases) tags a release containing a specific commit. The
blocker was prose only ("Blocked by: external ..."), so nothing in the
framework re-checked it. The package upstream monitor would only file a
separate generic "upstream vX available" issue; the gated feature issue would
stay blocked until a human remembered to check. Any issue gated on an
upstream release has the same gap.

## How

- `NEW: .agents/scripts/upstream-release-gate-lib.sh` — marker parsing and a
  bounded tag-containment check (newest tags first, capped, fail closed on
  API/shape errors and malformed markers). Read-only.
- `EDIT: .agents/scripts/dependency-event-reconciler.sh` — source the library,
  add a trusted-author check (`OWNER`, `MEMBER`, `COLLABORATOR`) and wire it
  into `_der_try_unblock` beside the declared blocker path.
- `NEW: .agents/scripts/tests/test-upstream-release-gate.sh` — wiring cases
  with a `gh` double.
- `EDIT: .agents/workflows/brief.md` and `.agents/reference/task-lifecycle.md`
  — document the marker in "Ordered Work / Dependencies".
- `EDIT: .agents/templates/brief-template.md` — mention the marker in the
  "Blocked by" field.

## Files Scope

- `.agents/scripts/upstream-release-gate-lib.sh`
- `.agents/scripts/dependency-event-reconciler.sh`
- `.agents/scripts/tests/test-upstream-release-gate.sh`
- `.agents/workflows/brief.md`
- `.agents/reference/task-lifecycle.md`
- `.agents/templates/brief-template.md`

## Acceptance Criteria

- A `status:blocked` issue with a trusted gate whose commit is in a tag is set
  to `status:available` by the stale-blocked sweep.
- A gate whose commit is in no tag leaves the issue blocked (`DER_NOT_READY`).
- Untrusted authors, malformed markers, API errors and holds leave the issue
  blocked.
- Issues without gate markers behave exactly as before.

## Verification

```bash
shellcheck -x .agents/scripts/upstream-release-gate-lib.sh .agents/scripts/dependency-event-reconciler.sh
bash .agents/scripts/tests/test-upstream-release-gate.sh
bash .agents/scripts/tests/test-dependency-event-reconciler.sh
```

Read-only live check against a public upstream: a gate on a commit already in
a tag reports satisfied; a gate on an untagged commit reports not ready.

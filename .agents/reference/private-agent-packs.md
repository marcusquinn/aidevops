<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Private Agent Packs

Private agent packs are Git repositories that sync into aidevops as custom agents
while keeping their source private. They need explicit data-flow contracts because
the useful outputs often sit between private operational context and public-safe
summaries.

## Operating Model

1. Keep pack source in a private repo.
2. Add `agent-pack.json` at the repo root using
   `.agents/templates/agent-source-repo/agent-pack.json` as the model.
3. Store durable private artifacts under
   `~/.aidevops/.agent-workspace/work/<pack-name>/`.
4. Surface only `public-safe` outputs in chat, GitHub issues/PRs, logs, or commits.

## Manifest Contract

The manifest has four data-flow sections:

- `inputs[]`: what the pack reads, with sensitivity and allowed source locations.
- `outputs[]`: what the pack produces, with per-output artifact paths and
  sensitivity tiers.
- `artifact_paths`: durable local directories used by the pack.
- `sensitivity`: the default tier and the complete tier enum.

Each output must declare:

- `name`
- `description`
- `artifact_path`
- `sensitivity`
- `allowed_destinations`

Validators should fail manifests that omit an output sensitivity tier, omit an
artifact path, or use a tier outside the supported enum.

## Privacy Tiers

| Tier | Use for | Allowed destinations |
|------|---------|----------------------|
| `public-safe` | Redacted summaries, docs, issues, PR descriptions, commit messages, and logs. | `chat`, `github-issue-pr`, `git-commit`, `logs`, `local-workspace` |
| `private-local` | Private repo details, client context, unpublished strategy, internal notes. | `local-workspace` |
| `secret-adjacent` | Secret paths, vault metadata, access-boundary notes, redacted security findings. | `local-workspace`; public summaries must remove operational detail |
| `never-export` | Actual secret values, tokens, private keys, recovery codes, unredacted credentials. | None; use the approved secret store instead |

## Destination Rules

- Chat output: `public-safe` only.
- Git commits: `public-safe` only, unless committing private-local pack source to the
  private source repo is the explicit task.
- Logs: `public-safe` only; avoid logging private operational detail.
- Local workspace artifacts: `public-safe`, `private-local`, and `secret-adjacent`.
- GitHub issue/PR text: `public-safe` only.
- Secret stores: use for `never-export`; do not create local artifact files with raw
  secret values.

## Session Workflow

1. Read `agent-pack.json` before producing artifacts.
2. Match the planned artifact to an `outputs[]` entry.
3. Write to that output's `artifact_path`.
4. Before surfacing content outside the local workspace, verify the output tier is
   `public-safe`.
5. If the tier is too broad for the content, downgrade the artifact and create a
   redacted `public-safe` summary instead.

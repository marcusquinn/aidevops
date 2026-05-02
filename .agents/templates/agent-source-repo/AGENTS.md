<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Private Agent Pack Guide

This repository is an aidevops private agent source. Keep the data-flow contract in
`agent-pack.json` current whenever an agent starts consuming new inputs or producing
new artifacts.

## Data-Flow Contract

- Declare every expected input in `inputs[]` with a `name`, `description`,
  `sensitivity`, and `allowed_sources` list.
- Declare every produced artifact in `outputs[]` with a `name`, `description`,
  `artifact_path`, `sensitivity`, and `allowed_destinations` list.
- Keep paths under `~/.aidevops/.agent-workspace/work/<pack-name>/` unless the
  output is explicitly safe to commit to this private repository.

## Privacy Tiers

| Tier | Meaning | Allowed destinations |
|------|---------|----------------------|
| `public-safe` | Redacted output safe for chat, GitHub issues/PRs, commits, logs, and local artifacts. | `chat`, `github-issue-pr`, `git-commit`, `logs`, `local-workspace` |
| `private-local` | Private client, repo, or operational context. | `local-workspace` only |
| `secret-adjacent` | Mentions credential locations, access boundaries, or secret handling without values. | `local-workspace`; summarize publicly only after redaction |
| `never-export` | Raw secrets, tokens, private keys, recovery codes, or unredacted credential material. | Do not write, log, commit, or paste; use approved secret stores |

## Agent Operating Rules

- Before writing an artifact, choose the output entry that matches the content.
- If content contains private names, unreleased plans, client data, or repo-private
  context, treat it as `private-local` unless the pack contract says otherwise.
- If content identifies where secrets live or how access is granted, treat it as
  `secret-adjacent` even when no secret value is present.
- If content contains an actual secret value, do not export it. Move it to the
  approved secret store and record only a redacted note.
- Public GitHub text must be derived only from `public-safe` outputs.

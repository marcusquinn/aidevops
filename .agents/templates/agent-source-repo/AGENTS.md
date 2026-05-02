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

<!-- aidevops:agent-source-template:start -->
<!-- aidevops:agent-source-template-version: 1 -->

# Private Agent Source Repository

This repo stores private aidevops agents and shared capabilities. Keep the structure aligned with the core framework so agents can move between private packs and the public framework without re-learning conventions.

## Organization Model

- Root `.agents/{agent}.md`: primary strategy agents.
- Matching `.agents/{agent}/`: extended context for that primary agent.
- `.agents/tools/`: reusable capabilities any agent can apply.
- `.agents/services/`: external integrations and service-specific runbooks.
- `.agents/workflows/`: repeatable processes.
- `.agents/reference/`: operating rules, architecture notes, and decision records.
- `.agents/scripts/`: flat helper scripts; use `*-helper.sh` for agent-callable tools.
- `.agents/configs/`, `.agents/templates/`, `.agents/rules/`, `.agents/tests/`: shared assets.

Prefer flat files and prefix-based names. Add subdirectories only when a prefix group becomes too large to scan quickly.

## Agent Creation Rules

1. Create the primary agent as `.agents/<name>.md` with concise routing context.
2. Add deeper knowledge under `.agents/<name>/` only when needed.
3. Put reusable how-to knowledge in `tools/`, `services/`, `workflows/`, or `reference/` instead of burying it in one agent directory.
4. Keep private repo names, client names, credentials, and internal URLs out of public TODO entries, issue bodies, PR comments, and logs.
5. Verify new scripts with `shellcheck` and include explicit `return 0` / `return 1` in every function.

## Sync Contract

Register this repo with `aidevops sources add <path>` for private-agent sync. Mark it in `~/.config/aidevops/repos.json` with `"agent_source": true` or `"role": "agent-source"` so `aidevops init` and `aidevops update` can seed and refresh the framework-owned organization guidance.

<!-- aidevops:agent-source-template:end -->

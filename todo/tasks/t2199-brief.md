<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2199 Brief — Make gh_create_pr and gh_create_issue wrappers discoverable in interactive sessions

**Issue:** GH#19686 (marcusquinn/aidevops) — issue body is the canonical spec.

## Session origin

Filed 2026-04-18 from the t2189 interactive session (PR #19682). During t2189 I ran `type gh_create_pr` and got "not found". The wrappers exist in `shared-constants.sh` but aren't available unless that file is sourced — which the agent's tool-invocation shell doesn't do by default. The build.txt rule "NEVER use raw `gh pr create`" is unfollowable in interactive contexts without these wrappers on PATH.

Workaround I used: raw `gh pr create --label origin:interactive` with explicit label. Worked, but the rule exists precisely to prevent operators (human or AI) from forgetting the label. Every unfollowable rule becomes a broken rule.

## What / Why / How

See issue body at https://github.com/marcusquinn/aidevops/issues/19686 for:
- Preferred option: thin PATH shims at `.agents/bin/gh_create_pr` and `.agents/bin/gh_create_issue`
- Rejected option: shell init sourcing (doesn't work for agent tool-call shells)
- setup.sh symlink integration into `~/.aidevops/bin/`
- Shim pattern: source shared-constants.sh, exec function with `"$@"`

## Acceptance criteria

Listed in the issue body. Key gates: `type gh_create_pr` returns PATH hit after `aidevops update`; auto-applies `origin:interactive` or `origin:worker` based on `AIDEVOPS_HEADLESS`; works from any directory.

## Tier

`tier:standard` — 2 new shim files + setup.sh install logic + uninstall path + docs.

## Relation to other tasks

- Should use `_set_origin_label` from t2200 internally (sequencing: t2200 ships first ideally, or both coordinate on the helper signature)

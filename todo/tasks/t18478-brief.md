<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18478: Repair Anthropic adaptive thinking and support local interactive defaults

## Pre-flight

- [x] Memory recall: Anthropic Opus OAuth routing query returned no relevant lessons.
- [x] Discovery pass: no related merged or open PRs in prework search; target-file history checked against current main.
- [x] File refs verified: provider auth, model routing, interactive defaults, documentation, and existing test files are present at HEAD.
- [x] Tier: standard — decided auth/request-shaping contract with focused runtime and test verification.
- [x] Seeded draft PR skipped — implementation and review remain owned by this interactive full-loop session.

## What

OpenCode Anthropic OAuth requests for Opus 5.5 must accept both medium and xhigh
effort with structured tool calls. A per-user routing override must allow an
interactive medium-effort default without changing the thinking-tier xhigh route
or replacing explicit model/variant pins. Shared provider defaults stay unchanged.

## Why

Unsupported adaptive metadata caused Opus 5.5 requests to fail before a tool
could execute; a separate interactive default is needed so the daily driver
does not silently downgrade thinking-tier effort.

## How

### Files to Modify

- `.agents/plugins/opencode-aidevops/provider-auth-body.mjs`: normalize an
  adaptive `thinking` object to the Messages API wire shape before serializing
  and computing the billing-header hash; leave `output_config.effort` intact.
- `.agents/plugins/opencode-aidevops/model-routing.mjs`: parse and merge the
  optional `interactive_default` independently of canonical tier reasoning.
- `.agents/plugins/opencode-aidevops/specialist-advisor.mjs`: apply that default
  only when the interactive model/variant is not explicitly pinned.
- `.agents/tools/context/model-routing.md`: document a per-user opt-in override
  and the unchanged shared model routing policy.
- Add focused cases to the existing plugin tests; do not add test infrastructure.

## Hazards and rollback

Anthropic auth and billing-header shaping are shared request paths: retain tool
schema normalization, effort selection, and billing-hash finalization. Preserve
the default fallback to the thinking-tier profile when `interactive_default` is
absent. Clearing the local override or reverting the patch restores previous
routing; an existing explicit pin must still win.

## Acceptance Criteria

- Run `node --test .agents/plugins/opencode-aidevops/tests/test-provider-auth-cch.mjs .agents/plugins/opencode-aidevops/tests/test-specialist-advisor.mjs .agents/plugins/opencode-aidevops/tests/test-model-routing.mjs` and `.agents/scripts/linters-local.sh --changed` in the linked worktree.
- In a fresh OpenCode process, verify that Opus 5.5 medium and xhigh can each
  call Read on a local non-secret file, and that an unpinned primary session
  selects the locally configured Opus default.
- Reject requests with unsupported adaptive metadata before they reach the API;
  retain the output effort and explicit user pins. Never publish a local OAuth
  account identity, credential, or per-user routing file in the PR.

## Files Scope

- `.agents/plugins/opencode-aidevops/provider-auth-body.mjs`
- `.agents/plugins/opencode-aidevops/model-routing.mjs`
- `.agents/plugins/opencode-aidevops/specialist-advisor.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-provider-auth-cch.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-specialist-advisor.mjs`
- `.agents/tools/context/model-routing.md`
- `CHANGELOG.md`
- `TODO.md`
- `todo/tasks/t18478-brief.md`

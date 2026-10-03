---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18492: fix: aidevops secret NAME -- cmd redacts short dictionary words (e.g. 'openai') from output

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `secret redaction short value` → 0 hits
- [x] Discovery pass: open issues searched for redaction and secret → none matching
- [x] File refs verified:
  - `.agents/scripts/secret-helper.sh` (1045 lines; stdin redactor block near :161-214, marker `[REDACTED]`)
  - `.agents/scripts/tests/test-secret-helper.sh` (578 lines)
  - `.agents/plugins/opencode-aidevops/registered-value-sources.mjs:22` (`MIN_VALUE_LENGTH = 8`)
- [x] Tier: `tier:standard`, a security-sensitive output path

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Issue:** GH#32614
- **Conversation context:** A TTS generator run through `aidevops secret <NAME> -- node …` printed model slugs such as `[REDACTED]-4omini-marin`, which made normal output look like a credential leak.

## What

`aidevops secret NAME -- cmd` output redaction must skip stored values shorter than 8 characters, matching the plugin redactor. When it skips one, it prints a one-line stderr warning that names the secret without the value.

## Why

Reproduction, with any single injected secret:

```bash
aidevops secret SOME_API_KEY -- node -e "console.log('a: openai-4omini | b: OpenAI | c: openai | d: nanogpt')"
# a: [REDACTED]-4omini | b: OpenAI | c: [REDACTED] | d: nanogpt
```

The lowercase word `openai` is masked wherever it appears; mixed case is not, and other words are not. The injected key does not contain it. The likely cause is that some stored secret value is the plain word `openai`, for example a provider-name setting, and the CLI redacts every stored value regardless of length. The OpenCode plugin redactor already enforces `MIN_VALUE_LENGTH = 8` (`registered-value-sources.mjs:22`), so the two redaction paths disagree.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?**
- [x] **Targets and reference pattern verified?** The plugin constant is the reference.
- [ ] **No semantic or design decision remains?** The worker confirms where the value list is built in `secret-helper.sh`. The secret-read guard blocked the filing session from reading that file.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** `secret-helper.sh` is not in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** A small change on a credential output path that needs careful regression proof.

## PR Conventions

Leaf task: the PR uses `Resolves #32614`.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/secret-helper.sh` around the stdin redactor (`marker = b"[REDACTED]"`, near line 214) and the function that collects the values to redact.
- **Load only if:** `.agents/plugins/opencode-aidevops/registered-value-sources.mjs:20-40` shows the plugin's length and placeholder rules to mirror.
- **Stop when:** the value-collection point and the replacement loop are identified.

### Files to Modify

- `EDIT: .agents/scripts/secret-helper.sh`: where redaction values are collected, drop values with `len < 8` and placeholder values (`""`, `***`, `[redacted]`, `not set`, `none`, `null`, `undefined`, `changeme`). Emit `WARN: secret <NAME> value too short to redact safely; not masked` to stderr, once per name.
- `EDIT: .agents/scripts/tests/test-secret-helper.sh`: add a case where a short fixture value (`openai`) passes through unredacted, and a case where a 24-character fixture is still redacted on stdout and stderr.

### Complete Write Surface

- **Callers/readers:** every `aidevops secret NAME -- cmd` invocation. Agents rely on its stdout and stderr, as documented in the `AGENTS.md` credential rules.
- **Writers/mutation paths:** only the redaction filter in `secret-helper.sh`; stored secrets are unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-secret-helper.sh` covers redaction (for example, at :222, :414 and :515).
- **Schemas/config:** N/A because no config key is required; if an env override is added, document it in the helper's usage text.
- **Generated/deployed mirrors:** `setup.sh` deploys it to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** N/A because stored secrets and their format are untouched.
- **Cleanup/rollback paths:** `git revert` of the PR commit restores the current masking.

### Implementation Steps

1. Locate value collection for the stdin or exec redactor and add the length and placeholder filter, mirroring the plugin constants.
2. Add the once-per-name stderr warning, naming the secret only.
3. Add the two test cases, then run ShellCheck and the test file.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A; the filter runs per invocation in memory.
- **Migration/rollback:** a revert restores full-length-agnostic masking.
- **Mixed-version/backward compatibility:** values of 8 characters or more are masked exactly as before. Only shorter values stop being masked, and those are too short to be meaningful credentials. The warning makes that visible.
- **Idempotency/retry:** unchanged.
- **Partial failure/recovery:** if the filter errors, keep the original value list, so the change fails closed toward over-redaction and never leaks.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/secret-helper.sh
bash .agents/scripts/tests/test-secret-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the test file proves both acceptance criteria. ShellCheck and the linter cover conventions.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** never print secret values; masking of values of 8 characters or more must not change.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/secret-helper.sh`
- `.agents/scripts/tests/test-secret-helper.sh`
- `TODO.md`
- `todo/tasks/t18492-brief.md`

## Acceptance Criteria

- [ ] A registered value shorter than 8 characters, such as `openai`, passes through `aidevops secret NAME -- cmd` output unmasked, and a one-line stderr warning names only the secret.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-secret-helper.sh"
  ```

- [ ] Regression guard: a normal-length secret value in stdout or stderr is still replaced with `[REDACTED]`.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/secret-helper.sh"
  ```

## Context & Decisions

- Chosen: mirror the plugin's 8-character minimum so both redaction paths agree. Ruled out: word-boundary matching, because a real secret can appear inside a longer token and must stay masked.
- Access note: in the filing session, the secret-read guard blocked reading `secret-helper.sh` ("secret-bearing basename") and reported a source-access broker mismatch. Workers may need `aidevops setup --scope source-access` reconciled.

## Relevant Files

- `.agents/scripts/secret-helper.sh:161` — redaction description.
- `.agents/plugins/opencode-aidevops/registered-value-sources.mjs:22` — reference minimum.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | locate collection point |
| Implementation | 20m | filter and warning |
| Verification | 20m | tests and ShellCheck |
| **Total** | **~1h** | |

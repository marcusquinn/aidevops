<!-- aidevops:brief-schema=v2 -->

# t18589: Surface OpenCode provider errors in ai-research-helper.sh failures

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `ai-research-helper opencode error output` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 commit (c842b638) / 0 related merged PRs in 48h / 0 open PRs touch `.agents/scripts/ai-research-helper.sh`
- [x] File refs verified: 4 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — not dispatch-path (absent from `self-hosting-files.conf`); output parsing choice left to implementer
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-05
- **Session:** opencode:interactive maintainer review of GH#33630
- **Created by:** ai-interactive
- **Conversation context:** Reviewing GH#33630 falsified its double-sourcing root cause. The real diagnostic gap is that `call_opencode` discards OpenCode's own error output, so the reporter could only see `OpenCode AI research call failed` and guessed at the cause.

## What

When the OpenCode provider path in `ai-research-helper.sh` fails, either from a non-zero `opencode run` exit or from output containing no response text, the helper logs one bounded, credential-scrubbed line to stderr. The line names the resolved model and gives the provider's error message. Example: `OpenCode AI research call failed (model=openai/gpt-5.4-mini): The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account.`

## Why

`call_opencode` (`.agents/scripts/ai-research-helper.sh:352-366`) captures `opencode run --format json ... 2>&1` into `raw` but never reports it on failure. Callers such as `pulse-fix-the-fixer-detector.sh:300-322` record the first 200 bytes of stderr as the failure rationale, so operators see no model and no cause. GH#33630 was filed with a wrong root cause because of this. The Anthropic path already surfaces `.error.message` (`ai-research-helper.sh:308-313`), so the OpenCode path is inconsistent with it.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** A small, local diagnostic change with a known reference pattern (`extract_opencode_text`, `scrub_credentials`). The worker still chooses the exact extraction precedence, so this is not `tier:simple`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/ai-research-helper.sh:236-266` — add `extract_opencode_error` next to `extract_opencode_text`, using the same strip_ansi + python line-scan pattern
- `EDIT: .agents/scripts/ai-research-helper.sh:351-366` — on both failure branches of `call_opencode`, log the model and the extracted, scrubbed, bounded error

### Complete Write Surface

- **Callers/readers:** `pulse-fix-the-fixer-detector.sh:300-322` reads `head -c 200` of stderr into `RATIONALE`/cooldown reasons (log-only; the comment path at `:536` runs only on a successful YES verdict). Other callers just propagate stderr.
- **Writers/mutation paths:** N/A. Stderr diagnostics only; exit codes stay 1/2 as today.
- **Existing verification/tests:** `.agents/scripts/tests/test-ai-research-helper-oauth-pool.sh` (Anthropic path; must still pass). Production path: `ai-research-helper.sh --provider opencode --model <bad-model> --prompt test`.
- **Schemas/config:** N/A. No config or schema change.
- **Generated/deployed mirrors:** Deployed copy under `~/.aidevops/agents/scripts/`, updated by `setup.sh`/release.
- **Migrations/backfills:** N/A.
- **Cleanup/rollback paths:** Trivial revert.

### Implementation Steps

1. `extract_opencode_error "$raw"`: strip ANSI, then prefer the last JSON event with `type == "error"` and print `error.data.message`, falling back to `error.message` and then `error.name`. Otherwise print the last plain (non-JSON) line that mentions an error, then the last plain line. Collapse whitespace.
2. In `call_opencode`, pass the result through `scrub_credentials` (`shared-constants.sh:669`) and truncate it to 120 characters, so a typical provider message still fits in the detector's 200-byte stderr capture after the log prefix and model. Log `<existing message> (model=<model_id>): <detail>`, or the existing message with only the model when no detail exists.
3. Run ShellCheck, then exercise the production path with a nonexistent model. Observed OpenCode error event shape: `{"type":"error",...,"error":{"name":"UnknownError","data":{"message":"Unexpected server error. ...","ref":"err_..."}}}`.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A. Pure stderr formatting in one process.
- **Migration/rollback:** Revert restores the generic message.
- **Mixed-version/backward compatibility:** The existing message text remains the prefix, so log greps still match. Exit codes are unchanged.
- **Idempotency/retry:** No state.
- **Partial failure/recovery:** Extraction failure falls back to the existing generic message (`|| detail=""`).
- **Secret exposure:** The provider output can echo request data. Always pass it through `scrub_credentials` and bound its length. Never log the prompt.

### Complexity Impact

- **Target function:** `call_opencode` in `.agents/scripts/ai-research-helper.sh`
- **Current line count:** 52 lines
- **Estimated growth:** about 8 lines (a small `_log_opencode_failure` helper keeps the function flat)
- **Projected post-change:** about 60 lines (60%)
- **Action required:** None

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/ai-research-helper.sh
AIDEVOPS_AI_RESEARCH_PROVIDER=opencode AIDEVOPS_AI_RESEARCH_OPENCODE_MODEL=openai/aidevops-nonexistent-model .agents/scripts/ai-research-helper.sh --prompt "reply ok" --max-tokens 10
bash .agents/scripts/tests/test-ai-research-helper-oauth-pool.sh
```

### Files Scope

- `.agents/scripts/ai-research-helper.sh`
- `TODO.md`
- `todo/tasks/t18589-brief.md`

## Acceptance Criteria

- [ ] A failing OpenCode call logs a single stderr line containing `model=<resolved model>` and the provider's error message from the JSON error event.

  ```yaml
  verify:
    method: codebase
    pattern: "extract_opencode_error"
    path: ".agents/scripts/ai-research-helper.sh"
  ```

- [ ] The detail passes through `scrub_credentials` and is at most 120 characters. The prompt text is never logged.
- [ ] Successful calls, exit codes (1 call failure, 2 no model/credentials) and the Anthropic path are unchanged; `test-ai-research-helper-oauth-pool.sh` passes.
- [ ] ShellCheck is clean for `.agents/scripts/ai-research-helper.sh`.

## Context & Decisions

- Ruled out the fixes proposed in GH#33630 (removing a direct source, an OAuth allowlist fallback). The cited mechanism does not exist.
- The 120-character bound keeps a typical provider message inside `pulse-fix-the-fixer-detector.sh`'s 200-byte stderr capture after the log prefix and model ID.

## Relevant Files

- `.agents/scripts/ai-research-helper.sh:236` — `extract_opencode_text` pattern to mirror
- `.agents/scripts/ai-research-helper.sh:308` — Anthropic error-surfacing precedent
- `.agents/scripts/shared-constants.sh:669` — `scrub_credentials`
- `.agents/scripts/pulse-fix-the-fixer-detector.sh:300` — primary stderr consumer

## Dependencies

- **Blocked by:** none
- **Blocks:** diagnosing future reports like GH#33630
- **External:** none

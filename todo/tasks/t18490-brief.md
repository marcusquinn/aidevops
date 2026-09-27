---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18490: docs: refresh TTS/music provider guidance (NanoGPT audio route, OpenAI TTS, OAuth scope) and Remotion BT.709 delivery flags

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `tts voice nanogpt remotion media verification` → 0 hits
- [x] Discovery pass: open issues searched for tts/nanogpt/remotion → only #32446 (NanoGPT Stagehand probe, unrelated scope)
- [x] File refs verified: `.agents/tools/voice/cloud-tts-apis.md` (69 lines), `.agents/tools/voice/voice-models.md` (139), `.agents/tools/video/remotion.md` (91), `.agents/content/production-audio.md` (137)
- [x] Tier: `tier:simple` — documentation-only edits with verified facts supplied inline

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Issue:** GH#32610
- **Conversation context:** An interactive brand-video production session (Remotion motion graphics, procedural soundtrack) ran a paid voice and music comparison through one NanoGPT key: 30 voices across 9 TTS providers and 8 AI music models, about 3.26 USD. The session found that aidevops voice guidance is out of date and has no aggregator route.

## What

Refresh the voice, music and Remotion reference docs so a future agent can pick a TTS or music route, discover models and prices, avoid double-billing on async jobs, and render broadcast-correct colour. Do this without rediscovering it from provider docs.

## Why

Evidence observed in the session:

- `cloud-tts-apis.md` describes OpenAI TTS as `tts-1`/`tts-1-hd` with 6 voices. Current OpenAI speech includes `gpt-4o-mini-tts`, which takes style `instructions` and has 11–13 voices.
- There is no NanoGPT guidance, although one NanoGPT key exposes:
  - About 45 TTS models: ElevenLabs v3 and Turbo 2.5, MiniMax 2.8, Gemini 2.5 Pro and 3.1 Flash TTS, Microsoft MAI-Voice-2, Inworld 1.5, xAI, ByteDance Seed, Qwen Audio 3, Kokoro and OpenAI.
  - About 30 music and sound-effect models, all through `POST https://api.nano-gpt.com/api/v1/audio/speech`.

  Discovery is `GET /api/v1/audio-models?type=tts&detailed=true`, which returns `pricing`, `supported_parameters.voices` and `max_chars`. Live prices differ from the static docs page; for example, ElevenLabs v3 is 0.17 USD per 1,000 characters.
- ElevenLabs and Qwen return an already-charged ticket (`{"status":"pending","runId":…}`) even from the synchronous endpoint. Poll `GET /api/tts/status?runId=&model=&cost=&paymentSource=&isApiRequest=`; resubmitting pays twice.
- Music models reject requests that lack model-specific fields. Each rejection is a 400 and is not billed.
  - MiniMax Music 3: an instrumental flag
  - ACE-Step: `tags`
  - Mureka: `prompt`
  - MiniMax 2.6: `lyrics`
- In the session, NanoGPT's OpenAI TTS upstream returned `invalid_api_key` (401, not billed) on both `/api/tts` and `/api/v1/audio/speech`. Treat that route as intermittently unavailable.
- The ChatGPT OAuth pool is only used for images (Codex responses endpoint), with no audio route. `/v1/audio/speech` needs an OpenAI Platform API key.
- `voice-models.md` offers EdgeTTS as "Free cloud" without noting that it relies on an unofficial consumer endpoint, which is unsuitable for commercial advertising.
- Remotion 4.0.529 H.264 output defaulted to `yuvj420p`/`bt470bg` full range. `--color-space=bt709 --pixel-format=yuv420p --crf=15` produced TV-range BT.709, and the brand colour sampled within one RGB step (#DD004A for #DC0049).

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?** Facts and target sections are listed below.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?**
- [x] **Bounded, reversible, low-consequence impact?** Documentation only.
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** No listed self-hosting file is touched.

**Selected tier:** `tier:simple`

**Tier rationale:** Four markdown files, with all facts supplied inline and no code.

## PR Conventions

Leaf task: the PR uses `Resolves #32610`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/tools/voice/cloud-tts-apis.md`:
  - Replace the `## OpenAI TTS` section with current models and voices, plus the `instructions` field.
  - Add a `## NanoGPT (one key, many providers)` section with the discovery curl, a sync request example, the async-ticket polling rule, the music extra-field table and the OpenAI-upstream caveat.
  - Add a `## ChatGPT OAuth scope` note.
- `EDIT: .agents/tools/voice/voice-models.md`: in `### By Use Case`, add a row "Compare many cloud voices with one key → NanoGPT (`cloud-tts-apis.md`)". Add an EdgeTTS commercial-use caveat under `## Text-to-Speech (TTS) — Voice Bridge Engines`.
- `EDIT: .agents/tools/video/remotion.md`: under `## CLI Commands`, add a delivery-render line with `--codec=h264 --crf=15 --pixel-format=yuv420p --color-space=bt709` and an `ffprobe -show_entries stream=pix_fmt,color_range,color_space` check.
- `EDIT: .agents/content/production-audio.md`: under `## Voice Tools`, add AI music bed options through NanoGPT (ElevenLabs Music, Lyria 3 Pro, MiniMax Music, Stable Audio 3, ACE-Step, Sonilo, Mureka). Note that generated beds are not cut to picture and need editing to scene changes.

### Complete Write Surface

- **Callers/readers:** agents that load `tools/voice/*.md`, `tools/video/remotion.md` and `content/production-audio.md` through `reference/domain-index.md` and subagent routing; no code reads these files.
- **Writers/mutation paths:** only the four markdown files listed above, for example `.agents/tools/voice/cloud-tts-apis.md`.
- **Existing verification/tests:** markdownlint in `.agents/scripts/linters-local.sh --changed`; no tests encode this prose.
- **Schemas/config:** N/A, because no frontmatter keys change (only body text).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/` to `~/.aidevops/agents/`; no index regeneration is needed for body-only edits.
- **Migrations/backfills:** N/A because this is documentation-only, with no persisted state.
- **Cleanup/rollback paths:** `git revert` of the PR commit restores the previous docs.

### Implementation Steps

1. Edit the four files as listed. Use `NANOGPT_API_KEY` as the placeholder, injected with `aidevops secret NANOGPT_API_KEY -- <cmd>`, and never inline a key.
2. Keep each file's progressive-disclosure style: short tables and one code block per provider.
3. Run markdownlint on the changed files.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A. These are static docs with no runtime writer.
- **Migration/rollback:** a revert restores the previous guidance; nothing depends on the new text.
- **Mixed-version/backward compatibility:** older deployed agents keep the old text until `setup.sh` redeploys; that is harmless.
- **Idempotency/retry:** re-applying the edits is a no-op.
- **Partial failure/recovery:** a partial edit leaves valid markdown; lint catches broken fences.

### Verification Before Dispatch

```bash
.agents/scripts/linters-local.sh --changed
rg -n "audio-models|tts/status|OAuth" .agents/tools/voice/cloud-tts-apis.md
rg -n "color-space=bt709" .agents/tools/video/remotion.md
```

- **Surface mapping:** the linter covers all four files. The two `rg` checks prove acceptance criteria 1 and 2.
- **Broad verification trigger:** not required, because only documentation changes.

### Scope Boundaries

**Hard boundaries:** documentation only; no script or plugin changes; no private project names, local paths or personal secret names.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/tools/voice/cloud-tts-apis.md`
- `.agents/tools/voice/voice-models.md`
- `.agents/tools/video/remotion.md`
- `.agents/content/production-audio.md`
- `TODO.md`
- `todo/tasks/t18490-brief.md`

## Acceptance Criteria

- [ ] `cloud-tts-apis.md` documents NanoGPT audio discovery, async-ticket polling, and that the ChatGPT OAuth pool does not cover TTS.

  ```yaml
  verify:
    method: codebase
    pattern: "audio-models|tts/status|OAuth"
    path: ".agents/tools/voice/cloud-tts-apis.md"
  ```

- [ ] `remotion.md` documents the BT.709 delivery flags.

  ```yaml
  verify:
    method: codebase
    pattern: "color-space=bt709"
    path: ".agents/tools/video/remotion.md"
  ```

- [ ] Regression guard: no private project names, local absolute paths or personal secret names are added, and changed files pass lint.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Chosen: document NanoGPT as a comparison and aggregation route. Ruled out: a new TTS helper script in this task, because docs are enough to prevent the rediscovery cost. A helper is a separate decision.
- Prices are volatile. The docs should point to the discovery endpoint and give order-of-magnitude examples only.

## Relevant Files

- `.agents/tools/voice/cloud-tts-apis.md:52` — current OpenAI section.
- `.agents/tools/voice/voice-models.md:80` — use-case table.
- `.agents/tools/video/remotion.md:63` — CLI commands.
- `.agents/content/production-audio.md:107` — voice tools.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | four short files |
| Implementation | 25m | prose and tables |
| Verification | 10m | lint and greps |
| **Total** | **~45m** | |

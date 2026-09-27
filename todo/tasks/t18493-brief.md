---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18493: feat: media-qa-helper for rendered video/audio deliverables (streams, loudness, contact sheets, whisper intelligibility)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `media verification loudness contact sheet whisper` → 0 hits
- [x] Discovery pass: `git ls-files .agents/scripts | rg media|video|audio|loudness` → only generation helpers (`video-gen-helper.sh`, `video-use-helper.py`, `transcription-helper.sh`); no QA helper
- [x] File refs verified:
  - `.agents/scripts/transcription-helper.sh` (1126 lines; `DEFAULT_MODEL="large-v3-turbo"` at :41)
  - `.agents/tools/video/video-editor.md` (76 lines; `## Verification Checklist` at :69)
  - `.agents/tools/video/remotion.md` (91 lines)
  - `.agents/tools/voice/transcription.md` (164 lines; `## Whisper (Local)` at :69)
- [x] Tier: `tier:standard`, a new file with a resolved interface

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Issue:** GH#32615
- **Conversation context:** A brand-video session had to invent ffmpeg, ffprobe and Whisper one-liners for every verification step. The `video` agent requires rendered-stream and perceptual checks, but no helper provides them.

## What

A new `.agents/scripts/media-qa-helper.sh` with machine-readable subcommands for verifying rendered media, linked from the video and voice docs.

## Why

The session's ad-hoc checks each caught a real defect:

- A stream and colour probe caught Remotion's default `yuvj420p`/`bt470bg` full-range output.
- A contact sheet of scene cuts caught a title overlap mid-transition.
- Frame colour sampling confirmed the brand colour after the colour fix (#DD004A for #DC0049).
- Whisper intelligibility (WER against the script) caught a homophone in the copy ("write"/"right") and a smeared final word from one voice ("free" heard as "Freddie").
- A Whisper pass over "instrumental" music beds flagged a sung jingle correctly. It also showed that "Thank you." on non-speech is a known hallucination.

Two problems slowed each check: ffmpeg's EBU R128 summary goes to stderr, and the OpenCode shell policy blocks `2>&1 | tail`. Local ggml Whisper models were already installed by desktop dictation apps and could be reused.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?** The subcommands and output fields are listed.
- [x] **Targets and reference pattern verified?** Follow `transcription-helper.sh` conventions.
- [x] **No semantic or design decision remains?**
- [x] **Bounded, reversible, low-consequence impact?** New file; docs only link it.
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?**

**Selected tier:** `tier:standard`

**Tier rationale:** One new shell helper with six small subcommands and three doc links.

## PR Conventions

Leaf task: the PR uses `Resolves #32615`.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/media-qa-helper.sh`, modelled on `.agents/scripts/transcription-helper.sh` (sources `shared-constants.sh`, `local var="$1"`, explicit returns, `main "$@"`).
- `EDIT: .agents/tools/video/video-editor.md:69` (`## Verification Checklist`): link `media-qa-helper.sh probe|loudness|contact-sheet|intelligibility`.
- `EDIT: .agents/tools/video/remotion.md`: add a line after `## CLI Commands` pointing at `media-qa-helper.sh probe` for colour verification.
- `EDIT: .agents/tools/voice/transcription.md:69` (`## Whisper (Local)`): add the local ggml model discovery order used by the helper.

### Complete Write Surface

- **Callers/readers:** agents following `tools/video/video-editor.md`, `tools/video/remotion.md` and the `video` primary agent verification rule. No scripts call it yet.
- **Writers/mutation paths:** the helper only writes the `--out` path the caller passes (contact-sheet PNG) and temporary 16 kHz WAVs that it deletes.
- **Existing verification/tests:** N/A because no existing tests encode this behaviour; verify by running `media-qa-helper.sh probe` and the other subcommands on an ffmpeg-generated clip, as below, and add test infrastructure only if requested.
- **Schemas/config:** the JSON output keys are the contract: `probe{codec,width,height,fps,pix_fmt,color_range,color_space,duration}`, `loudness{I,LRA,TP}`, `intelligibility{transcript,wer}`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*`. Check whether `.agents/scripts` has a helper index to update; if not, write N/A in the PR.
- **Migrations/backfills:** N/A because this is new-file-only, with no stored state.
- **Cleanup/rollback paths:** `git revert` of the PR commit removes `media-qa-helper.sh` and the doc links.

### Implementation Steps

1. Create the helper with these subcommands:
   - `probe`: ffprobe as JSON.
   - `loudness`: run `ffmpeg … -af ebur128=peak=true:framelog=quiet -f null -` and parse `I:`, `LRA:` and `Peak:` from stderr inside the script, so callers don't need redirection.
   - `contact-sheet --frames a,b,c | --scenes N --out PNG [--scale W]`: `select` plus `tile`.
   - `sample-colour --at S --crop w:h:x:y [--expect #RRGGBB]`: a 1×1 scale to `rgb24`, then hex output and a delta check.
   - `intelligibility --reference FILE [--model PATH]`: a 16 kHz mono WAV, `whisper-cli -np -nt`, and normalised WER.
   - `music-vocals`: Whisper, treating the "Thank you."/`*music*`/`you` hallucinations as no vocals.
2. Model discovery order: the `--model` flag, then `$WHISPER_MODEL`, then known local ggml locations (for example, dictation apps' `WhisperModels/ggml-large-v3-turbo.bin`), then fail with a clear message. Never download without an explicit flag.
3. Add the doc links.
4. Run ShellCheck, then exercise each subcommand on a generated clip.

### Hazards and Compatibility

- **Concurrency/atomicity:** temporary files use `mktemp`, so parallel runs don't collide.
- **Migration/rollback:** a new file, so rollback is deletion.
- **Mixed-version/backward compatibility:** handle both old and new ffmpeg ebur128 summary formats by matching labels, not line numbers.
- **Idempotency/retry:** read-only apart from the requested `--out`.
- **Partial failure/recovery:** a missing `ffmpeg` or `whisper-cli` exits non-zero with an install hint. `intelligibility` without a model exits 2.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/media-qa-helper.sh
ffmpeg -v error -y -f lavfi -i testsrc2=s=640x360:d=3 -f lavfi -i sine=d=3 -shortest -pix_fmt yuv420p /tmp/mqa.mp4
.agents/scripts/media-qa-helper.sh probe /tmp/mqa.mp4
.agents/scripts/media-qa-helper.sh loudness /tmp/mqa.mp4
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** ShellCheck and the linter cover conventions. `probe` and `loudness` on the generated clip prove acceptance criterion 1. `intelligibility` with a `say`-generated clip proves criterion 2 where a model exists.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** no network access or model downloads without explicit flags; no new CI gates or test runners.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/media-qa-helper.sh`
- `.agents/tools/video/video-editor.md`
- `.agents/tools/video/remotion.md`
- `.agents/tools/voice/transcription.md`
- `TODO.md`
- `todo/tasks/t18493-brief.md`

## Acceptance Criteria

- [ ] `media-qa-helper.sh probe` and `loudness` print JSON with `pix_fmt`, `color_space`, `I`, `LRA` and `TP` for a generated test clip, parsed inside the helper so callers run each as a single command.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/media-qa-helper.sh"
  ```

- [ ] `intelligibility` reports a transcript and WER against a reference text using a locally discovered ggml model, and exits non-zero with a clear message when no model or `whisper-cli` is available.

  ```yaml
  verify:
    method: codebase
    pattern: "intelligibility"
    path: ".agents/scripts/media-qa-helper.sh"
  ```

- [ ] Regression guard: `music-vocals` treats Whisper's "Thank you." non-speech hallucination as no vocals, and no subcommand downloads anything by default.

## Context & Decisions

- Chosen: one shell helper following existing conventions. Ruled out: a Node or Python package, which would add dependencies for work that ffmpeg and whisper-cli already do.

## Relevant Files

- `.agents/scripts/transcription-helper.sh:41` — model default and conventions.
- `.agents/tools/video/video-editor.md:69` — verification checklist.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** `ffmpeg`/`ffprobe` required; `whisper-cli` optional

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | conventions |
| Implementation | 1h15m | six subcommands |
| Verification | 30m | generated clips |
| **Total** | **~2h** | |

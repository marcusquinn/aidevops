---
description: Portrait phone talking-head reel editing recipe for repeated takes, timed overlays and platform-safe delivery
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Portrait Talking-Head Reel

Use for a real speaker's portrait phone recording with restarts, repeated lines
and a short-form social deliverable. This is an editing recipe, not the
synthetic-presenter pipeline in `content/production-video-08-talking-head-pipeline.md`.
Follow `tools/video/video-editor.md`, `tools/video/video-use-runtime.md` and
`tools/video/video-use-skill.md` for consent, source preservation, ASR/privacy,
EDL, rendering and verification. Do not install or run an upstream reel project
by default. Choose Remotion only if the requested overlays warrant a React
timeline; the existing ffmpeg/PIL/animation-slot path is also valid.

## From recording to cut

1. Probe rotation, dimensions, audio tracks and frame rate; inspect a few
   contact-sheet frames for face/chin position, gestures and lighting. Keep the
   original immutable. If a portrait working copy is needed, rotate/scale it
   deliberately and verify speech and source timestamps still agree.
2. Ask for an intended script if available. Transcribe **all** takes with
   verbatim word times using the approved ASR route. Match the selected audio
   track and cache to the source hash and ASR settings as the runtime adapter
   requires; do not assume local Whisper or hosted ASR is universally best.
3. Group alternatives by intended thought or sentence, including false starts.
   Prefer a fluent delivery faithful to the speaker's meaning. Later takes may
   improve, but do not override a better earlier take. Preserve a natural run
   of adjacent sentences when it works better than several isolated splices;
   keep useful breaths and reactions. Record chosen and rejected ranges and why
   in `edit/project.md`. Never add an unsaid line as a factual caption or card.
4. Select cut edges from word times with padding appropriate to ASR drift and
   the speaker's cadence. Inspect audio/frames where a word overlaps a pause;
   silence detection alone cannot locate spoken content. Preview each join,
   check framing and light continuity, and use fades to prevent audio clicks.
   Consider a modest face-centred framing change across a jump cut when it
   improves continuity; avoid a fixed snap/zoom schedule or automatic SFX.

## Timing spoken beats and captions

Keep a single ordered EDL of retained source ranges. For a source time `t`
inside retained range `i`, its output time is:

```text
output_time(t) = sum(duration of retained ranges before i) + (t - range_i.start)
```

For frame-based animation, quantise segment starts and word/beat positions to
the **actual output FPS** and rendered segment durations, not separately rounded
floating-point totals. If a time is outside every kept range, treat the beat as
invalid and fix the edit or beat; never silently place it at the nearest cut.
At adjacent range boundaries, assign the shared edge consistently to one range.
For multiple sources, identify both source ID and time. Recompute beat and
caption offsets when the EDL changes; render captions on the output timeline.

Plan overlays from the words the speaker actually says (name, number, list,
quote, punchline), timed at or just after the relevant word. Leave unillustrated
beats quiet. Confirm brand, pace and visual density in the edit strategy before
building effects. Do not assume memes, logos, fonts or music are licensed for
reuse; use user-owned or verified assets only. Apply captions after overlays or
otherwise verify they remain fully visible in the final composite.

## Portrait layout and QA

- Establish the deliverable canvas and **current platform-specific UI safe
  areas** for the intended placement; a preview/feed crop may differ from the
  full-screen reel. Do not adopt fixed pixel margins from an example video.
- Use a frame/grid from this recording to measure face, chin, hands and negative
  space. Keep essential text clear of the face and platform controls. Give
  captions a readable contrast and avoid collisions with cards or reaction
  overlays. Inspect the most zoomed-in frame too.
- Inspect rendered stills at the first/last frames, each cut, each overlay's
  landing word and the end card. Check both the clean video and, where possible,
  a target-platform UI/crop preview. Then check `ffprobe` streams/duration,
  caption sync, join audio, loudness and unexpected speech pauses by listening
  to the preview. Record checks not performed rather than claiming them.

Adapted as guidance from the MIT-licensed `mariagorskikh/talking-head-reel`
(`references/take-selection.md`, `references/layout.md`, `assets/Reel.example.tsx`).
No upstream scripts, preset timings or assets are bundled here.

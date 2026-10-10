---
description: Code-rendered motion design harness - seek(t) render contract, engine pitfalls, beat grid, sourced claims and frame-level critique for any engine
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Motion Design (code-rendered)

Use for launch films, product reels, kinetic type, explainers, loops and UI
motion rendered from code rather than edited footage. This file is the
**harness**: determinism, measurement, real assets and looking at your own
frames. It is deliberately not a house style. The model owns the concept, look,
technique and engine; style defaults below are critique questions, not bans.
Shared intake, budget, critic and artifact rules: `workflows/creative-production.md`.

## Pick the engine

| Route | Fits | Load |
|-------|------|------|
| Existing project framework | The repo already renders video; keep its engine | That framework's skill |
| Plain `seek(t)` page | One-off films, loops, kinetic type, zero dependencies; a common unprompted model choice | This file |
| Remotion (React) | Series, templates, data-driven or parameterised video, captions, Lambda/SaaS | `tools/video/remotion/remotion.md` |
| HyperFrames (HTML + GSAP) | Website/mockup-to-video, overlays inside an edit | `tools/video/video-use-skill.md` animation slots |
| Generated base + code layer | Physics or characters that are costly to hand-code, then traced or composited in code for a consistent look | `content/media-generation-providers.md` (budgeted) |

User or project choice wins. Otherwise choose by reuse needs, not habit.

## Render contract (every route)

- Every frame is a pure function of time: `seek(t)` (or Remotion's
  `useCurrentFrame()`) paints frame `t` with no carried state.
- No `setTimeout`, `requestAnimationFrame` timing, CSS transitions/animations,
  `Date` or `Math.random` in render mode. Seeded PRNG only (e.g. mulberry32).
- One timeline object holds every beat, move and audio cue; picture and sound
  read the same object, so a retime is one edit.
- Measure layout once after fonts load; ship fonts locally (or embedded) so a
  render never depends on the network.
- Time comes from the frame index (`i / fps`), never wall-clock. Optional
  motion blur: render N subframes per frame and average them (`tmix`).

Minimal plain-route capture: Playwright opens the page at the exact canvas size
with `deviceScaleFactor: 1`, awaits `document.fonts.ready`, then for each frame
calls `page.evaluate(t => window.seek(t), i / fps)`, screenshots the canvas
element, and writes PNGs to an `ffmpeg -f image2pipe` process encoding
`libx264 -crf 16 -pix_fmt yuv420p` with BT.709 tags (`-colorspace bt709
-color_primaries bt709 -color_trc bt709 -color_range tv`) and
`-movflags +faststart`. A live preview loop may run only when
`navigator.webdriver` is false.

## Engine pitfalls (model-agnostic facts)

- **Fonts fall back silently.** A screenshot cannot prove a glyph exists; check
  the font's character coverage for every on-screen string, or subset/embed
  known-good fonts.
- **Springs never land exactly.** Use closed-form springs so frame `t` needs no
  simulation, snap to the target after settling, and model a value with several
  targets as the sum of one spring per change (no restarts, no jumps).
- **Loops:** the last frame must hand off to frame 0. Entrances that start
  mid-state (a spring from 0.6 to 1) break the seam; motion-blur subframes of
  frame 0 sample the end of the loop.
- **Scaled text blurs** when rasterised once and transformed (`will-change`,
  cached layers). Re-rasterise text at its drawn size.
- **Colour:** deliver H.264 `yuv420p`, BT.709, limited range. Remotion 4.0.529
  defaults were observed full-range `yuvj420p`/`bt470bg`; verify the file, not
  the flags. Sample brand colours from the decoded output.
- **Timing measurements:** canvas drawing is lazy; time `seek` plus a pixel read,
  not `seek` alone.

## Sound and beat grid

- Supplied track: measure it before animating. Beat/onset times (e.g. librosa
  `beat_track`, onset peaks) go into the timeline: state changes on beats, big
  moments on downbeats, SFX on measured hits.
- No track: synthesize score and SFX from the same timeline (Web Audio
  `OfflineAudioContext`, or sample buffers written to WAV) so sync is exact.
- Duck music under voice; give UI sounds only to actions that carry meaning.
- Mix to the destination: about -14 LUFS integrated for normalised social
  platforms, about -16 for voice-led explainers, true peak at or below -1 dBTP.
  Check with `media-qa-helper.sh loudness`, then watch muted and listen
  audio-only. Voice-over: `media-qa-helper.sh intelligibility` against the
  script catches homophones and smeared words.

## Copy, claims and assets

- Every on-screen claim, number and quote comes from the product's live pages or
  the brief, logged with its source. No invented metrics, prices or UI screens.
- Use real screenshots, logos and colours captured from the product (Playwright)
  into `./assets`; animate the real thing rather than redrawing it from memory.
- Short on-screen lines readable at phone width; one name per thing.

## Formats

Author against a layout function (safe areas, measure, pins), not fixed pixels.
Recompose each format (16:9, 9:16, 1:1) from the same timeline; never crop a
16:9 render to vertical. Review every delivered format separately.

## Autonomy and decisions

Make creative calls without stopping; log each in one line in `DECISIONS.md`.
Show a shot list or storyboard first only in `draft` mode or when the user asks.
Pause only for consequential ambiguity that changes the goal, missing assets or
secrets, or spend beyond the approved budget.

## Look at your own frames

After the first full pass (not before it), produce evidence and read the images:

```bash
qa=~/.aidevops/agents/scripts/media-qa-helper.sh
$qa probe out/final.mp4                                   # codec, pix_fmt, BT.709, duration
$qa contact-sheet --every 0.5 --out out/contact.png out/final.mp4
$qa contact-sheet --every 1 --scale 360 --out out/phone.png out/final.mp4  # phone-width read
$qa strip --at 4.1 --count 12 --out out/strip.png out/final.mp4           # fast transition
$qa scan out/final.mp4             # freeze/black/silence spans: pointers, not verdicts
$qa loopcheck out/final.mp4        # loops only: exit 1 when the seam jumps
$qa compare out/a.mp4 out/b.mp4    # same source rendered twice: exit 1 if not deterministic
$qa loudness out/final.mp4
```

Sheets print `{sheets, grid, times}` so each tile maps to a timestamp, and stay
within the 1568 px review limit (extra pages are suffixed `-01`, `-02`).
`--scenes` sheets need hard cuts; smooth films return no scene tiles.

An independent critic (per `workflows/creative-production.md`) scores 1-10:
hook in the first 2 s, readability at phone width, motion quality, pacing and
variety, composition and hierarchy, brand and claim accuracy, sound sync. It
names the three most consequential problems with timestamps. Questions worth
asking, not rules to obey:

- Is this the generic default (centred title on a gradient, everything fading
  in, corner labels, frame borders, glow on UI, decorative particles)? If so,
  is it a choice?
- Does text overlap or pop during swaps and mid-transition frames?
- Does a `scan` freeze span read as an intentional hold or as dead time?
- Does any fast move read as copies rather than motion?
- Would this be indistinguishable from other AI reels made from the same prompt?

Fix, re-render only affected seconds where the engine allows, and keep a
before/after frame pair per fix. At most three rounds unless the budget allows
more; keep the best verified checkpoint.

## Deliverables

Master render plus each format, `contact.png`, a poster frame, the source that
re-renders the film, `DECISIONS.md`, and a README listing exact render commands
and only the checks that were actually run.

## External references (optional, not loaded)

- [Kimeur/motion-launch-videos](https://github.com/Kimeur/motion-launch-videos)
  (MIT): per-style Claude Code skills with an automated still critique (glyph
  coverage, collisions, contrast, loop tail, composition lean, decode flags).
- [alexdcd/code-to-video-studio](https://github.com/alexdcd/code-to-video-studio)
  (Apache-2.0): HyperFrames project scaffold with BRIEF/SCRIPT/STORYBOARD files
  and render QA.
- [heygen-com/hyperframes](https://github.com/heygen-com/hyperframes)
  (Apache-2.0): HTML + GSAP video framework.

Evaluate before adopting; do not install them by default.

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18511: Make the brand-identity.toon template valid TOON

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `brand identity toon template syntax` → 0 hits
- [x] Discovery pass: only `.agents/tools/design/brand-identity.md` defines the template; no script parses `context/brand-identity.toon` contents (`campaign-helper.sh:241` matches the path only)
- [x] File refs verified at HEAD `1da93b63c`
- [x] Tier: `tier:standard` — rewrite of two fenced examples with a format-validation step

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (found while designing t18509)
- **Conversation context:** While designing the TOON-based keywords registry (t18509), the brand identity "TOON" template was found to use TOML/INI-style `[section]` headers and `key = ""` assignments, which `toon-helper.sh validate` / `@toon-format/cli` cannot decode.

## What

The template and worked example in `.agents/tools/design/brand-identity.md` use valid TOON (`key: value`, 2-space nested objects, inline primitive arrays `key[N]: a,b`), keep the same 8 dimension names and fields, and decode cleanly with the TOON CLI. Agents are told how to treat existing legacy-syntax files.

## Why

`tools/context/toon.md` defines TOON as the framework's token-efficient format; a template that claims TOON but cannot be decoded breaks tooling (validation, JSON round-trip, `context/keywords` cross-references) and teaches agents an invalid syntax.

## How (Approach)

### Files to Modify

- `EDIT: .agents/tools/design/brand-identity.md:39-101` — template block.
- `EDIT: .agents/tools/design/brand-identity.md:144-173` — Launchpad example block.
- `EDIT: .agents/tools/design/brand-identity.md` Quick Reference — one line on validation and legacy-syntax conversion.

### Verification Before Dispatch

```bash
# extract each ```toon block to a temp file, then:
npx -y @toon-format/cli --decode <block>.toon
.agents/scripts/linters-local.sh --changed
```

### Files Scope

- `.agents/tools/design/brand-identity.md`
- `todo/tasks/t18511-brief.md`

## Acceptance Criteria

- [ ] Both fenced `toon` blocks in `brand-identity.md` decode with `@toon-format/cli --decode` without errors.
- [ ] The 8 dimension names (`visual_style`, `voice_and_tone`, `copywriting_patterns`, `imagery`, `iconography`, `buttons_and_forms`, `media_and_motion`, `brand_positioning`) are unchanged, so `design-md.md` Method 4 mapping still applies.
- [ ] Guidance says legacy `[section] key = ""` files are converted when next edited, not rewritten in bulk.
- [ ] Changed-file lint passes.

## Context & Decisions

- Enumerated option hints stay as YAML-style `#` comments are not TOON; move them to a short options table below the block instead.
- No bulk migration of user repos: files are converted by the next agent that edits them.

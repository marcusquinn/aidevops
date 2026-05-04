---
description: Optional Open Design integration for artifact-first design workflows
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Open Design Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [nexu-io/open-design](https://github.com/nexu-io/open-design) — Apache-2.0, local-first design artifact studio
- **Role in aidevops**: optional peripheral for sandboxed previews, design artifacts, decks, and media surfaces
- **Source of truth**: aidevops remains self-contained; `.agents/` and Google `DESIGN.md` stay canonical
- **Commands**: `/open-design`, `/design-artifact`, `open-design-helper.sh`
- **Local HTTPS**: prefer `localdev-helper.sh run --name open-design <command>` when Open Design only exposes localhost
- **Ingestion plan**: `tools/design/open-design-ingestion.md`

<!-- AI-CONTEXT-END -->

## Integration Model

Open Design is valuable as an **optional artifact studio** beside aidevops, not as a framework dependency. Keep the boundary explicit:

| Layer | Owner | Rule |
|-------|-------|------|
| Agent/source registry | aidevops | `.agents/` remains canonical; no Open Design symlink registry as source of truth |
| Design system | aidevops | Google `DESIGN.md` with YAML tokens, linted via `@google/design.md` |
| Preview/runtime | Open Design optional | Use for live iframe preview, exports, and artifact workspaces |
| Local HTTPS | aidevops | Use `localdev-helper.sh` when `.local` HTTPS is needed |
| Verification | aidevops | Run UI/accessibility/design verification after artifact generation |

## When to Use

- User asks for design artifacts: landing prototypes, decks, mobile screens, posters, carousels, HTML/PDF/PPTX exports.
- User wants a browser-based design studio with live preview and file workspace.
- Design task benefits from typed discovery forms, visual direction picking, or sandboxed iteration.
- Generated output should be reviewed with aidevops Playwright/accessibility gates before shipping.

Do not use for normal code changes, backend work, or any task where aidevops agents can directly implement and verify faster.

## Workflow

1. Check status: `open-design-helper.sh status`.
2. If missing and user opts in: `open-design-helper.sh install --execute`.
3. Ensure project has a valid Google `DESIGN.md`; create/lint via `tools/design/design-md.md`.
4. Start Open Design through local hosting if HTTPS is required:
   `open-design-helper.sh start --https-local open-design`.
5. Generate artifacts in Open Design, keeping work under its `.od/` workspace.
6. Copy selected outputs back into the project deliberately; do not import generated runtime state.
7. Verify with `workflows/ui-verification.md`, `email-design-test-helper.sh`, or relevant media checks.

## Skill Ingestion Methodology

Use build-agent rules before importing any Open Design skill:

1. **Deduplicate** against existing `.agents/` design, UI, email, video, and marketing agents.
2. **Classify** as adopt, adapt, combine, reference-only, or defer.
3. **Compress** to aidevops shape: `{name}-skill.md` plus flat `{name}-skill/` references, not nested runtime folders.
4. **Preserve provenance** with upstream URL, license, commit, and source notes in `configs/skill-sources.json` when imported.
5. **Keep tokens out of always-loaded docs**; point to focused references instead.
6. **Verify** with Markdown lint plus an artifact smoke test where practical.

## DESIGN.md Bridge

Open Design accepts broad Markdown design systems; aidevops uses the Google `DESIGN.md` standard with YAML tokens. Bridge rules:

- Convert Open Design systems into Google `DESIGN.md` before reuse.
- Run `npx @google/design.md lint DESIGN.md` and resolve errors.
- Use aidevops library examples as canonical where duplicates exist.
- Preserve educational/trademark disclaimers for third-party brand examples.

## Local Hosting Bridge

Open Design may print a localhost URL. For browser-safe HTTPS `.local` previews:

```bash
localdev-helper.sh init
localdev-helper.sh run --name open-design corepack pnpm tools-dev run web
```

Expected result: `https://open-design.local` proxies to the Open Design dev server with mkcert TLS.

## Related

- `tools/design/open-design-ingestion.md` — all Open Design skills classified for aidevops value
- `tools/design/design-md.md` — Google DESIGN.md workflow
- `tools/design/library/` — aidevops design-system library
- `workflows/ui-verification.md` — screenshot/accessibility verification
- `services/hosting/local-hosting.md` — localdev HTTPS proxy
- `tools/build-agent/build-agent.md` — ingestion and agent optimisation rules

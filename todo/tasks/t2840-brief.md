---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2840: knowledge / cases / matter framework planes (MVP)

## Pre-flight

- [x] Memory recall: `knowledge ingestion training data pipeline` → 0 hits — no relevant lessons (new framework primitive)
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h — substantial existing primitives surfaced (PageIndex, MinerU, PaddleOCR, Whisper, Ollama, contacts-helper, quickfile-helper, email-providers, email-sieve, simplification engine, memory FTS5, NMR + crypto-approval gate)
- [x] File refs verified: existing files at HEAD — `tools/context/pageindex.md`, `scripts/ollama-helper.sh`, `tools/document/extraction-schemas/10-classification.md`, `services/accounting/quickfile.md`, `tools/productivity/contacts.md`, `configs/email-providers.json.txt`, `configs/email-sieve-config.json.txt`
- [x] Tier: `tier:thinking` — design+decomposition work for a parent-task that won't dispatch directly. Children inherit per-phase tiers.

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none (this IS the parent)
- **Conversation context:** ~50K-token interactive design session iterating from "training data pipeline for repos" through dimensions of knowledge corpus + KPI/feedback loop + business cases + email ingestion + AI-drafted communications + PII/discovery sensitivity. Final scope is a 6-phase MVP across knowledge plane, sensitivity layer, kind-aware enrichment, cases plane, email channel, and comms agent.

## What

Establishes a standardised framework primitive — `_knowledge/`, `_cases/` and supporting infrastructure — applicable to any aidevops-managed repo. The framework primitive serves multiple matter types (code projects, business cases, limited companies, asset portfolios, customer relationships, investigations, research projects) via the same engine, parallel to existing `.agents/`, `TODO.md`, `todo/`.

**Concrete deliverables (MVP scope):**

1. Five user-data plane directories (`_` prefix, visible, sort-priority) with shared lifecycle infrastructure — `_knowledge/` and `_cases/` shipped in MVP; `_projects/`, `_performance/`, `_feedback/` post-MVP
2. Inbox → staging → sources → index lifecycle with NMR review gate (or auto-promote for maintainer/trusted sources)
3. Sensitivity classification + LLM routing layer that hard-fails on non-compliant providers for sensitive/privileged content
4. Kind-aware enrichment that extracts structured fields (parties, dates, amounts, etc.) for business/legal/accounts/asset document types
5. Email channel: `.eml` drop + IMAP polling + thread reconstruction + filter→case-attach
6. AI comms agent: `aidevops case draft` (human-gated, RAG over case sources, provenance footer) + `aidevops case chase` (template-only auto-send for routine follow-ups)

## Why

The same ingestion-index-retrieve pattern serves any long-running matter with documents around it. Building one engine means:

- Technical agents get queryable knowledge (vendor docs, recurring decisions, industry patterns)
- Business cases get evidence management + AI-drafted comms (disputes, complaints, breaches, debts)
- Limited companies get statutory document storage with audit trails (board minutes, statutory filings, contracts)
- Asset portfolios get maintenance + incident histories (property, vehicles, IP, investments)
- awardsapp t357 (file post-processing pipeline) becomes a thin SaaS layer over the same engine

Without this primitive: every repo that needs document-shaped data invents its own ingestion + index + retrieval pattern. With it: standardised, audit-trailed, sensitivity-aware, retrievable across all aidevops-managed repos via one CLI surface.

## Tier

`tier:thinking` — design + decomposition only. This parent does not dispatch (parent-task label). Each child phase inherits its own tier based on its scope (most are `tier:standard`).

### Tier rationale

Parent task with `parent-task` label blocks all dispatch. Tier on parent is informational only — it captures the design reasoning depth that produced the decomposition. Children's tiers are set per child brief.

## Phases

Pre-filed for parallelism within phases — auto-fire NOT used because phases overlap (P0.5 depends on P0; P1 depends on P0+P0.5; P4-P6 depend on P0+P0.5+P1).

Each phase ships as 2-3 child issues; children within a phase can run in parallel; phases overlap when their dependencies merge.

- **Phase P0** — knowledge plane skeleton (3 children: directory contract + provisioning, CLI + platform abstraction, review gate routine)
- **Phase P0.5** — sensitivity + LLM routing layer (3 children: classification schema + detector, LLM routing + audit log, Ollama integration + local LLM substrate)
- **Phase P1** — kind-aware enrichment (2 children: structured field extraction, PageIndex tree across corpus)
- **Phase P2** — `_inbox/` capture & triage (4 children: directory contract + provisioning, capture CLI + watch folder + audit log, triage routine with sensitivity-first gating + classification routing, pulse digest of stale items + weekly review)
- **Phase P4** — cases plane (3 children: case dossier contract + `aidevops case open`, case CLI surface, milestone + deadline alarming)
- **Phase P5** — email channel (3 children: `.eml` ingestion handler, IMAP polling routine + `mailboxes.json`, thread reconstruction + filter→case-attach)
- **Phase P6** — AI comms agent (2 children: `aidevops case draft` human-gated, `aidevops case chase` template-only auto-send)

Total: **20 children**.

### Future planes and crosscutting parents (separate parents — NOT in this MVP)

These planes and crosscutting concerns are part of the long-term architecture but file separately so MVP scope ships first:

- `_campaigns/` — marketing/ads/outreach work (brand assets, competitive intel, swipe files, in-flight creative, post-launch performance + learnings). Filed as **t2870** (peer parent-task). Decomposed into 6 future phases (directory contract, CLI, sensitivity tier, asset binary integration, AI creative agent, performance integration). Children file post-MVP-exit.
- **Structured tag format (Markdoc-style)** — crosscutting content format peer parent. Filed as **t2874**. Defines tag namespace + schema validator + extractor + migration tooling for inline semantic tags (`{% sensitivity %}`, `{% citation %}`, `{% case-attach %}`, `{% provenance %}`, etc.) across all planes. P1a (t2849) ships forward-compat tag emission in a draft namespace; P1c (t2850) ships forward-compat metadata-lift on the tree. Phase 4 of t2874 migrates `meta.json + text.txt` → `source.md + slim meta.json`. 7 future phases (schema, validator, extractor, migration, PageIndex consumer, retrieval consumer, tooling). Children file post-MVP-exit + after t2849/t2850 are merged so producer-consumer pair exists.
- `_performance/` — KPI tracking, metrics, dashboards. Future parent-task.
- `_feedback/` — raw user-feedback corpus + capability-gap mining. Future parent-task.
- `_projects/` — active project work (peer to `_cases/` but proactive not reactive). Future parent-task.
- `_contacts-index/`, `_accounts-index/` — adapter planes referencing external systems of record. Future parent-tasks.

## How (Approach)

### Architecture summary

| Plane | Storage | When data enters git |
|---|---|---|
| `_knowledge/` | Inbox (gitignored) → staging (gitignored) → sources (versioned) | After review-gate promotion |
| `_cases/` | Dossier + timeline + sources pointers | All case material (default), or out-of-repo for sensitive/privileged |
| `_config/` | Plane configs, mailbox/KPI definitions, sensitivity policy | All config |

Originals ≥30MB go to `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/` with hash+pointer in `meta.json`. Below 30MB, stored in `_knowledge/sources/<id>/`.

Personal/cross-repo plane: `~/.aidevops/.agent-workspace/knowledge/` (out-of-repo for content that doesn't belong to any single repo or that's still being staged).

### Sensitivity tiers (cross-cutting, not a plane)

| Tier | Examples | Storage | LLM access |
|---|---|---|---|
| `public` | Published docs, public datasets | In-repo | Any LLM |
| `internal` | Internal docs, non-PII business | In-repo (private repos) | Cloud (with vendor DPA) |
| `pii` | Personal data, account numbers, contact details | Encrypted/out-of-repo | Local LLM only OR cloud + redaction |
| `sensitive` | Strategic, commercial-confidential | Out-of-repo / encrypted | Local LLM only |
| `privileged` | Legal advice, attorney-client comms, board strategy | Encrypted, access-controlled | Local LLM only — hard fail otherwise |

Detection runs locally only. Routing layer fails hard if no compliant provider; never silently degrades.

### Naming convention

- `.agents/` — framework wiring (hidden, developer-managed)
- `_knowledge/`, `_cases/`, etc. — user-data planes (visible, underscore-prefix sorts above regular files)
- `_config/` — plane configs (mailboxes, KPIs, sensitivity policy)

### Repo provisioning

`repos.json` gains:

```jsonc
{
  "knowledge":   "off | repo | personal",
  "performance": "off | repo",
  "feedback":    "off | repo | mined-only",
  "cases":       "off | repo",
  "platform":    "github | gitea | gitlab | local"
}
```

`setup.sh` provisions skeletons + `.gitignore` based on values. `aidevops <plane> init` flips a repo from off to repo.

### Trust ladder

| Trust | Source | Behaviour |
|---|---|---|
| `maintainer` | Drops by maintainer in own repo | Auto-promote, audit-log |
| `trusted` | Allowlisted email/bot/sender | Auto-promote with light review prompt |
| `untrusted` | Anyone else | NMR-gated; `sudo aidevops approve issue <N>` to promote |

### Child task index

| Phase | Child task ID | Title |
|---|---|---|
| P0 | t2843 / GH#20895 | knowledge plane directory contract + provisioning |
| P0 | t2844 / GH#20896 | knowledge CLI surface (`add`, `list`, `search`) + platform abstraction |
| P0 | t2845 / GH#20897 | knowledge review gate routine + NMR integration |
| P0.5 | t2846 / GH#20899 | sensitivity classification schema + detector helper |
| P0.5 | t2847 / GH#20900 | LLM routing helper + audit log |
| P0.5 | t2848 / GH#20901 | Ollama integration + local LLM substrate (extends ollama-helper.sh) |
| P1 | t2849 / GH#20902 | kind-aware enrichment + structured field extraction (generalises ocr-receipt-helper) |
| P1 | t2850 / GH#20903 | PageIndex tree generation across corpus |
| P2 | t2866 / GH#20930 | `_inbox/` directory contract + per-repo provisioning |
| P2 | t2867 / GH#20931 | inbox capture CLI + watch folder + audit log |
| P2 | t2868 / GH#20932 | inbox triage routine: sensitivity gate → classification → routing |
| P2 | t2869 / GH#20933 | pulse digest of stale inbox items + weekly review surface |
| P4 | t2851 / GH#20904 | case dossier contract + `aidevops case open` |
| P4 | t2852 / GH#20905 | case CLI surface (`attach`, `status`, `close`, `archive`, `list`) |
| P4 | t2853 / GH#20906 | case milestone + deadline alarming routine |
| P5 | t2854 / GH#20908 | `.eml` ingestion handler (knowledge channel for kind=email) |
| P5 | t2855 / GH#20909 | IMAP polling routine + `mailboxes.json` registry |
| P5 | t2856 / GH#20910 | email thread reconstruction + filter→case-attach |
| P6 | t2857 / GH#20911 | `aidevops case draft` agent (RAG, human-gated, provenance) |
| P6 | t2858 / GH#20912 | `aidevops case chase` (template-only auto-send, opt-in per case) |

GH#20898 and GH#20907 in this range are PRs for unrelated bugfixes (t2842 + t2841) that landed during decomposition — they share the issue+PR number space but are not children of this parent.

P2 children (t2866-t2869) added 2026-04-25 — `_inbox/` is foundational for capture velocity. Sensitivity-first triage means P2c blocks on P0.5a + P0.5c. P2a/P2b ship in parallel with P0.

Each child has its own brief at `todo/tasks/<task_id>-brief.md`.

### Files Scope (this parent's planning PR only)

- `todo/tasks/t2840-brief.md`
- `todo/tasks/t<children>-brief.md` (20 child briefs)
- `TODO.md` (parent + 20 children entries)

## Acceptance Criteria

- [ ] All 20 children pre-filed as GitHub issues, each with brief at `todo/tasks/<id>-brief.md`
- [ ] Parent issue body updated with child task IDs
- [ ] TODO.md updated with parent + all 20 children entries (each with `ref:GH#NNN`)
- [ ] Planning PR opened with `For #20892` keyword (NEVER `Resolves`/`Closes`)
- [ ] Child PRs (when implemented later) all use `For #20892` (parent stays open)
- [ ] Final phase child PR uses `Closes #20892`
- [ ] MVP exit criteria (when all 16 children merged):
  - [ ] `aidevops knowledge add <path>` works for a PDF, a URL, an `.eml`
  - [ ] `aidevops case open <slug>` creates a case dossier
  - [ ] `aidevops case draft <case>` produces a draft with provenance footer (human-gated)
  - [ ] `aidevops case chase <case> --template <name>` sends a template-only chaser (opt-in)
  - [ ] Sensitivity classification stamps every source's `meta.json`
  - [ ] LLM routing fails hard if no compliant provider for a tier
  - [ ] Provisioning works in a `local_only: true` repo (no GitHub)
  - [ ] Standard skeleton provisions in any new aidevops-init repo

## Context & Decisions

Key decisions from the design session:

1. **Five planes (not seven)** — `_knowledge/`, `_cases/`, `_projects/`, `_performance/`, `_feedback/`. Email/contacts/accounts are NOT planes — they're channels (email) or adapters (contacts, accounts) over existing helpers.
2. **Underscore-prefix for user-data planes** — visible in Finder, sorts above regular files. Dot-prefix retained only for framework wiring (`.agents/`).
3. **Sensitivity layer is cross-cutting, not a plane** — classification stamped on `meta.json`, LLM routing gated on classification.
4. **Originals ≥30MB stored out-of-repo** — 30MB chosen to align with email attachment limits. Below threshold, in-repo for full audit trail.
5. **awardsapp t357 framework-first** — build the framework primitive in aidevops, then awardsapp t357 becomes a thin SaaS layer over it (post-MVP).
6. **Maintainer drops auto-promote** — NMR only for untrusted sources. Crypto-approved (`sudo aidevops approve issue <N>`) for explicit gate.
7. **Insights promote to `_knowledge/` (with source refs), not just memory** — memory becomes a local cache of the canonical knowledge store, not a parallel system.
8. **Per-repo case IDs** — case-YYYY-NNNN-<slug> scoped to repo. Cross-repo links via `related_cases` field.
9. **Pulse-based deadline alarming** — sub-minute latency on legal deadlines is theatre; pulse polling (5-15min) is sufficient.
10. **Local-only / Gitea support via platform abstraction** — all new CLI surfaces route through a thin platform layer; gh adapter today, gitea/gitlab/local adapters defined but stubbed.
11. **Strategic vs routine comms split** — `aidevops case draft` always human-gated; `aidevops case chase` opt-in per case for template-only auto-send (no LLM at send time, just template substitution with verified data fields).
12. **Cross-case privilege firewall** — `aidevops case draft <case-id>` only sees that case's `sources.toon`. Cross-case search needs explicit `--include-case <other-id>` and is logged.
13. **2-year retention** for raw mined feedback records (seasonal trends); 10-year retention for emails (UK statutory minima for commercial correspondence + investigation windows).
14. **Sensitivity layer is MVP-mandatory** — shipping P4-P6 without it would be a privacy footgun for case work involving privileged communications.

Things explicitly ruled out (non-goals for MVP):

- Auto-transcription pipeline (P1b, post-MVP — manual `.md` drops work without it)
- URL/GH-issue ingestion channels (P2, post-MVP)
- `_performance/` and `_feedback/` planes (P2.5, P3 — post-MVP)
- `_projects/` plane (P7, post-MVP)
- `_contacts-index/` and `_accounts-index/` adapters (P8, post-MVP)
- `repo_type` system + per-type provisioning (P9, post-MVP)
- Gitea adapter implementation (P9, post-MVP — abstraction layer in MVP, gh-only impl in MVP)
- awardsapp t357 SaaS layer (P10, separate parent post-MVP)

## Relevant Files

Existing primitives the children build on:

- `.agents/scripts/ollama-helper.sh` — local LLM management (extend for routing layer in P0.5)
- `.agents/tools/context/pageindex.md` — vectorless tree-RAG (use for index in P1)
- `.agents/tools/document/extraction-schemas/10-classification.md` — extend for broader business/legal/asset taxonomy in P1
- `.agents/scripts/ocr-receipt-helper.sh` — generalise pattern for kind-aware enrichment in P1
- `.agents/scripts/document-extraction-helper.sh` — same
- `.agents/scripts/quickfile-helper.sh` — adapter pattern (P8 post-MVP, but reference for design)
- `.agents/scripts/contacts-helper.sh` — adapter pattern (P8 post-MVP, but reference for design)
- `.agents/configs/email-providers.json.txt` — extend with `mailboxes.json` registry in P5
- `.agents/configs/email-sieve-config.json.txt` — extend with case-attach rules in P5
- `.agents/services/accounting/quickfile.md` — reference for adapter design
- `.agents/services/crm/fluentcrm.md` — reference for adapter design
- `.agents/scripts/memory-helper.sh` — promotion target for distilled feedback insights (P3, post-MVP)
- `.agents/scripts/pulse-simplification.sh` — pattern for hash-based change detection routine
- `.agents/scripts/pulse-wrapper.sh` — alarming routine integration point (P4)

## Dependencies

- **Blocked by:** none — independent foundational work
- **Blocks:** post-MVP phases (P1b, P2, P2.5, P3, P7, P8, P9, P10) all depend on MVP exit
- **External:** Ollama installation for local LLM substrate (P0.5); existing IMAP credentials for any test mailbox (P5)

## Estimate Breakdown

| Phase | Estimate | Notes |
|---|---|---|
| Parent decomposition (this PR) | ~2h | Briefs + TODO entries + planning PR |
| P0 — knowledge plane skeleton | ~3 days | 3 children, mostly mechanical |
| P0.5 — sensitivity + LLM routing | ~4 days | 3 children, careful design needed |
| P1 — kind-aware enrich + index | ~3 days | 2 children, builds on existing extractors |
| P4 — cases plane | ~4 days | 3 children, new domain |
| P5 — email channel | ~5 days | 3 children, IMAP loop is non-trivial |
| P6 — comms agent | ~3 days | 2 children, builds on prior planes |
| **Total MVP** | **~3-4 weeks** | Single-driver effort |

Post-MVP arc (P1b through P10) is roughly equivalent total scope, filed as separate parent issue after MVP exit.

## PR Convention

This is a `parent-task` issue. Per t2046, all child PRs use `For #20892` (parent stays open until all 16 children merge). The final phase child PR uses `Closes #20892`. The planning PR for THIS parent (which adds the 16 child briefs + TODO entries) uses `For #20892`.

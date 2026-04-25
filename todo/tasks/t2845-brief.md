---
mode: subagent
---

# t2845: knowledge review gate routine + NMR integration

## Pre-flight

- [x] Memory recall: `nmr review gate maintainer approval` → existing `pulse-nmr-approval.sh` and `sudo aidevops approve issue` flow
- [x] Discovery: `pulse-nmr-approval.sh` and `auto_approve_maintainer_issues` recently iterated; current behaviour stable
- [x] File refs verified: `.agents/scripts/pulse-nmr-approval.sh`, `.agents/scripts/pulse-wrapper.sh` (routine integration point), `prompts/build.txt` § "Crypto-approval"
- [x] Tier: `tier:standard` — extends existing NMR pattern; mechanical promotion logic + routine wiring

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0 (knowledge plane skeleton)

## What

The lifecycle stage gate: `inbox → staging → sources` requires per-source review unless source is auto-promoted (maintainer drop or trusted source). This task ships the **review gate routine** that runs on the pulse loop, classifies inbox items by trust ladder, auto-promotes maintainer/trusted drops, and files NMR-gated GitHub issues for untrusted sources. The crypto-approval flow (`sudo aidevops approve issue <N>`) promotes from staging to sources.

**Concrete deliverables:**

1. `knowledge-review-helper.sh tick` — pulse-driven routine: scan inbox, classify trust, auto-promote or NMR-file
2. Trust ladder definition in `_config/knowledge.json` (`trusted_emails`, `trusted_bots`, `auto_promote_paths`)
3. NMR issue body template: includes source meta + sha + a side-by-side preview link
4. Auto-promotion path: maintainer drops bypass NMR, audit-logged
5. Crypto-approval hook: extend `aidevops approve issue <N>` to recognise knowledge-review issues and promote staging → sources atomically (move dir + update meta.json `state` field)
6. Pulse routine entry in `TODO.md` `## Routines` (e.g. `r040`) with `repeat: cron(*/15 * * * *)` and `run: scripts/knowledge-review-helper.sh tick`

## Why

Without a review gate, untrusted content lands directly in versioned `_knowledge/sources/` — no audit trail, no opportunity to redact PII or reject malicious payloads. The trust ladder lets self-drops and trusted sources flow without friction (95% of cases), while still gating untrusted submissions through the existing NMR + crypto-approval infrastructure (no new approval primitives — reuses what's already battle-tested).

Inbox content is gitignored; staging content is gitignored too. Only after promotion does anything enter git. This is privacy-by-default: even a momentary gitignore misconfig won't leak inbox content.

## How (Approach)

1. **Trust ladder spec** — in `_config/knowledge.json`:
   ```json
   {
     "trust": {
       "auto_promote": { "from_paths": ["~/Drops/maintainer-knowledge/"], "from_emails": ["maintainer@example.com"], "from_bots": ["my-internal-bot"] },
       "review_gate":  { "from_emails": ["partner@example.com"] },
       "untrusted":    "*"
     }
   }
   ```
2. **Review helper** — new `scripts/knowledge-review-helper.sh`:
   - `tick` subcommand: scan `_knowledge/inbox/*/meta.json`, for each:
     - Read `trust` field (set by adder per source); if `maintainer` or `trusted` → auto-promote (move to `staging/` then to `sources/`, log audit)
     - If `untrusted` → file GH issue with NMR label, move to `staging/`
   - `promote <source-id>` subcommand: explicit promotion (used by approve hook)
   - `audit-log <action> <source-id>` — append to `_knowledge/index/audit.log` (JSONL)
3. **NMR issue body template** — embed source kind, sha256, size, ingested_by, and a snippet of extracted text (first 500 chars) so reviewer can decide without leaving GitHub
4. **Crypto-approval hook** — extend `sudo aidevops approve issue <N>` (or its dispatch path in `pulse-nmr-approval.sh`) to detect knowledge-review issues (label `kind:knowledge-review`) and call `knowledge-review-helper.sh promote <source-id>` after approval
5. **Pulse integration** — append routine to `TODO.md` Routines section; pulse picks it up on next cycle. Verify with `routine-helper.sh dry-run r040`
6. **Tests** — covers auto-promotion path, NMR-file path, crypto-approval promotion, audit log correctness, idempotent tick (re-run doesn't double-process)

### Files Scope

- NEW: `.agents/scripts/knowledge-review-helper.sh`
- NEW: `.agents/templates/knowledge-review-nmr-body.md`
- EDIT: `.agents/scripts/pulse-nmr-approval.sh` (add knowledge-review detection in `auto_approve_maintainer_issues` or sibling hook)
- EDIT: `.agents/templates/knowledge-config.json` (add `trust` defaults)
- EDIT: `TODO.md` (add `r040` routine entry — done in this task's PR)
- NEW: `.agents/tests/test-knowledge-review.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (review gate section)

## Acceptance Criteria

- [ ] Maintainer drop in `_knowledge/inbox/` auto-promotes to `_knowledge/sources/` on next pulse tick (audit-logged)
- [ ] Trusted-email drop creates a `kind:knowledge-review` issue with `auto-dispatch` label (light review prompt)
- [ ] Untrusted drop creates `kind:knowledge-review` issue with `needs-maintainer-review` label
- [ ] `sudo aidevops approve issue <N>` on a knowledge-review issue: removes NMR, promotes source to `sources/`, closes issue with summary comment
- [ ] Audit log at `_knowledge/index/audit.log` (JSONL) records every promotion + decision with timestamp + actor
- [ ] Routine `r040` runs every 15 min on the pulse, idempotent (re-runs do not duplicate work)
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-knowledge-review.sh`
- [ ] Documentation: review gate diagram + trust ladder in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2842 (directory contract + meta.json schema), t2843 (CLI surface for knowledge add)
- **Blocks:** P4 cases plane (case attaches reference promoted sources only)
- **Soft-blocks:** P5 email channel (reuses review gate for IMAP-fetched content)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Trust ladder"
- Pattern to follow: `.agents/scripts/pulse-nmr-approval.sh` § `auto_approve_maintainer_issues` (existing crypto-approval flow)
- Approval flow doc: `prompts/build.txt` § "Cryptographic issue/PR approval"
- Routine pattern: existing routines in `TODO.md` `## Routines` and `.agents/reference/routines.md`

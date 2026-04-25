---
mode: subagent
---

# t2856: email thread reconstruction + filter→case-attach

## Pre-flight

- [x] Memory recall: `email thread reconstruction in-reply-to references` → no relevant lessons
- [x] Discovery: existing sieve config at `.agents/configs/email-sieve-config.json.txt`; thread semantics standard (RFC 5322 + JWZ algorithm)
- [x] File refs verified: parent brief; `email-ingest-helper.sh` from t2854; `case-helper.sh` from t2851/t2852
- [x] Tier: `tier:standard` — JWZ-style reconstruction is well-trodden; sieve filter rules already a standard format

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P5 (email channel)

## What

Two related capabilities that together close the email→cases loop:

1. **Thread reconstruction** — given the corpus of email sources, build a thread index using `In-Reply-To`, `References`, and subject heuristics (JWZ algorithm). Each thread becomes a queryable entity at `_knowledge/index/email-threads/<thread-id>.json` listing constituent source IDs in chronological order
2. **Filter → case-attach** — sieve-style rules in `_config/email-filters.json` that match incoming emails (post-ingestion) against rules; matching emails get attached to the configured case via `case-helper.sh attach` automatically. Audit-logged.

**Concrete deliverables:**

1. `scripts/email-thread-helper.sh build` — JWZ-style thread reconstruction over all email sources
2. `scripts/email-thread-helper.sh thread <message-id>` — returns thread ID + ordered constituent source IDs
3. `scripts/email-filter-helper.sh tick` — pulse-driven routine: scan recently-promoted email sources, match against filter rules, auto-attach to cases
4. `_config/email-filters.json` — sieve-style ruleset: `from`, `subject_contains`, `body_matches`, → `attach_to_case: <case-id>`, `set_role: evidence|reference`, `set_sensitivity: <tier>`
5. Routine `r045` in `TODO.md`, repeat: `cron(*/15 * * * *)`, run: `scripts/email-filter-helper.sh tick`
6. Audit log at `_cases/<case-id>/comms/email-attach.jsonl` per case
7. CLI: `aidevops email thread <message-id>`, `aidevops email filter add|list|test`

## Why

Without thread reconstruction, an email corpus is a flat list of disconnected messages — useless for case work where the conversation arc matters. JWZ-style threading is the de-facto standard (used by Thunderbird, Gmail, etc.) and works on `In-Reply-To` + `References` + subject normalisation.

Filter-based auto-attach is the productivity killer: a maintainer can configure "any email from `dispute-counsel@example.com` mentioning case slug XYZ → attach to case XYZ as evidence" and never manually attach again. Without filters, every incoming email needs human triage; with them, only the unmatched residue does.

The sieve-style ruleset format is familiar to anyone who's used Procmail/Sieve/Gmail filters; reusing the mental model lowers learning cost.

## How (Approach)

1. **Thread reconstruction** — `email_thread.py`:
   - For each email source, read `meta.json` for `message_id`, `in_reply_to`, `references`
   - Build threads via JWZ: parent-link from `in_reply_to`, fall back to last `references` entry; subject-merge for orphans (normalise: strip `Re:`, `Fwd:`, lowercase, trim)
   - Each thread gets `_knowledge/index/email-threads/<thread-id>.json`: `{thread_id, root_subject, participants, sources: [{source_id, message_id, date, from}, …]}`
   - Re-runs are incremental: re-thread only sources whose meta changed since last build (via mtime)
2. **Filter ruleset** — `_config/email-filters.json`:
   ```json
   {
     "rules": [
       {
         "name": "Dispute counsel correspondence",
         "match": {
           "from_contains": "dispute-counsel@example.com",
           "subject_contains_any": ["Re: Dispute"]
         },
         "actions": [
           { "attach_to_case": "case-2026-0001-dispute-acme", "role": "evidence" },
           { "set_sensitivity": "privileged" }
         ]
       }
     ]
   }
   ```
3. **Filter helper** — `scripts/email-filter-helper.sh`:
   - `tick`: list email sources promoted since last filter run; for each, evaluate rules; on match, run actions (call `case-helper.sh attach`, optionally `sensitivity-detector-helper.sh override`); audit-log per case
   - `add` — interactive add of new filter rule
   - `test <rule-name>`: against last 50 email sources, show what would match without actions firing
   - `list`: show all rules with hit counts
4. **Filter state** — `_knowledge/.email-filter-state.json` records last-processed source ID per filter run (no double-processing)
5. **Routine `r045`** — pulse picks up; lock-protected; idempotent
6. **Match semantics** — start simple: `from_contains`, `from_equals`, `subject_contains_any`, `subject_matches_regex`, `body_contains`, `has_attachment_kind: <doc-type>`. Combine with `AND` semantics (all conditions must match). Negation operators come post-MVP.
7. **Tests** — covers thread reconstruction (orphan, root, multiple branches), filter match (each predicate kind), filter actions (attach, sensitivity override), no-double-process, filter `test` dry-run mode

### Files Scope

- NEW: `.agents/scripts/email_thread.py`
- NEW: `.agents/scripts/email-thread-helper.sh`
- NEW: `.agents/scripts/email-filter-helper.sh`
- NEW: `.agents/templates/email-filters-config.json` (default `_config/email-filters.json`)
- EDIT: `.agents/cli/aidevops` (add `email thread` and `email filter` subcommand groups)
- EDIT: `TODO.md` (add `r045` routine entry — done in this task's PR)
- NEW: `.agents/tests/test-email-thread.sh`
- NEW: `.agents/tests/test-email-filter.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (threading + filtering section)

## Acceptance Criteria

- [ ] `email-thread-helper.sh build` reconstructs threads across email corpus and writes `_knowledge/index/email-threads/<id>.json`
- [ ] `aidevops email thread <message-id>` returns thread ID + chronological source list
- [ ] Orphan emails (no `In-Reply-To`/`References`, unique subject) get their own single-source thread
- [ ] Subject-merged threading: emails with `Subject: Foo` and `Re: Foo` link as same thread when no `In-Reply-To`
- [ ] Email matching `from_contains: "counsel@..."` rule auto-attaches to configured case via `case-helper.sh attach`
- [ ] Auto-attach records audit log at `_cases/<case>/comms/email-attach.jsonl`
- [ ] Filter `test <rule-name>` shows would-match without firing actions
- [ ] Re-running filter `tick` does not double-process the same source (state-protected)
- [ ] Filter rule with `set_sensitivity: privileged` overrides detector output for matched emails
- [ ] Routine `r045` runs every 15 min, lock-protected, idempotent
- [ ] ShellCheck zero violations; Python `py_compile` passes
- [ ] Tests pass: `bash .agents/tests/test-email-thread.sh && bash .agents/tests/test-email-filter.sh`
- [ ] Documentation: thread + filter sections in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2854 (P5a — email sources must exist with meta), t2855 (P5b — IMAP polling provides volume to test threading), t2851 (P4a — case dossier contract for `attach`), t2852 (P4b — `case-helper.sh attach` subcommand)
- **Blocks:** P6 (comms agent reads threads as RAG context, draft replies in context of thread)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Email channel"
- JWZ thread algorithm: Jamie Zawinski's spec — well-known, public-domain
- Sieve filter syntax inspiration: existing `.agents/configs/email-sieve-config.json.txt` (ManageSieve config)

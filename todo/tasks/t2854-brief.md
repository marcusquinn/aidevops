---
mode: subagent
---

# t2854: `.eml` ingestion handler (kind=email)

## Pre-flight

- [x] Memory recall: `.eml ingest mime parser email` → no relevant lessons
- [x] Discovery: existing email infrastructure at `.agents/configs/email-providers.json.txt` (15 providers, IMAP/SMTP/JMAP)
- [x] File refs verified: parent brief; `python3 -c "import email"` available stdlib
- [x] Tier: `tier:standard` — `.eml` is RFC 5322; mature parsers exist; `kind=email` is just another knowledge ingestion path

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P5 (email channel)

## What

`.eml` ingestion as a first-class knowledge channel. When a `.eml` file lands in `_knowledge/inbox/`, the ingestion helper detects `kind=email`, parses headers + body + attachments, writes structured `meta.json` with email-specific fields, and stores attachments as separate sources linked to the parent email source.

**Concrete deliverables:**

1. `scripts/email-ingest-helper.sh ingest <eml-path>` — parses `.eml`, creates source(s), populates meta with email fields
2. Email-specific meta fields: `kind: email, from, to, cc, bcc, date, message_id, in_reply_to, references, subject, body_text_sha, body_html_sha, attachments: [{source_id, filename}]`
3. Attachments split into separate `_knowledge/sources/<attachment-id>/` with `parent_source: <email-id>` linkage
4. Body sanitisation: strip tracking pixels, strip remote images on storage (privacy + reproducibility)
5. Plain-text body extracted to `text.txt`, HTML body preserved at `body.html` for fidelity
6. `aidevops knowledge add` (from t2843) auto-detects `.eml` extension and routes through this helper

## Why

Email is high-volume, high-signal, and structurally rich (headers, threading, attachments). Treating it as just another file would lose the threading semantics needed for case-attach (P5c) and the comms agent (P6).

Splitting attachments into separate sources lets each be sensitivity-classified independently — a benign email with a privileged contract attachment is the common case, and the contract should land at `tier:privileged` even if the email body is `tier:internal`.

Stripping tracking pixels/remote images on store is privacy hygiene: stored emails should not phone home if a future re-render happens, and tracking artefacts skew any analytics built on the corpus.

## How (Approach)

1. **Parser** — Python script `scripts/email_parse.py` using stdlib `email` module:
   - Read `.eml`, extract headers (use `email.policy.default` for proper Unicode)
   - Body parts: prefer text/plain; if HTML-only, extract text via `html2text` (vendor minimal version) or `python -c "from html.parser import HTMLParser"` strip
   - Attachments: walk parts, identify `Content-Disposition: attachment` and inline-but-named parts; write each to a temp dir
   - Output JSON to stdout: `{from, to, cc, ..., body_text_path, body_html_path, attachments: [{filename, content_path, content_type, size}]}`
2. **Ingest helper** — `scripts/email-ingest-helper.sh`:
   - `ingest <eml-path>`:
     - Call `email_parse.py` to JSON
     - Allocate parent source ID via the same scheme as `knowledge-helper.sh add`
     - Sanitise body (strip tracking pixels: replace `<img src="*://*"/>` with `<!-- tracker stripped: $url -->`; strip Beacon/UTM tracking links)
     - Write parent source: `text.txt` from body, `body.html` (sanitised), `meta.json` with email fields + sensitivity placeholder
     - For each attachment: allocate child source ID, write attachment file under `_knowledge/sources/<child-id>/`, populate child's `meta.json` with `parent_source: <parent-id>` and `attachment_filename`
     - Run sensitivity detector (t2846) on body and each attachment independently
3. **Auto-detection in `knowledge add`** — extend t2843's `add` to detect `.eml` extension; route through `email-ingest-helper.sh ingest`
4. **MIME edge cases**:
   - `multipart/alternative` (text + html): take both, prefer text for `text.txt`
   - `multipart/related` (HTML + inline images): treat inline images as attachments OR strip if from external CIDs
   - Apple Mail `.emlx`: strip Apple-prepended length header before parsing
   - Encoding: handle quoted-printable, base64, 8bit; punt on non-UTF-8 with warning + raw-bytes preserved
5. **Tests** — covers plaintext-only, html-only, mixed, with attachments, with PDF attachment that triggers downstream PDF extraction (cross-helper integration), tracking pixel removal, sanitisation idempotency

### Files Scope

- NEW: `.agents/scripts/email_parse.py`
- NEW: `.agents/scripts/email-ingest-helper.sh`
- EDIT: `.agents/scripts/knowledge-helper.sh` (route `.eml` through email handler in `add`)
- NEW: `.agents/tests/test-email-ingest.sh`
- NEW: `.agents/tests/fixtures/sample-emails/` (3-4 test `.eml` files: plaintext, html, with-attachments, with-tracking-pixel)
- EDIT: `.agents/aidevops/knowledge-plane.md` (email kind section)

## Acceptance Criteria

- [ ] `aidevops knowledge add /path/to/email.eml` creates a parent source with `kind=email` and full email-specific meta
- [ ] Email with 3 attachments creates 1 parent source + 3 child sources, each linked via `parent_source`
- [ ] HTML body preserved at `body.html`; plain-text version at `text.txt`
- [ ] Tracking pixel `<img src="https://tracker.example.com/pixel.gif"/>` is stripped from stored `body.html`
- [ ] UTF-8 subjects with non-ASCII characters parse correctly (e.g., emoji, diacritics)
- [ ] Quoted-printable and base64-encoded bodies decode correctly
- [ ] PDF attachment triggers downstream extraction via `document-extraction-helper.sh`
- [ ] Each child (attachment) source independently classified by sensitivity detector
- [ ] `.emlx` files (Apple Mail format) parse correctly after length-header stripping
- [ ] ShellCheck zero violations on new helpers; `python3 -m py_compile` passes on `email_parse.py`
- [ ] Tests pass: `bash .agents/tests/test-email-ingest.sh`
- [ ] Documentation: email kind section in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2844 (P0a — directory contract for child-source linkage), t2843 (P0b — `add` CLI), t2849 (P1a — kind-aware enrichment for body content)
- **Soft-blocked by:** t2846 (P0.5a — sensitivity detector to classify body + attachments)
- **Blocks:** t2855 (P5b IMAP routine drops `.eml` files for ingestion), t2856 (P5c thread reconstruction reads email meta)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Email channel"
- Existing email infrastructure: `.agents/configs/email-providers.json.txt`, `.agents/configs/email-sieve-config.json.txt`
- Stdlib parser: Python `email` module with `policy=default`
- Sanitisation pattern: minimal regex/HTML-strip; full-fidelity sanitisation (e.g. DOMPurify) is out of scope for MVP

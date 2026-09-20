---
description: Jev classification, SEO, browser selection and bounded continuation recipes
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Structured-decision recipes

<!-- AI-CONTEXT-START -->

Read [Jev setup and privacy](jev.md) before provider use. These recipes are
advisory: no default provider routing, browser execution or runtime hooks change.
Prefer exact code first, narrow semantic decisions second, and the existing
approved LLM for generation or unresolved reasoning. Escalation never broadens
data permissions. Report unresolved results rather than forcing a classification.

<!-- AI-CONTEXT-END -->

## Directory ingestion and retrieval

Use API/feed/static fetch before browsers. Parse schema.org/JSON-LD, headings and
candidate spans in code; give Jev a small candidate list with stable IDs. Choose
the relevant phone, address, service category or page type without inventing new
field values. Retain verbatim evidence, source URL, retrieval date and whether a
field is observed or inferred. Validate field formats and database constraints.
Use embeddings/BM25 to shortlist duplicate candidates before pair classification;
do not compare every record with every other record. Ambiguous matches go to review,
not automatic destructive merges. Preserve source rights and collection permissions.

For media, OCR/caption/transcribe first with an approved model; Jev itself is
text-only. Avoid forwarding credentials, signed asset URLs or private media metadata.

## SEO and content

Combine first-party search evidence and authorised competitor retrieval with
deterministic term/heading counts, embeddings and generative drafting. Jev can
classify search intent, assess passage relevance, flag unsupported claims and
rank internal-link candidates. It cannot count terms reliably or establish future
rankings, authority, factual credibility or citation likelihood by a score alone.
Retain citations and editorial review. Treat NeuronWriter as a complementary
baseline, not an assumed replacement; see [NeuronWriter](../../seo/neuronwriter.md).
Evaluate accepted output and review burden, not just minimum inference tokens.

## Browser and GitHub efficiency

Use a compact observed DOM/accessibility candidate table; allow only observed IDs
and approved operations, then revalidate stale nodes, action compatibility and
postconditions. Keep CDP local and use isolated browser contexts. Never expose a
normal signed-in profile or execute generated selectors/JavaScript. Use a browser
only when simpler collection fails; no browser adapter is shipped here.

For GitHub, semantic issue/review triage and candidate ranking can be optional.
Keep query shaping, freshness, rate-limit arithmetic, deduplication and permission
checks in existing tooling. Read [GitHub transport](../../reference/github-api-transport.md).
Never replace trusted-author checks, required CI evidence or merge approval with a
model score. Missing Jev access leaves the established LLM workflow unchanged.

## Continuation prompting (example, not installed)

Use Jev only to advise whether another nudge could advance an existing authorised
objective. Send a minimal approved objective/checklist/blocker summary, not a full
session. Keep model output separate from trusted runtime facts. The example's
`ContinuationBudget` demonstrates the deterministic enforcement boundary:

- Opt-in, one owner, at most **12** nudges over the entire objective; callers may
  lower the cap but cannot raise it. Count before issuing each nudge.
- Completed, cancelled, awaiting permission, awaiting information, waiting for an
  external event, or still choosing a direction means stop regardless of model score.
- A repeated verified progress token means stop. A changed promise is not progress;
  the host must derive the token from actual accepted work/evidence.
- Unknown or malformed evidence fails closed. Abstention does not consume a nudge.
- No automatic reset on retry, process restart, model fallback or new user message.
  A future host adapter must persist the objective-bound counter atomically, serialize
  concurrent decisions and recheck stop/permission state immediately before dispatch.
  The in-memory example is **not** restart-safe and must not be wired into a hook.
- Cancellation, permission and budget stops cannot be overturned by LLM fallback.
  Reaching the cap preserves a checkpoint and returns control; it is not completion.

No automatic continuation is enabled by running the CLI: its continuation payload
is synthetic, and even a positive answer only prints a decision. Tests exercise
the cap and early stops without running agents. Compaction, transcript pruning and
retention selection are explicitly out of scope.

## Other domains and evaluation

Accounting: suggest categories/matches; amounts, tax rules and posting authority
stay outside the model. Legal: rank source passages or clause categories, not legal
outcomes; preserve privilege and qualified review. Creativity: rank candidates
against a brief while preserving diversity; randomness belongs in code. UX:
classify feedback and shortlist variants, then verify accessibility and behaviour.

For any pilot, use a representative independently labelled holdout including
ambiguous, multilingual and irrelevant examples. Measure false acceptance,
abstention/coverage, calibration, end-to-end cost, latency and human repair time.
Synthetic smoke examples verify wiring only, not production accuracy. Thresholds
in example code are illustrative and must not be reused across primitives or
domains without validation. Do not use Jev outputs as training labels for a clone.

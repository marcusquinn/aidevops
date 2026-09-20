---
description: Opt-in reversible retrieval and shadow issue/review triage with private Jev evaluations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Jev workflow-efficiency pilots

<!-- AI-CONTEXT-START -->

These are opt-in exploration commands, not automatic hooks. Read [Jev](jev.md)
for service/privacy terms. Start offline with the bundled synthetic fixtures.
Never send sessions, credentials, private repository content, personal data or
privileged material. Retain original evidence and preserve the existing authorised
LLM route. Suggestions cannot grant authority, modify GitHub, dispatch work or
decide that a task is complete. No compaction or continuation hooks are installed.

<!-- AI-CONTEXT-END -->

## Quick start

After installing the release, run:

```bash
python3 ~/.aidevops/agents/scripts/jev-pilot.py retrieval
python3 ~/.aidevops/agents/scripts/jev-pilot.py triage
```

These commands do not read a key or make a network request. They exercise the
local baseline and write an owner-only report. To test the same synthetic data:

```bash
aidevops secret TYPESAFE_API_KEY -- python3 ~/.aidevops/agents/scripts/jev-pilot.py retrieval --live
aidevops secret TYPESAFE_API_KEY -- python3 ~/.aidevops/agents/scripts/jev-pilot.py triage --live
```

For an account-suffixed secret, change the injected name and add
`--key-env TYPESAFE_API_KEY_WORK` (substitute your own suffix). Key values never
belong in argv, chat or fixtures. Each live command makes at most one fixed-endpoint
request, with no automatic retry, redirected credential or secondary provider.
The pinned model and strict response validator are reused from `jev-example.py`.

## Custom public corpus

Prepare a UTF-8 JSON file locally; the CLI does not fetch URLs or scrape GitHub:

```json
{
  "mode": "retrieval",
  "data_classification": "public_non_personal",
  "query": "How should an API key be stored?",
  "items": [
    {
      "id": "doc-1",
      "text": "Use a secret manager; do not commit API keys.",
      "label": "relevant"
    },
    {"id": "doc-2", "text": "Garden planting guide.", "label": "irrelevant"}
  ]
}
```

Supported limits: 1–12 unique opaque IDs, 4,000 characters per text, 1,000 for the
query, and 24,000 bytes for both the input file and its JSON serialization. Unknown
fields fail closed. Human `label` values are optional and are **never sent to Jev**;
do not derive evaluation labels from Jev itself. Keep a separate private mapping
from IDs to immutable source references/spans. Neither source paths nor IDs are
sent to the provider; only the query, texts and authored questions are sent.

```bash
python3 ~/.aidevops/agents/scripts/jev-pilot.py retrieval --input corpus.json
aidevops secret TYPESAFE_API_KEY -- python3 ~/.aidevops/agents/scripts/jev-pilot.py retrieval --input corpus.json --live --allow-public-data
```

`--allow-public-data` is required for a custom live upload in addition to the
classification. This is the operator's assertion, **not an automatic PII detector**.
Public pages can contain personal data; review and minimise them before upload.
The local prompt-guard pattern scanner must also pass. Missing scanner, timeout or
a flagged scan blocks the request; scan success is not proof of privacy or injection
immunity. No flag bypasses a blocked scan. Keep original material for the host to
inspect under its normal trust rules instead of trying to force a model decision.

## Reversible retrieval

The report contains all IDs in original order, selected IDs ranked by relevance,
deferred IDs, and fallback IDs. Only a validated `irrelevant` Choice at confidence
at least 0.9 is deferred. Unknown/low-confidence items remain available in the
selection. An empty selection restores everything. Missing key, bad schema/model,
rate limit or transport failure retains everything. These are illustrative
thresholds, not measured calibration guarantees.

The input file is never modified. To expand back to the complete set without any
provider access (even if `--live` is also present):

```bash
python3 ~/.aidevops/agents/scripts/jev-pilot.py retrieval --input corpus.json --unfiltered
```

Before consuming a report, match its `corpus_sha256` to the same canonical JSON
(`json.dumps(corpus, sort_keys=True)` encoded as UTF-8). Resolve IDs only against
that corpus. Treat a mismatch as unfiltered fallback, not a selection for new text.
Any answering agent must expand to originals when evidence is insufficient; never
delete deferred content or use the filter as a security boundary.

## Shadow triage

Use `"mode": "triage"` and human labels `defect`, `enhancement`, `question` or
`unknown`. Supply public issue/review excerpts without identities or unnecessary
metadata. The report suggests categories; it always retains all records and never
applies labels, closes issues, dispatches workers, posts comments or changes trust
checks. Compare against accepted human outcomes before considering integration.

## Private evaluation

Reports are new UUID-named files under
`~/.aidevops/.agent-workspace/work/jev-pilots/`, outside Git, with directory mode
700 and file mode 600. Existing files are not overwritten; symlink paths and Git
checkouts are rejected using no-follow directory descriptors. This storage path
supports macOS/Linux (POSIX); other platforms fail closed before inference.
IDs and corpus hashes are also private: hashes can confirm guesses about input.
The CLI prints only status, fallback indication and the
report path, not source text, decisions or performance results. Do not paste reports
into public PRs, transcripts or benchmarks. Retain locally only as long as needed;
delete them through your normal approved local-data lifecycle. See the dated
[commercial restrictions](../../reference/jev-research.md).

Each report records model/rubric versions, corpus hash, a stable lexical-overlap
ranking baseline (or a deliberately simple keyword triage baseline), fallback
coverage, labelled errors, relevant evidence deferred, top-three relevance counts,
original/selected character counts, request bytes, local/provider/total elapsed
time and input-token usage when provided. Timings cover the pilot core only, not
input loading, scanning, secret injection, report storage or the host LLM. Measure
the enclosing workflow separately for a true end-to-end comparison.
The baseline is not the current production
LLM's quality or cost. Compare paired runs on the same corpus and annotate manual
repair time and accepted final outcomes locally. LLM tokens saved, total dollar
cost, human repair time and final task quality are explicitly **unknown**, not zero,
until measured in an actual host workflow. No efficiency improvement is claimed
from the bundled synthetic smoke tests.

### Manual outcome journal

`jev-evaluation.py` is a separate, offline-only journal for a small held-out
evaluation of retrieval or shadow triage against the actual existing workflow.
It observes nothing between explicit invocations: it does not read sessions,
repositories, GitHub, or provider credentials, and it makes no network request.
Use opaque task IDs rather than task text, paths, identities, or source material.

Create a local JSON file with an operator-reviewed outcome and explicit units.
`null` means unknown, never zero. `accepted_outcome` and
`label_provenance` distinguish accepted work, synthetic cases, and unreviewed
labels; AI-authored labels are not human ground truth.

```json
{
  "task_id": "heldout-01",
  "task_category": "retrieval",
  "route": "baseline",
  "accepted_outcome": "accepted",
  "label_provenance": "operator_reviewed",
  "corpus_sha256": "<private corpus hash>",
  "rubric": "<operator rubric version>",
  "model": "<route/model identity>",
  "metrics": {
    "repair_seconds": null,
    "end_to_end_seconds": 120,
    "input_tokens": null,
    "total_cost_usd": null
  },
  "missing_evidence": false,
  "misclassification": false
}
```

```bash
python3 ~/.aidevops/agents/scripts/jev-evaluation.py record --input outcome.json
python3 ~/.aidevops/agents/scripts/jev-evaluation.py status
python3 ~/.aidevops/agents/scripts/jev-evaluation.py compare --baseline baseline.json --pilot pilot.json
```

Pass `--pilot-report /path/to/selected-report.json` only to import the corpus,
rubric, and model metadata from one explicitly selected local pilot report. The
journal rejects unknown report schemas, duplicate logical records, unreviewed
labels, unknown accepted outcomes, and mismatched task/corpus/rubric/model pairs
for a value comparison. A compatible comparison reports deltas only and always
states `no_value_claim`: quality, missing evidence, and repair effort come before
any claimed savings. It never establishes Jev value from offline fixtures.

Records are owner-only files under
`~/.aidevops/.agent-workspace/work/jev-evaluation/`, outside Git. Stop collection
by not invoking the command; there is no hook, daemon, upload, API spend, schedule,
or production integration. Retain or delete records through the approved local-data
lifecycle. Reverting this optional source leaves records untouched. A separately
consented live comparison is required before any provider value claim or public
benchmark; do not publish reports or performance results.

Exit 0: offline/unfiltered report or live results needing no fallback. Exit 2:
blocked input/storage/scan or live results requiring the established LLM path for
some/all items. `fallback_required` does not mean an LLM was invoked. Do not change
provider or data permissions to obtain an answer. Defer production activation
until held-out error rates, discarded evidence, total costs and repair effort
justify it. Existing routing remains the default for users without TypeSafe access.

## Verification

From a source worktree:

```bash
python3 .agents/scripts/tests/test-jev-pilot.py
python3 .agents/scripts/tests/test-jev-example.py
python3 .agents/scripts/tests/test-jev-evaluation.py
```

These offline tests cover reversible selections, abstention, failed/missing access,
label isolation, shadow-only triage, private file permissions, upload consent and
normal CLI operation. No new test infrastructure or automatic telemetry is installed.

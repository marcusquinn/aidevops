---
description: Optional TypeSafe Jev typed decisions, privacy-aware setup and synthetic examples
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

# Jev — TypeSafe structured decisions

<!-- AI-CONTEXT-START -->

- Jev is an optional text-only decision service, not a chat model, browser driver,
  authority checker or replacement for the host LLM. Missing access must preserve
  the existing approved LLM route. Never silently change provider or data policy.
- Use Choice for one bounded option, Score for ordered descriptive levels, and
  Noul for a yes-probability. Ask atomic questions against minimal relevant state;
  batch independent questions sharing that state. Keep arithmetic in code.
- Operational recipes: [structured decisions](jev-decisions.md). Dated sources,
  commercial terms and project comparisons: [research](../../reference/jev-research.md).
  Research is optional context, not always-loaded agent instructions.
- Run `python3 ~/.aidevops/agents/scripts/jev-example.py` offline first. Only
  `--live` sends the fixed synthetic example to TypeSafe. It does not read user
  files, sessions, browsers, repositories or arbitrary stdin.
- No compaction integration. Continuation is an example only, not an installed
  runtime hook: at most **12** nudges per objective, with earlier safety stops.

<!-- AI-CONTEXT-END -->

## Setup and readiness

Store a key in an attached terminal, never in chat, source files or command args:

```bash
aidevops secret status
aidevops secret set TYPESAFE_API_KEY
aidevops secret list
```

Prefer encrypted gopass; the credentials-file fallback is plaintext. Multi-account
keys may use a suffix, for example `TYPESAFE_API_KEY_WORK`. The example's
`--key-env TYPESAFE_API_KEY_WORK` selects an injected environment variable; it
does not fetch secrets itself. Inject only that key:

```bash
aidevops secret TYPESAFE_API_KEY -- python3 ~/.aidevops/agents/scripts/jev-example.py --live
```

For a suffixed key, replace the name in both the injection and `--key-env` option.
Do not use `secret get` in an agent-visible terminal. Never infer permission to
send private data from the presence of a key. There is no registered production
Jev route yet: `--live` is the explicitly authorised synthetic smoke path only.
Production activation requires provider/data approval, a readiness contract and
the application's existing authority checks before any payload leaves the device.

## Examples and verification

From a source worktree (or use the deployed scripts directory):

```bash
python3 .agents/scripts/jev-example.py --example directory
python3 .agents/scripts/jev-example.py --example seo
python3 .agents/scripts/jev-example.py --example continuation
python3 .agents/scripts/tests/test-jev-example.py
```

Offline execution prints a synthetic request without looking up a key. Live mode
makes at most one request to the fixed HTTPS TypeSafe endpoint, rejects redirects,
uses a finite timeout and limits response size. No SDK or new dependency is needed.
The model is pinned in the example. The test uses mocked responses, not credentials.

Exit 0 means a dry run or accepted example result. Exit 2 returns
`fallback_required`: missing key, unavailable transport, malformed response,
unknown option, model drift or insufficient certainty. This is a handoff to the
existing authorised LLM, **not** evidence that an LLM fallback ran. Never retry
authentication failures automatically; honour provider cooldowns in a future
production adapter rather than adding immediate retries to the example.

## Data and decision boundaries

Use synthetic or non-personal public material initially. Publicly accessible data
can still be personal or licensed. Client records, financial data, privileged legal
material, credentials and full transcripts are excluded from these examples.
Approve retention, telemetry, subprocessors, cross-border transfers and any ZDR
agreement before sensitive use. A gateway adds another processing boundary.

Typed answers may be wrong. Confidence describes the answer distribution, not a
guarantee of correctness. Explicitly include `unknown`/abstention where appropriate.
Pin model, question and rubric versions when tuning thresholds. Independent
questions are not guaranteed to obey probability identities or to be jointly valid.
Validate action/argument combinations in code; never execute model-supplied code,
selectors, URLs or shell commands.

Do not rely on Jev to establish trust, detect all prompt injection, approve merges,
post transactions or determine task completion. The existing host owns permissions,
evidence, user cancellation and final acceptance. Private validation outcomes must
not be published as benchmarks without resolving the provider's commercial terms.

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoresearch — Logging, Memory & Mailbox

Sub-doc for `autoresearch.md`. Loaded on demand.

## Results Logging

Append to `todo/research/{name}-results.tsv`:

```text
{iteration}\t{commit_sha_or_dash}\t{metric_name}\t{metric_value_or_dash}\t{baseline}\t{delta_or_dash}\t{status}\t{hypothesis}\t{ISO_timestamp}\t{tokens_used}\t{pass_rate_or_dash}\t{token_ratio_or_dash}\t{trials}\t{trial_variance_or_dash}
```

| Column | Type | Notes |
|--------|------|-------|
| `iteration` | int | Sequential (0 = baseline) |
| `commit` | string | Short SHA or `-` for crashes/discards |
| `metric_name` | string | From research program `name:` field |
| `metric_value` | float\|`-` | `-` for crashes/constraint fails; median when TRIALS > 1 |
| `baseline` | float | Original value (same for all rows) |
| `delta` | float\|`-` | `metric_value - baseline` (signed); `-` for crashes |
| `status` | string | `baseline`, `keep`, `discard`, `discard_inconsistent`, `constraint_fail`, `crash` |
| `hypothesis` | string | One line, no tabs |
| `timestamp` | ISO 8601 | UTC |
| `tokens_used` | int | Approximate tokens for this iteration |
| `pass_rate` | float\|`-` | 0–1; agent-optimization only |
| `token_ratio` | float\|`-` | `avg_response_chars / baseline_chars`; agent-optimization only |
| `trials` | int | Number of evaluation trials run (1 if single-shot) |
| `trial_variance` | float\|`-` | `max - min` of trial results; `-` for single trial or crashes |

Example:

```tsv
iteration	commit	metric_name	metric_value	baseline	delta	status	hypothesis	timestamp	tokens_used	pass_rate	token_ratio	trials	trial_variance
0	(baseline)	build_time_s	12.4	12.4	0.0	baseline	(initial measurement)	2026-04-01T10:00:00Z	0	-	-	1	-
1	a1b2c3d	build_time_s	11.1	12.4	-1.3	keep	remove unused lodash import	2026-04-01T10:12:00Z	2340	-	-	1	-
2	-	build_time_s	12.8	12.4	0.4	discard	switch to esbuild (breaks API)	2026-04-01T10:24:00Z	3100	-	-	1	-
3	b3c4d5e	avg_tokens_per_task	85.2	92.0	-6.8	keep	remove redundant constraint examples	2026-04-01T10:36:00Z	4200	0.94	0.92	3	2.1
4	-	avg_tokens_per_task	91.5	92.0	-0.5	discard_inconsistent	merge hints into single bullet	2026-04-01T10:48:00Z	3800	0.93	0.91	3	4.7
```

## Memory Storage

After each **keep** or **discard** (medium confidence):

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME}: {hypothesis[:80]} → {status} ({METRIC_NAME}: {metric_value}, delta={delta:+.2f})" \
  --confidence medium
```

After each **keep**, also store a high-confidence finding:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} FINDING: {hypothesis}. Improved {METRIC_NAME} by {abs(delta):.2f} ({improvement_pct:.1f}%). Commit: {commit_sha}" \
  --confidence high
```

At session end, store a summary (high confidence):

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} session complete: {ITERATION_COUNT} iterations, best {METRIC_NAME}={BEST_METRIC} (baseline={BASELINE}, improvement={improvement_pct:.1f}%), total_tokens={TOTAL_TOKENS}" \
  --confidence high
```

## Mailbox Discovery Integration

Used in multi-dimension campaigns (CAMPAIGN_ID is set). No-ops when CAMPAIGN_ID is absent.

**Before each hypothesis generation** — check peer discoveries:

```bash
mail-helper.sh check --agent "$AGENT_ID" --unread-only
# For each unread: mail-helper.sh read <message-id> --agent "$AGENT_ID"
# Parse payload JSON → add to hypothesis context as PEER_DISCOVERIES
# keep peer → consider applying; discard peer → deprioritize similar approaches
```

**After each keep or discard** — broadcast discovery:

```bash
DISCOVERY_PAYLOAD=$(cat <<EOF
{
  "campaign": "{CAMPAIGN_ID}",
  "dimension": "{DIMENSION}",
  "hypothesis": "{hypothesis}",
  "status": "{keep|discard}",
  "metric_name": "{METRIC_NAME}",
  "metric_before": {BASELINE},
  "metric_after": {metric_value},
  "metric_delta": {delta},
  "files_changed": [{list of files modified}],
  "iteration": {ITERATION_COUNT},
  "commit": "{commit_sha_or_null}"
}
EOF
)
mail-helper.sh send --from "$AGENT_ID" --to "broadcast" --type discovery \
  --payload "$DISCOVERY_PAYLOAD" --convoy "{CAMPAIGN_ID}"
```

**On completion** — deregister:

```bash
mail-helper.sh deregister --agent "$AGENT_ID"
```

# Autoresearch — Logging, Memory & Mailbox

Sub-doc for `autoresearch.md`. Loaded on demand.

---

## Results Logging

Append to `todo/research/{name}-results.tsv`:

```text
{iteration}\t{commit_sha_or_dash}\t{metric_name}\t{metric_value_or_dash}\t{baseline}\t{delta_or_dash}\t{status}\t{hypothesis}\t{ISO_timestamp}\t{tokens_used}
```

Column definitions:

| Column | Type | Notes |
|--------|------|-------|
| `iteration` | int | Sequential experiment number (0 = baseline) |
| `commit` | string | Short SHA or `-` for crashes/discards |
| `metric_name` | string | From research program `name:` field |
| `metric_value` | float or `-` | Measured value; `-` for crashes/constraint fails |
| `baseline` | float | Original baseline value (same for all rows) |
| `delta` | float or `-` | `metric_value - baseline` (signed); `-` for crashes |
| `status` | string | `baseline`, `keep`, `discard`, `constraint_fail`, `crash` |
| `hypothesis` | string | What was tried (one line, no tabs) |
| `timestamp` | ISO 8601 | UTC timestamp |
| `tokens_used` | int | Approximate tokens consumed by this iteration |

Example rows:

```tsv
iteration	commit	metric_name	metric_value	baseline	delta	status	hypothesis	timestamp	tokens_used
0	(baseline)	build_time_s	12.4	12.4	0.0	baseline	(initial measurement)	2026-04-01T10:00:00Z	0
1	a1b2c3d	build_time_s	11.1	12.4	-1.3	keep	remove unused lodash import	2026-04-01T10:12:00Z	2340
2	-	build_time_s	12.8	12.4	0.4	discard	switch to esbuild (breaks API)	2026-04-01T10:24:00Z	3100
3	-	build_time_s	-	12.4	-	crash	double worker threads (OOM)	2026-04-01T10:36:00Z	1800
4	b2c3d4e	build_time_s	10.5	12.4	-1.9	keep	tree-shake utils/ barrel exports	2026-04-01T10:48:00Z	2800
```

---

## Memory Storage

After each **keep** or **discard** iteration:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME}: {hypothesis[:80]} → {status} ({METRIC_NAME}: {metric_value}, delta={delta:+.2f})" \
  --confidence medium
```

After **keep** iterations, also store a higher-confidence finding:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} FINDING: {hypothesis}. Improved {METRIC_NAME} by {abs(delta):.2f} ({improvement_pct:.1f}%). Commit: {commit_sha}" \
  --confidence high
```

At session end, store a summary:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} session complete: {ITERATION_COUNT} iterations, best {METRIC_NAME}={BEST_METRIC} (baseline={BASELINE}, improvement={improvement_pct:.1f}%), total_tokens={TOTAL_TOKENS}" \
  --confidence high
```

---

## Mailbox Discovery Integration

Used in multi-dimension campaigns (CAMPAIGN_ID is set). No-ops when CAMPAIGN_ID is absent.

### Check peer discoveries (before each hypothesis generation)

```bash
mail-helper.sh check --agent "$AGENT_ID" --unread-only
# For each unread discovery message:
#   mail-helper.sh read <message-id> --agent "$AGENT_ID"
#   Parse payload JSON → add to hypothesis context as PEER_DISCOVERIES
```

- If a peer found a `keep` result, consider whether the same change applies to this dimension
- If a peer found a `discard` result, deprioritize similar approaches

### Send discovery (after each keep or discard)

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

mail-helper.sh send \
  --from "$AGENT_ID" \
  --to "broadcast" \
  --type discovery \
  --payload "$DISCOVERY_PAYLOAD" \
  --convoy "{CAMPAIGN_ID}"
```

### Deregister on completion

```bash
mail-helper.sh deregister --agent "$AGENT_ID"
```

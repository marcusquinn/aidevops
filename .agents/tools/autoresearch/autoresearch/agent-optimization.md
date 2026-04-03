# Autoresearch — Agent Optimization Domain

Sub-doc for `autoresearch.md`. Load when `PROGRAM_NAME == "agent-optimization"` or `METRIC_CMD` contains `agent-test-helper.sh`.

---

## Security Instruction Exemptions

Discard any hypothesis that removes or weakens the following — do not test:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

Enforced by both the research program constraint list and the researcher model. Both layers must hold.

---

## Composite Metric Parsing

```bash
METRIC_JSON=$(eval "$METRIC_CMD")
COMPOSITE_SCORE=$(echo "$METRIC_JSON" | jq '.composite_score')
PASS_RATE=$(echo "$METRIC_JSON" | jq '.pass_rate')
TOKEN_RATIO=$(echo "$METRIC_JSON" | jq '.token_ratio')
```

Use `COMPOSITE_SCORE` as the primary metric for keep/discard decisions.
Log `PASS_RATE` and `TOKEN_RATIO` as supplementary columns in results.tsv.

**Formula**: `composite_score = pass_rate * (1 - 0.3 * token_ratio)` (higher = better)

- `pass_rate`: fraction of tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars` — proxy for token usage

---

## Baseline Setup

On first run (`BASELINE == null`), establish baseline before measuring:

```bash
agent-test-helper.sh baseline .agents/tests/agent-optimization.test.json
```

Sets `baseline_chars` for `token_ratio` computation. Without this, `token_ratio` defaults to 1.0.

---

## Simplification State Integration

Before generating hypotheses, skip unchanged files:

```bash
TARGET_FILE=".agents/build-plus.md"
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
STORED_HASH=$(jq -r --arg f "$TARGET_FILE" '.files[$f].hash // empty' \
    .agents/configs/simplification-state.json 2>/dev/null)
[[ "$CURRENT_HASH" == "$STORED_HASH" ]] && log "File unchanged. Skipping."
```

After a successful session (`composite_score` improved vs baseline), update the hash:

```bash
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
jq --arg file "$TARGET_FILE" \
   --arg hash "$CURRENT_HASH" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.files[$file] = ((.files[$file] // {}) + {"hash": $hash, "at": $ts, "pr": null})' \
   .agents/configs/simplification-state.json > /tmp/ss.json && \
   mv /tmp/ss.json .agents/configs/simplification-state.json
```

---

## Agent Optimization Hypothesis Types

| Phase | Hypothesis type | Example |
|-------|----------------|---------|
| 1–5 | Consolidate redundant rules | Merge two similar "Read before Edit" rules into one |
| 6–15 | Remove low-value instructions | Delete rules that don't affect any test outcome |
| 16–25 | Shorten verbose phrasing | Replace 3-sentence rule with 1-sentence equivalent |
| 26–35 | Replace inline code with references | `rg "pattern"` instead of inline code blocks |
| 36–45 | Merge thin sections | Combine two small sections covering the same topic |
| 46+ | Aggressive removal | Remove anything that doesn't affect the metric |

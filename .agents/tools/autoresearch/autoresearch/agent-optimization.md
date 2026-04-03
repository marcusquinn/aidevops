# Autoresearch — Agent Optimization Domain

Sub-doc for `autoresearch.md`. Load when `PROGRAM_NAME == "agent-optimization"` or
`METRIC_CMD` contains `agent-test-helper.sh`.

---

## Composite Metric Parsing

The metric command outputs a JSON object. Parse it as follows:

```bash
METRIC_JSON=$(eval "$METRIC_CMD")
COMPOSITE_SCORE=$(echo "$METRIC_JSON" | jq '.composite_score')
PASS_RATE=$(echo "$METRIC_JSON" | jq '.pass_rate')
TOKEN_RATIO=$(echo "$METRIC_JSON" | jq '.token_ratio')
```

Use `COMPOSITE_SCORE` as the primary metric value for keep/discard decisions.
Log `PASS_RATE` and `TOKEN_RATIO` as supplementary columns in results.tsv.

**Formula**: `composite_score = pass_rate * (1 - 0.3 * token_ratio)`

- `pass_rate`: fraction of tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars` — proxy for token usage
- Higher composite score = better (direction: higher)

---

## Baseline Setup

On first run (BASELINE == null), save the current test results as the baseline
before measuring the baseline metric:

```bash
agent-test-helper.sh baseline .agents/tests/agent-optimization.test.json
```

This sets `baseline_chars` in the baseline file, enabling `token_ratio` computation
on subsequent runs. Without this step, `token_ratio` defaults to 1.0 (no change).

---

## Security Instruction Exemptions

Before generating any hypothesis, check whether it would remove or weaken any of
the following instruction categories. If yes, discard the hypothesis without testing:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

These exemptions are enforced by the constraint list in the research program AND
by the researcher model's hypothesis generation. Both layers must hold.

---

## Simplification State Integration

Before generating hypotheses for a target file, check `.agents/configs/simplification-state.json`:

```bash
TARGET_FILE=".agents/build-plus.md"  # or whichever file is being optimized
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
STORED_HASH=$(jq -r --arg f "$TARGET_FILE" '.files[$f].hash // empty' \
    .agents/configs/simplification-state.json 2>/dev/null)

if [[ "$CURRENT_HASH" == "$STORED_HASH" ]]; then
    log "File unchanged since last optimization. Skipping."
    # If this is the only target, exit with "no work needed"
    # If there are multiple targets, move to the next one
fi
```

After a successful session (composite_score improved vs baseline), update the hash:

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
| 46+ | Simplification | Remove anything that doesn't affect the metric |

Always check security exemptions before testing any hypothesis.

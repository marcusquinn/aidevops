# Evaluation Datasets

Standardised JSONL format and storage convention for LLM evaluation cases. Used by bench and evaluator workflows.

## Format

One JSON object per line. Required fields: `id`, `input`.

```jsonl
{"id":"001","input":"What is the capital of France?","expected":"Paris","context":"France is in Western Europe.","tags":["geography","factual"],"source":"manual"}
{"id":"002","input":"Summarize this PR","expected":null,"context":"PR #123 adds auth middleware...","tags":["code-review","summarization"],"source":"trace:abc123"}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `id` | string | Yes | Unique identifier; auto-generated on `add` |
| `input` | string | Yes | Prompt or input sent to the model |
| `expected` | string/null | No | Expected output; `null` for open-ended evals |
| `context` | string/null | No | Grounding context for faithfulness checks |
| `tags` | string[] | No | Scenario, domain, or difficulty filters |
| `source` | string | No | Provenance: `manual`, `trace:<id>`, `generated:<model>` |
| `metadata` | object/null | No | Extra key-value pairs |

Full schema: `dataset-helper.sh schema`

## Storage

```text
~/.aidevops/.agent-workspace/datasets/    # Global, cross-project
~/Git/myproject/datasets/                 # Project-local, version-controlled
```

## CLI

```bash
DATASET_DIR="$HOME/.aidevops/.agent-workspace/datasets"

# Create
dataset-helper.sh create golden-prompts                    # Global
dataset-helper.sh create api-tests --project ~/Git/myapp   # Project-local

# Add entry
dataset-helper.sh add "$DATASET_DIR/golden-prompts.jsonl" \
  --input "What is the capital of France?" \
  --expected "Paris" \
  --context "France is in Western Europe." \
  --tags "geography,factual" \
  --source "manual"

# Validate
dataset-helper.sh validate "$DATASET_DIR/golden-prompts.jsonl"            # Basic
dataset-helper.sh validate "$DATASET_DIR/golden-prompts.jsonl" --strict   # + type checking

# List and stats
dataset-helper.sh list                                     # Global only
dataset-helper.sh list --project ~/Git/myapp               # Global + project
dataset-helper.sh stats "$DATASET_DIR/golden-prompts.jsonl"

# Promote trace to dataset entry
dataset-helper.sh promote --trace-id abc123
dataset-helper.sh promote --trace-id abc123 -o "$DATASET_DIR/regression.jsonl" --tags "regression"

# Merge (dedup by ID; file2 wins on conflict)
dataset-helper.sh merge dataset1.jsonl dataset2.jsonl -o merged.jsonl
```

## Workflows

### Golden dataset

1. Add manual entries for known cases.
2. Run evaluations; add failures with tags.
3. Re-run after prompt changes to catch regressions.

### Promote from traces

1. Find the trace ID: `jq '.request_id' ~/.aidevops/.agent-workspace/observability/metrics.jsonl | tail`
2. Promote it: `dataset-helper.sh promote --trace-id <id> --tags "edge-case"`
3. Edit the promoted entry with expected output and cleaner input.

### Integrations

- Bench (t1393): `compare-models-helper.sh bench --dataset golden-prompts.jsonl`
- Evaluators (t1394): `ai-judgment-helper.sh evaluate --dataset golden-prompts.jsonl`

## Design decisions

- **JSONL over CSV/JSON-array**: Streamable, append-friendly, grep/wc-friendly, standard in ML/eval tooling, consistent with observability-helper.sh.
- **`id` required**: Enables deduplication, trace-back, and merges.
- **`expected` optional**: Some evals have no single correct answer.
- **`source` provenance**: Distinguishes manual, promoted, and generated cases.
- **`tags` filtering**: Supports subsets by scenario, domain, or difficulty.

# Evaluation Datasets

Standardised JSONL format and directory convention for LLM evaluation test cases. Used by bench and evaluator workflows.

## Dataset Format

Each line is a JSON object (JSONL). Required fields: `id`, `input`.

```jsonl
{"id":"001","input":"What is the capital of France?","expected":"Paris","context":"France is in Western Europe.","tags":["geography","factual"],"source":"manual"}
{"id":"002","input":"Summarize this PR","expected":null,"context":"PR #123 adds auth middleware...","tags":["code-review","summarization"],"source":"trace:abc123"}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (auto-generated on `add`) |
| `input` | string | Yes | Prompt or input to send to the model |
| `expected` | string/null | No | Expected output (null for open-ended evaluations) |
| `context` | string/null | No | Context for grounding (faithfulness evaluation) |
| `tags` | string[] | No | Filtering: scenario type, domain, difficulty |
| `source` | string | No | Provenance: `manual`, `trace:<id>`, `generated:<model>` |
| `metadata` | object/null | No | Arbitrary key-value pairs |

Full JSON Schema: `dataset-helper.sh schema`

## Directory Convention

```text
~/.aidevops/.agent-workspace/datasets/    # Global (cross-project)
~/Git/myproject/datasets/                  # Project-specific (version-controlled)
```

## CLI Reference

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

# List / Stats
dataset-helper.sh list                                     # Global only
dataset-helper.sh list --project ~/Git/myapp               # Global + project
dataset-helper.sh stats "$DATASET_DIR/golden-prompts.jsonl"

# Promote trace to dataset entry
dataset-helper.sh promote --trace-id abc123
dataset-helper.sh promote --trace-id abc123 -o "$DATASET_DIR/regression.jsonl" --tags "regression"

# Merge (dedup by ID, file2 wins on conflict)
dataset-helper.sh merge dataset1.jsonl dataset2.jsonl -o merged.jsonl
```

## Workflows

### Building a Golden Dataset

1. Add manual entries for known test cases
2. Run evaluations, identify failures → add failure cases with tags
3. Re-run after prompt changes to detect regressions

### Promoting from Traces

1. Find trace ID: `jq '.request_id' ~/.aidevops/.agent-workspace/observability/metrics.jsonl | tail`
2. Promote: `dataset-helper.sh promote --trace-id <id> --tags "edge-case"`
3. Edit promoted entry to add expected output and refine input

### Integration with Bench (t1393)

```bash
compare-models-helper.sh bench --dataset golden-prompts.jsonl
```

### Integration with Evaluators (t1394)

```bash
ai-judgment-helper.sh evaluate --dataset golden-prompts.jsonl
```

## Design Decisions

- **JSONL over CSV/JSON-array**: Streamable, one entry per line (grep/wc), standard in ML/eval tooling, consistent with observability-helper.sh
- **`id` required**: Deduplication, trace-back, merge operations
- **`expected` optional**: Many evaluations lack a single correct answer (summarization, creative)
- **`source` provenance**: Distinguish hand-written, promoted from production, or synthetically generated
- **`tags` filtering**: Run dataset subsets by scenario type, domain, or difficulty

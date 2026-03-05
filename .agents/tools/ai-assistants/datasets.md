# Evaluation Datasets

Standardised JSONL format and directory convention for storing LLM evaluation test cases. Enables repeatable evaluations across bench and evaluator workflows.

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
| `tags` | string[] | No | Tags for filtering: scenario type, domain, difficulty |
| `source` | string | No | Provenance: `manual`, `trace:<id>`, `generated:<model>` |
| `metadata` | object/null | No | Arbitrary key-value pairs for extra context |

Run `dataset-helper.sh schema` for the full JSON Schema.

## Directory Convention

```text
~/.aidevops/.agent-workspace/datasets/    # Global datasets (cross-project)
  golden-prompts.jsonl                     # Curated test prompts
  regression-auth.jsonl                    # Auth-related regression cases
  promoted.jsonl                           # Auto-created by promote command

~/Git/myproject/datasets/                  # Project-specific datasets
  api-responses.jsonl                      # Expected API response quality
```

- **Global datasets** live in agent-workspace — shared across all projects
- **Project datasets** live in the repo's `datasets/` directory — version-controlled with the code

## CLI Reference

```bash
# Set the global dataset directory for copy/paste convenience
DATASET_DIR="$HOME/.aidevops/.agent-workspace/datasets"

# Create a new dataset
dataset-helper.sh create golden-prompts                    # Global
dataset-helper.sh create api-tests --project ~/Git/myapp   # Project-local

# Add entries (use full path from create output, or $DATASET_DIR)
dataset-helper.sh add "$DATASET_DIR/golden-prompts.jsonl" \
  --input "What is the capital of France?" \
  --expected "Paris" \
  --tags "geography,factual"

dataset-helper.sh add "$DATASET_DIR/golden-prompts.jsonl" \
  --input "Summarize this code" \
  --context "function add(a, b) { return a + b; }" \
  --tags "code,summarization" \
  --source "manual"

# Validate dataset schema
dataset-helper.sh validate "$DATASET_DIR/golden-prompts.jsonl"            # Basic checks
dataset-helper.sh validate "$DATASET_DIR/golden-prompts.jsonl" --strict   # + type checking

# List available datasets
dataset-helper.sh list                                     # Global only
dataset-helper.sh list --project ~/Git/myapp               # Global + project

# Show statistics
dataset-helper.sh stats "$DATASET_DIR/golden-prompts.jsonl"

# Promote observability trace to dataset entry
dataset-helper.sh promote --trace-id abc123
dataset-helper.sh promote --trace-id abc123 -o "$DATASET_DIR/regression.jsonl" --tags "regression"

# Merge datasets (dedup by ID, file2 wins on conflict)
dataset-helper.sh merge dataset1.jsonl dataset2.jsonl -o merged.jsonl
```

## Workflows

### Building a Golden Dataset

1. Start with manual entries for known test cases
2. Run evaluations, identify failures
3. Add failure cases to the dataset with appropriate tags
4. Re-run evaluations after prompt changes to detect regressions

### Promoting from Traces

When observability captures an interesting interaction:

1. Find the trace ID: `jq '.request_id' ~/.aidevops/.agent-workspace/observability/metrics.jsonl | tail`
2. Promote it: `dataset-helper.sh promote --trace-id <id> --tags "edge-case"`
3. Edit the promoted entry to add expected output and refine the input

### Integration with Bench (t1393)

```bash
# Run the same dataset through multiple models
compare-models-helper.sh bench --dataset golden-prompts.jsonl
```

### Integration with Evaluators (t1394)

```bash
# Score model outputs against dataset expectations
ai-judgment-helper.sh evaluate --dataset golden-prompts.jsonl
```

## Design Decisions

- **JSONL over CSV/JSON-array**: Streamable (append without rewriting), one entry per line (easy grep/wc), standard in ML/eval tooling, consistent with observability-helper.sh
- **`id` required**: Enables deduplication, trace-back, and merge operations
- **`expected` optional**: Many evaluations don't have a single correct answer (summarization, creative writing)
- **`source` tracks provenance**: Know whether a test case was hand-written, promoted from production, or synthetically generated
- **`tags` enable filtering**: Run subsets of a dataset by scenario type, domain, or difficulty

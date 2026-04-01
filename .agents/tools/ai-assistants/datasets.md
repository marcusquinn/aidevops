# Evaluation Datasets

JSONL format and storage for LLM evaluation cases. Used by bench and evaluator workflows.

## Format

One JSON object per line. Required: `id`, `input`. Full schema: `dataset-helper.sh schema`

```jsonl
{"id":"001","input":"What is the capital of France?","expected":"Paris","context":"France is in Western Europe.","tags":["geography","factual"],"source":"manual"}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `id` | string | Yes | Unique identifier; auto-generated on `add` |
| `input` | string | Yes | Prompt sent to the model |
| `expected` | string/null | No | Expected output; `null` for open-ended evals |
| `context` | string/null | No | Grounding context for faithfulness checks |
| `tags` | string[] | No | Scenario, domain, or difficulty filters |
| `source` | string | No | Provenance: `manual`, `trace:<id>`, `generated:<model>` |
| `metadata` | object/null | No | Extra key-value pairs |

## Storage

- **Global**: `~/.aidevops/.agent-workspace/datasets/`
- **Project-local**: `~/Git/<project>/datasets/` (version-controlled)

## CLI

```bash
D="$HOME/.aidevops/.agent-workspace/datasets"

dataset-helper.sh create golden-prompts                    # Global
dataset-helper.sh create api-tests --project ~/Git/myapp   # Project-local
dataset-helper.sh add "$D/golden-prompts.jsonl" \
  --input "What is the capital of France?" --expected "Paris" \
  --context "France is in Western Europe." --tags "geography,factual" --source "manual"
dataset-helper.sh validate "$D/golden-prompts.jsonl"            # Basic
dataset-helper.sh validate "$D/golden-prompts.jsonl" --strict   # + type checking
dataset-helper.sh list                                     # Global only
dataset-helper.sh list --project ~/Git/myapp               # Global + project
dataset-helper.sh stats "$D/golden-prompts.jsonl"
dataset-helper.sh promote --trace-id abc123 -o "$D/regression.jsonl" --tags "regression"
dataset-helper.sh merge dataset1.jsonl dataset2.jsonl -o merged.jsonl  # Dedup by ID; file2 wins
```

## Workflows

**Golden dataset**: Add manual entries for known cases. Run evaluations; add failures with tags. Re-run after prompt changes to catch regressions.

**Promote from traces**: Find trace ID via `jq '.request_id' ~/.aidevops/.agent-workspace/observability/metrics.jsonl | tail`, then `dataset-helper.sh promote --trace-id <id> --tags "edge-case"`. Edit the promoted entry with expected output.

**Integrations**: Bench (t1393): `compare-models-helper.sh bench --dataset golden-prompts.jsonl` | Evaluators (t1394): `ai-judgment-helper.sh evaluate --dataset golden-prompts.jsonl`

## Design decisions

- **JSONL**: Streamable, append-friendly, grep/wc-friendly; consistent with observability-helper.sh
- **`id` required**: Enables dedup, trace-back, and merges
- **`expected` optional**: Some evals have no single correct answer
- **`source`**: Distinguishes manual, promoted, and generated cases
- **`tags`**: Supports subsets by scenario, domain, or difficulty

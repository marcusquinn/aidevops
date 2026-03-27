# Seed Bracketing Method

Increases success rate from 15% to 70%+ by systematically testing seed ranges.

**Step 1**: Select seed range by content type (people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999).

**Step 2**: Generate 10-15 variations with sequential seeds:

```bash
#!/bin/bash
set -euo pipefail
HF_API_KEY="${HF_API_KEY:?Set HF_API_KEY}"
HF_SECRET="${HF_SECRET:?Set HF_SECRET}"
: > seed_bracket_results.csv
echo "seed,job_id" >> seed_bracket_results.csv
for seed in {4000..4010}; do
  result=$(curl --fail --show-error --silent -X POST \
    'https://platform.higgsfield.ai/v1/image2video/dop' \
    --header "hf-api-key: ${HF_API_KEY}" --header "hf-secret: ${HF_SECRET}" \
    --data "{\"params\":{\"prompt\":\"[your prompt]\",\"seed\":$seed,\"model\":\"dop-turbo\"}}") \
    || { echo "ERROR: API call failed for seed $seed" >&2; continue; }
  job_id=$(echo "$result" | jq -r '.jobs[0].id // empty' || true)
  [[ -z "$job_id" ]] && { echo "ERROR: No job_id for seed $seed" >&2; continue; }
  echo "$seed,$job_id" >> seed_bracket_results.csv
done
```

**Step 3**: Score outputs (1-10 scale): Composition 25%, Quality 25%, Style Adherence 20%, Motion Realism 20%, Subject Accuracy 10%.

**Step 4**: Score 8.0+ = production-ready; 6.5-7.9 = acceptable; <6.5 = discard. If no winners, shift to adjacent range (+/- 100) or revise prompt.

## Automation

```bash
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh status
seed-bracket-helper.sh score 4005 8 9 7 8 9
seed-bracket-helper.sh report
seed-bracket-helper.sh presets
```

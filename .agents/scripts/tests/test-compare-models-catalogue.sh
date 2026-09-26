#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${script_dir}/compare-models-helper.sh"
models=(gpt-6-sol gpt-5.6-sol claude-opus-5-5 qwen3.8-max)

list=$(bash "$helper" list)
pricing=$(bash "$helper" pricing)
help=$(bash "$helper" help)
capabilities=$(bash "$helper" capabilities)
comparison=$(bash "$helper" compare "${models[@]}")
recommendation=$(bash "$helper" recommend 'create a visually polished responsive website')

for model in "${models[@]}"; do
	[[ "$list" == *"$model"* && "$comparison" == *"$model"* && "$capabilities" == *"$model"* ]] || {
		printf 'Missing current model: %s\n' "$model" >&2
		exit 1
	}
done
[[ "$list" == *'Snapshot: 2026-09-25'* && "$pricing" == *'Snapshot: 2026-09-25'* && "$help" == *'Snapshot: 2026-09-25'* ]]
[[ "$comparison" == *'unverified'* && "$pricing" == *'unverified'* ]]
[[ "$recommendation" == *'not aesthetic quality'* && "$recommendation" == *'independent visual review'* ]]
[[ "$comparison" != *'No model found'* && "$comparison" != *'No models found'* ]]
printf 'PASS: offline model catalogue, pricing qualifiers, freshness and visual-evidence guidance\n'

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Compare Models — Live Benchmarking Library (t1393)
# =============================================================================
# Sends the same prompt (or JSONL dataset) to N models and compares actual
# outputs with latency, tokens, cost, and optional LLM-as-judge quality score.
#
# Usage: source "${SCRIPT_DIR}/compare-models-bench-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning, print_success, CONTENT_TYPE_JSON)
#   - compare-models-scoring-lib.sh (init_results_db, check_provider_key)
#   - Orchestrator globals: MODEL_DATA, get_field, find_model
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_COMPARE_MODELS_BENCH_LIB_LOADED:-}" ]] && return 0
_COMPARE_MODELS_BENCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

readonly BENCH_RESULTS_DIR="${HOME}/.aidevops/.agent-workspace/observability"
readonly BENCH_RESULTS_FILE="${BENCH_RESULTS_DIR}/bench-results.jsonl"

# Resolve a provider API key value for use in curl calls.
# Uses the same resolution chain as check_provider_key but returns the value.
# Arguments: arg1 — env var name (e.g. ANTHROPIC_API_KEY)
# Output: key value on stdout
# Returns: 0 if found, 1 if not
_resolve_key_value() {
	local key_name="$1"

	# 1. Environment variable
	if [[ -n "${!key_name:-}" ]]; then
		echo "${!key_name}"
		return 0
	fi

	# 2. gopass
	if command -v gopass &>/dev/null; then
		local val
		val=$(gopass show -o "aidevops/${key_name}" 2>/dev/null) || true
		if [[ -n "$val" ]]; then
			echo "$val"
			return 0
		fi
	fi

	# 3. credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		local val
		val=$(grep -E "^(export )?${key_name}=" "$creds_file" 2>/dev/null | head -1 | sed "s/^export //" | cut -d= -f2- | tr -d '"'"'" || true)
		if [[ -n "$val" ]]; then
			echo "$val"
			return 0
		fi
	fi

	return 1
}

# Determine which provider a model_id belongs to and its API key env var.
# Output: "provider|key_env_var" or empty if unknown
_model_provider_info() {
	local model_id="$1"
	local match
	match=$(echo "$MODEL_DATA" | grep "^${model_id}|" || true)
	if [[ -z "$match" ]]; then
		# Try partial match
		match=$(find_model "$model_id" | head -1)
	fi
	if [[ -z "$match" ]]; then
		echo ""
		return 0
	fi

	local provider
	provider=$(get_field "$match" 2)
	local actual_model_id
	actual_model_id=$(get_field "$match" 1)

	local key_var=""
	case "$provider" in
	Anthropic) key_var="ANTHROPIC_API_KEY" ;;
	OpenAI) key_var="OPENAI_API_KEY" ;;
	Google) key_var="GOOGLE_API_KEY" ;;
	DeepSeek) key_var="DEEPSEEK_API_KEY" ;;
	*) key_var="" ;;
	esac

	echo "${provider}|${key_var}|${actual_model_id}"
	return 0
}

# Map model_id to the API model string each provider expects
_api_model_string() {
	local model_id="$1"
	case "$model_id" in
	claude-opus-4-6) echo "claude-opus-4-20250514" ;;
	claude-opus-4-7) echo "claude-opus-4-7" ;;
	claude-sonnet-4-6) echo "claude-sonnet-4-20250514" ;;
	claude-haiku-4-5) echo "claude-haiku-4-20250414" ;;
	gpt-4.1) echo "gpt-4.1" ;;
	gpt-4.1-mini) echo "gpt-4.1-mini" ;;
	gpt-4.1-nano) echo "gpt-4.1-nano" ;;
	gpt-4o) echo "gpt-4o" ;;
	gpt-4o-mini) echo "gpt-4o-mini" ;;
	o3) echo "o3" ;;
	o4-mini) echo "o4-mini" ;;
	gemini-2.5-pro) echo "gemini-2.5-pro" ;;
	gemini-2.5-flash) echo "gemini-2.5-flash" ;;
	gemini-2.0-flash) echo "gemini-2.0-flash" ;;
	deepseek-r1) echo "deepseek-reasoner" ;;
	deepseek-v3) echo "deepseek-chat" ;;
	*) echo "$model_id" ;;
	esac
	return 0
}

# Call a single model API and capture response + metrics.
# Arguments:
#   arg1 — model_id (from MODEL_DATA)
#   arg2 — prompt text
#   arg3 — max_tokens
#   arg4 — output directory for result files
# Output: writes result JSON to arg4/$model_id.json
# Returns: 0 on success, 1 on failure
# Make API call to a model provider
# Args: provider, api_model, api_key, escaped_prompt, max_tokens, raw_file
# Returns: http_code
_bench_api_call() {
	local provider="$1"
	local api_model="$2"
	local api_key="$3"
	local escaped_prompt="$4"
	local max_tokens="$5"
	local raw_file="$6"
	local http_code

	case "$provider" in
	Anthropic)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "x-api-key: ${api_key}" \
			-H "anthropic-version: 2023-06-01" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.anthropic.com/v1/messages" 2>/dev/null) || http_code="000"
		;;
	OpenAI)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "Authorization: Bearer ${api_key}" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.openai.com/v1/chat/completions" 2>/dev/null) || http_code="000"
		;;
	Google)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"contents\": [{\"parts\": [{\"text\": ${escaped_prompt}}]}],
				\"generationConfig\": {\"maxOutputTokens\": ${max_tokens}}
			}" \
			"https://generativelanguage.googleapis.com/v1beta/models/${api_model}:generateContent?key=${api_key}" \
			2>/dev/null) || http_code="000"
		;;
	DeepSeek)
		http_code=$(curl -sS -o "$raw_file" -w "%{http_code}" --max-time 120 \
			-H "Authorization: Bearer ${api_key}" \
			-H "${CONTENT_TYPE_JSON}" \
			-d "{
				\"model\": \"${api_model}\",
				\"max_tokens\": ${max_tokens},
				\"messages\": [{\"role\": \"user\", \"content\": ${escaped_prompt}}]
			}" \
			"https://api.deepseek.com/v1/chat/completions" 2>/dev/null) || http_code="000"
		;;
	*)
		http_code="000"
		;;
	esac

	echo "$http_code"
	return 0
}

# Escape a prompt string for embedding in a JSON payload.
# Args: arg1=prompt text
# Output: JSON-encoded string (with surrounding quotes)
_bench_escape_prompt() {
	local prompt="$1"
	if command -v python3 &>/dev/null; then
		printf '%s' "$prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null
	else
		printf '"%s"' "$(printf '%s' "$prompt" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\t/\\t/g')"
	fi
	return 0
}

# Parse a raw provider API response into a normalized JSON result file.
# Args: arg1=provider arg2=actual_id arg3=latency_ms arg4=http_code arg5=raw_file arg6=result_file
_bench_parse_response() {
	local provider="$1"
	local actual_id="$2"
	local latency_ms="$3"
	local http_code="$4"
	local raw_file="$5"
	local result_file="$6"

	if [[ ! -f "$raw_file" ]] || [[ ! -s "$raw_file" ]]; then
		echo "{\"error\":\"empty response\",\"http_code\":\"${http_code}\",\"latency_ms\":${latency_ms}}" >"$result_file"
		return 1
	fi

	python3 -c "
import json, sys

provider = '${provider}'
model_id = '${actual_id}'
latency_ms = ${latency_ms}
http_code = '${http_code}'

try:
    with open('${raw_file}', 'r') as f:
        raw = json.load(f)
except Exception as e:
    json.dump({'error': str(e), 'http_code': http_code, 'latency_ms': latency_ms, 'model': model_id}, sys.stdout)
    sys.exit(0)

result = {
    'model': model_id,
    'provider': provider,
    'latency_ms': latency_ms,
    'http_code': http_code,
    'tokens_in': 0,
    'tokens_out': 0,
    'output': '',
    'error': ''
}

if provider == 'Anthropic':
    result['output'] = ''.join(b.get('text', '') for b in raw.get('content', []))
    usage = raw.get('usage', {})
    result['tokens_in'] = usage.get('input_tokens', 0)
    result['tokens_out'] = usage.get('output_tokens', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))
elif provider in ('OpenAI', 'DeepSeek'):
    choices = raw.get('choices', [])
    if choices:
        result['output'] = choices[0].get('message', {}).get('content', '')
    usage = raw.get('usage', {})
    result['tokens_in'] = usage.get('prompt_tokens', 0)
    result['tokens_out'] = usage.get('completion_tokens', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))
elif provider == 'Google':
    candidates = raw.get('candidates', [])
    if candidates:
        parts = candidates[0].get('content', {}).get('parts', [])
        result['output'] = ''.join(p.get('text', '') for p in parts)
    usage = raw.get('usageMetadata', {})
    result['tokens_in'] = usage.get('promptTokenCount', 0)
    result['tokens_out'] = usage.get('candidatesTokenCount', 0)
    if raw.get('error'):
        result['error'] = raw['error'].get('message', str(raw['error']))

json.dump(result, sys.stdout)
" >"$result_file" 2>/dev/null || {
		echo "{\"error\":\"parse failure\",\"latency_ms\":${latency_ms},\"model\":\"${actual_id}\"}" >"$result_file"
		return 1
	}
	return 0
}

_bench_call_model() {
	local model_id="$1"
	local prompt="$2"
	local max_tokens="$3"
	local out_dir="$4"

	local info
	info=$(_model_provider_info "$model_id")
	if [[ -z "$info" ]]; then
		echo "{\"error\":\"unknown model: ${model_id}\"}" >"${out_dir}/${model_id}.json"
		return 1
	fi

	local provider key_var actual_id
	IFS='|' read -r provider key_var actual_id <<<"$info"

	if [[ -z "$key_var" ]]; then
		echo "{\"error\":\"no API key mapping for provider: ${provider}\"}" >"${out_dir}/${actual_id}.json"
		return 1
	fi

	local api_key
	api_key=$(_resolve_key_value "$key_var") || {
		echo "{\"error\":\"API key not found: ${key_var}\"}" >"${out_dir}/${actual_id}.json"
		return 1
	}

	local api_model escaped_prompt
	api_model=$(_api_model_string "$actual_id")
	escaped_prompt=$(_bench_escape_prompt "$prompt")

	local start_ms http_code end_ms latency_ms
	start_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)

	local result_file="${out_dir}/${actual_id}.json"
	local raw_file="${out_dir}/${actual_id}-raw.json"

	# Make API call
	http_code=$(_bench_api_call "$provider" "$api_model" "$api_key" "$escaped_prompt" "$max_tokens" "$raw_file")
	[[ "$http_code" == "000" ]] && {
		echo "{\"error\":\"unsupported provider: ${provider}\"}" >"$result_file"
		return 1
	}

	end_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)
	latency_ms=$((end_ms - start_ms))

	_bench_parse_response "$provider" "$actual_id" "$latency_ms" "$http_code" "$raw_file" "$result_file" || return 1

	# Clean up raw file
	rm -f "$raw_file"
	return 0
}

# Calculate cost from token counts and model pricing
# Arguments: arg1=model_id arg2=tokens_in arg3=tokens_out
# Output: cost as decimal string
_calc_bench_cost() {
	local model_id="$1"
	local tokens_in="$2"
	local tokens_out="$3"

	local match
	match=$(echo "$MODEL_DATA" | grep "^${model_id}|" | head -1 || true)
	if [[ -z "$match" ]]; then
		echo "0.0000"
		return 0
	fi

	local input_price output_price
	input_price=$(get_field "$match" 5)
	output_price=$(get_field "$match" 6)

	# Cost = (tokens / 1M) * price_per_1M
	awk "BEGIN{printf \"%.6f\", (${tokens_in}/1000000.0)*${input_price} + (${tokens_out}/1000000.0)*${output_price}}"
	return 0
}

# Store bench result as JSONL
_store_bench_result() {
	local model_id="$1"
	local prompt_text="$2"
	local latency_ms="$3"
	local tokens_in="$4"
	local tokens_out="$5"
	local cost="$6"
	local judge_score="${7:-}"
	local prompt_version="${8:-}"

	mkdir -p "$BENCH_RESULTS_DIR"

	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local prompt_hash
	# shell-portability: ignore next — sha256sum: macOS needs shasum -a 256 (GH#18787)
	prompt_hash=$(printf '%s' "$prompt_text" | sha256sum | cut -c1-12)

	local output_hash
	# shell-portability: ignore next — sha256sum: macOS needs shasum -a 256 (GH#18787)
	output_hash=$(printf '%s' "${model_id}:${ts}" | sha256sum | cut -c1-12)

	local judge_field=""
	if [[ -n "$judge_score" ]]; then
		judge_field=",\"judge_score\":${judge_score}"
	fi

	local version_field=""
	if [[ -n "$prompt_version" ]]; then
		version_field=",\"prompt_version\":\"${prompt_version}\""
	fi

	printf '{"ts":"%s","prompt_hash":"%s","model":"%s","latency_ms":%d,"tokens_in":%d,"tokens_out":%d,"cost":%s%s%s,"output_hash":"%s"}\n' \
		"$ts" "$prompt_hash" "$model_id" "$latency_ms" "$tokens_in" "$tokens_out" "$cost" \
		"$judge_field" "$version_field" "$output_hash" >>"$BENCH_RESULTS_FILE"
	return 0
}

# LLM-as-judge scoring for bench results
# Arguments: arg1=prompt arg2=output_dir (contains model result files)
# Output: model_id|score lines on stdout
_bench_judge_score() {
	local original_prompt="$1"
	local out_dir="$2"

	local ai_helper="${SCRIPT_DIR}/ai-research-helper.sh"
	if [[ ! -x "$ai_helper" ]]; then
		print_warning "ai-research-helper.sh not found — skipping judge scoring"
		return 0
	fi

	# Build judge prompt with all model outputs
	local judge_prompt="You are evaluating AI model responses to the same prompt. Rate each response on a 0.0-1.0 scale for overall quality (accuracy, completeness, clarity, relevance).

ORIGINAL PROMPT:
${original_prompt}

MODEL RESPONSES:
"
	local -a models_with_output=()
	for result_file in "${out_dir}"/*.json; do
		[[ -f "$result_file" ]] || continue
		local basename_file
		basename_file=$(basename "$result_file" .json)
		# Skip non-model files
		[[ "$basename_file" == *"-raw"* ]] && continue
		[[ "$basename_file" == "judge"* ]] && continue

		local output error
		output=$(jq -r '.output // ""' "$result_file" 2>/dev/null || echo "")
		error=$(jq -r '.error // ""' "$result_file" 2>/dev/null || echo "")

		if [[ -n "$output" && -z "$error" ]]; then
			# Truncate to 2000 chars per model for judge prompt
			local truncated="${output:0:2000}"
			judge_prompt+="
=== MODEL: ${basename_file} ===
${truncated}
"
			models_with_output+=("$basename_file")
		fi
	done

	if [[ ${#models_with_output[@]} -lt 1 ]]; then
		return 0
	fi

	judge_prompt+="
Respond with ONLY a valid JSON object mapping model names to scores:
{\"model_name\": 0.85, \"other_model\": 0.72}
No explanation, no markdown, just the JSON object."

	local judge_result
	judge_result=$("$ai_helper" --prompt "$judge_prompt" --model haiku --max-tokens 200 2>/dev/null || echo "")

	if [[ -z "$judge_result" ]]; then
		print_warning "Judge returned no output"
		return 0
	fi

	# Parse judge JSON and output model|score lines
	echo "$judge_result" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{[^}]+\}', text)
if m:
    try:
        scores = json.loads(m.group())
        for model, score in scores.items():
            s = float(score)
            if s < 0: s = 0.0
            if s > 1: s = 1.0
            print(f'{model}|{s:.2f}')
    except Exception:
        pass
" 2>/dev/null || true
	return 0
}

#######################################
# Live model benchmarking (t1393)
# Usage: compare-models-helper.sh bench "prompt text" model1 model2 [model3...]
#        compare-models-helper.sh bench --dataset path/to/dataset.jsonl model1 model2
#        compare-models-helper.sh bench --history [--limit N]
#
# Options:
#   --judge           Enable LLM-as-judge scoring (haiku-tier, ~$0.001/call)
#   --dataset FILE    Read prompts from JSONL file (each line: {"input":"..."} or {"prompt":"..."})
#   --max-tokens N    Max output tokens per model (default: 1024)
#   --dry-run         Show what would happen without making API calls
#   --history         Show historical bench results
#   --limit N         Limit history output (default: 20)
#   --version TAG     Tag results with a prompt version (e.g. git short hash)
#######################################

# Parse command-line arguments for cmd_bench
# Sets: prompt, dataset_file, max_tokens, dry_run, judge_flag, history_flag, history_limit, prompt_version, model_args
# Bash 3.2 compatible: printf -v for scalar writes, ${!var} for reads, eval for array appends.
_bench_parse_args() {
	local _r_prompt="$1" _r_dataset="$2" _r_max_tokens="$3" _r_dry_run="$4"
	local _r_judge="$5" _r_history="$6" _r_limit="$7" _r_version="$8" _r_models="$9"
	shift 9
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dataset)
			[[ $# -lt 2 ]] && { print_error "--dataset requires a file path"; return 1; }
			printf -v "$_r_dataset" '%s' "$2"; shift 2 ;;
		--judge)
			printf -v "$_r_judge" '%s' true; shift ;;
		--max-tokens)
			[[ $# -lt 2 ]] && { print_error "--max-tokens requires a value"; return 1; }
			printf -v "$_r_max_tokens" '%s' "$2"; shift 2 ;;
		--dry-run)
			printf -v "$_r_dry_run" '%s' true; shift ;;
		--history)
			printf -v "$_r_history" '%s' true; shift ;;
		--limit)
			[[ $# -lt 2 ]] && { print_error "--limit requires a value"; return 1; }
			printf -v "$_r_limit" '%s' "$2"; shift 2 ;;
		--version)
			[[ $# -lt 2 ]] && { print_error "--version requires a value"; return 1; }
			printf -v "$_r_version" '%s' "$2"; shift 2 ;;
		--*)
			print_error "Unknown option: $1"; return 1 ;;
		*)
			if [[ -z "${!_r_prompt}" && -z "${!_r_dataset}" ]]; then
				printf -v "$_r_prompt" '%s' "$1"
			else
				eval "${_r_models}+=(\"\$1\")"
			fi
			shift ;;
		esac
	done
	return 0
}

# Validate bench inputs and build prompts list
# Returns: 0 on success, 1 on error
# Bash 3.2 compatible: uses ${!var} for indirect reads, eval for array ops.
_bench_validate_and_build() {
	local _r_prompt="$1"
	local _r_dataset="$2"
	local _r_max_tokens="$3"
	local _r_models="$4"
	local _r_prompts="$5"
	local _r_valid_models="$6"

	# Read scalar values via indirect expansion (bash 3.2 compatible)
	local _prompt="${!_r_prompt}"
	local _dataset="${!_r_dataset}"
	local _max_tokens="${!_r_max_tokens}"

	# Validate inputs
	if [[ -z "$_prompt" && -z "$_dataset" ]]; then
		print_error "Usage: compare-models-helper.sh bench \"prompt\" model1 model2 [model3...]"
		echo "       compare-models-helper.sh bench --dataset file.jsonl model1 model2"
		echo "       compare-models-helper.sh bench --history [--limit N]"
		echo ""
		echo "Options:"
		echo "  --judge           Enable LLM-as-judge quality scoring"
		echo "  --dataset FILE    Read prompts from JSONL (each line: {\"input\":\"...\"} or {\"prompt\":\"...\"})"
		echo "  --max-tokens N    Max output tokens per model (default: 1024)"
		echo "  --dry-run         Show plan without making API calls"
		echo "  --history         Show historical bench results"
		echo "  --version TAG     Tag results with prompt version"
		return 1
	fi

	local _models_cnt
	eval "_models_cnt=\${#${_r_models}[@]}"
	if [[ "${_models_cnt}" -lt 1 ]]; then
		print_error "At least 1 model required for benchmarking"
		return 1
	fi

	if [[ -n "$_dataset" && ! -f "$_dataset" ]]; then
		print_error "Dataset file not found: $_dataset"
		return 1
	fi

	if ! [[ "$_max_tokens" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --max-tokens value: $_max_tokens"
		return 1
	fi

	# Build prompts list
	local p
	if [[ -n "$_dataset" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			p=$(printf '%s' "$line" | jq -r '(.input // .prompt) // empty' || true)
			if [[ -n "$p" ]]; then
				eval "${_r_prompts}+=(\"\$p\")"
			fi
		done <"$_dataset"
		local _prompts_cnt
		eval "_prompts_cnt=\${#${_r_prompts}[@]}"
		if [[ "${_prompts_cnt}" -eq 0 ]]; then
			print_error "No valid prompts found in dataset (expected JSONL with {\"input\":\"...\"} or {\"prompt\":\"...\"})"
			return 1
		fi
	else
		eval "${_r_prompts}+=(\"\$_prompt\")"
	fi

	# Validate models exist in MODEL_DATA
	local _i m info actual_id
	for (( _i=0; _i<_models_cnt; _i++ )); do
		eval "m=\${${_r_models}[$_i]}"
		info=$(_model_provider_info "$m")
		if [[ -z "$info" ]]; then
			print_warning "Unknown model: $m (skipping)"
		else
			actual_id=$(echo "$info" | cut -d'|' -f3)
			eval "${_r_valid_models}+=(\"\$actual_id\")"
		fi
	done

	local _valid_cnt
	eval "_valid_cnt=\${#${_r_valid_models}[@]}"
	if [[ "${_valid_cnt}" -lt 1 ]]; then
		print_error "No valid models found"
		return 1
	fi

	return 0
}

# Display dry-run plan with cost estimates
_bench_show_plan() {
	local max_tokens="$1"
	local judge_flag="$2"
	shift 2
	local -a valid_models=("$@")

	echo ""
	echo "Bench Plan (dry-run)"
	echo "===================="
	echo ""
	echo "Prompts: ${#valid_models[@]}"
	echo "Models:  ${valid_models[*]}"
	echo "Max tokens: $max_tokens"
	echo "Judge: $judge_flag"
	echo "Total API calls: $((${#valid_models[@]} * ${#valid_models[@]}))"
	echo ""

	# Estimate cost
	echo "| Model                  | Est. Cost/prompt | Provider |"
	echo "|------------------------|------------------|----------|"
	for m in "${valid_models[@]}"; do
		local match
		match=$(echo "$MODEL_DATA" | grep "^${m}|" | head -1 || true)
		if [[ -n "$match" ]]; then
			local prov input_p output_p
			prov=$(get_field "$match" 2)
			input_p=$(get_field "$match" 5)
			output_p=$(get_field "$match" 6)
			local est_cost
			est_cost=$(awk "BEGIN{printf \"%.4f\", (200/1000000.0)*${input_p} + (${max_tokens}/1000000.0)*${output_p}}")
			printf "| %-22s | \$%-15s | %-8s |\n" "$m" "$est_cost" "$prov"
		fi
	done
	echo ""

	if [[ "$judge_flag" == true ]]; then
		echo "Judge cost: ~\$0.001 per prompt (haiku-tier)"
	fi
	echo ""
	echo "Run without --dry-run to execute."
	return 0
}

# Display results table for a single prompt
_bench_display_results() {
	local bench_dir="$1"
	local judge_flag="$2"
	shift 2
	local -a valid_models=("$@")

	if [[ "$judge_flag" == true ]]; then
		printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
			"Model" "Latency" "Tokens (in/out)" "Cost" "Judge Score"
		printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
			"----------------------" "-------" "---------------" "---------" "-----------"
	else
		printf "| %-22s | %7s | %15s | %9s |\n" \
			"Model" "Latency" "Tokens (in/out)" "Cost"
		printf "| %-22s | %7s | %15s | %9s |\n" \
			"----------------------" "-------" "---------------" "---------"
	fi

	for m in "${valid_models[@]}"; do
		local result_file="${bench_dir}/${m}.json"
		if [[ ! -f "$result_file" ]]; then
			if [[ "$judge_flag" == true ]]; then
				printf "| %-22s | %7s | %15s | %9s | %11s |\n" "$m" "ERROR" "-" "-" "-"
			else
				printf "| %-22s | %7s | %15s | %9s |\n" "$m" "ERROR" "-" "-"
			fi
			continue
		fi

		local latency tokens_in tokens_out error_msg
		latency=$(jq -r '.latency_ms // 0' "$result_file" 2>/dev/null || echo "0")
		tokens_in=$(jq -r '.tokens_in // 0' "$result_file" 2>/dev/null || echo "0")
		tokens_out=$(jq -r '.tokens_out // 0' "$result_file" 2>/dev/null || echo "0")
		error_msg=$(jq -r '.error // ""' "$result_file" 2>/dev/null || echo "")

		if [[ -n "$error_msg" ]]; then
			if [[ "$judge_flag" == true ]]; then
				printf "| %-22s | %7s | %15s | %9s | %11s |\n" "$m" "FAIL" "$error_msg" "-" "-"
			else
				printf "| %-22s | %7s | %15s | %9s |\n" "$m" "FAIL" "$error_msg" "-"
			fi
			continue
		fi

		local latency_fmt
		if [[ "$latency" -ge 1000 ]]; then
			latency_fmt=$(awk "BEGIN{printf \"%.1fs\", ${latency}/1000.0}")
		else
			latency_fmt="${latency}ms"
		fi

		local tokens_fmt="${tokens_in}/${tokens_out}"
		local cost
		cost=$(_calc_bench_cost "$m" "$tokens_in" "$tokens_out")
		local cost_fmt
		cost_fmt=$(printf "\$%.4f" "$cost")

		if [[ "$judge_flag" == true ]]; then
			local judge_fmt="${judge_score:-  -  }"
			printf "| %-22s | %7s | %15s | %9s | %11s |\n" \
				"$m" "$latency_fmt" "$tokens_fmt" "$cost_fmt" "$judge_fmt"
		else
			printf "| %-22s | %7s | %15s | %9s |\n" \
				"$m" "$latency_fmt" "$tokens_fmt" "$cost_fmt"
		fi
	done
	return 0
}

cmd_bench() {
	local prompt="" dataset_file="" max_tokens=1024 dry_run=false
	local judge_flag=false history_flag=false history_limit=20
	local prompt_version=""
	local -a model_args=()

	# Parse arguments
	_bench_parse_args prompt dataset_file max_tokens dry_run judge_flag history_flag history_limit prompt_version model_args "$@" || return 1

	# Handle --history subcommand
	if [[ "$history_flag" == true ]]; then
		_bench_show_history "$history_limit"
		return $?
	fi

	# Validate and build prompts list
	local -a prompts=()
	local -a valid_models=()
	_bench_validate_and_build prompt dataset_file max_tokens model_args prompts valid_models || return 1

	# Dry-run mode
	if [[ "$dry_run" == true ]]; then
		_bench_show_plan "$max_tokens" "$judge_flag" "${valid_models[@]}"
		return 0
	fi

	# Execute benchmarks
	echo ""
	echo "Live Model Benchmark"
	echo "===================="
	echo ""
	echo "Models: ${valid_models[*]}"
	echo "Prompts: ${#prompts[@]}"
	echo "Max tokens: $max_tokens"
	[[ "$judge_flag" == true ]] && echo "Judge: enabled (haiku)"
	echo ""

	local prompt_idx=0
	local p
	for p in "${prompts[@]}"; do
		prompt_idx=$((prompt_idx + 1))
		local prompt_label="Prompt"
		[[ ${#prompts[@]} -gt 1 ]] && prompt_label="Prompt ${prompt_idx}/${#prompts[@]}"
		_bench_run_prompt "$p" "$prompt_label" "$max_tokens" "$judge_flag" "$prompt_version" "${valid_models[@]}"
	done

	echo "Results stored: $BENCH_RESULTS_FILE"
	echo ""
	return 0
}

# Run one prompt across all models, display results, and store them.
# Args: arg1=prompt arg2=prompt_label arg3=max_tokens arg4=judge_flag arg5=prompt_version arg6+=valid_models
_bench_run_prompt() {
	local p="$1"
	local prompt_label="$2"
	local max_tokens="$3"
	local judge_flag="$4"
	local prompt_version="$5"
	shift 5
	local -a valid_models=("$@")

	# Truncate prompt for display
	local display_prompt="${p:0:80}"
	[[ ${#p} -gt 80 ]] && display_prompt="${display_prompt}..."
	echo "${prompt_label}: ${display_prompt}"
	echo ""

	# Create temp directory for this prompt's results
	local bench_dir
	bench_dir=$(mktemp -d "${TMPDIR:-/tmp}/bench-XXXXXX")

	# Run models in parallel
	local -a pids=()
	local m
	for m in "${valid_models[@]}"; do
		echo "  Calling ${m}..."
		_bench_call_model "$m" "$p" "$max_tokens" "$bench_dir" &
		pids+=($!)
	done
	local pid
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	# Collect judge scores if enabled
	local -a judge_models=()
	local -a judge_scores_vals=()
	if [[ "$judge_flag" == true ]]; then
		echo "  Scoring with judge (haiku)..."
		local judge_output
		judge_output=$(_bench_judge_score "$p" "$bench_dir")
		local jm js
		while IFS='|' read -r jm js; do
			[[ -z "$jm" ]] && continue
			judge_models+=("$jm")
			judge_scores_vals+=("$js")
		done <<<"$judge_output"
	fi

	# Display results table
	echo ""
	_bench_display_results "$bench_dir" "$judge_flag" "${valid_models[@]}"

	# Store results for each model
	for m in "${valid_models[@]}"; do
		local result_file="${bench_dir}/${m}.json"
		[[ ! -f "$result_file" ]] && continue
		local latency tokens_in tokens_out error_msg
		latency=$(jq -r '.latency_ms // 0' "$result_file" 2>/dev/null || echo "0")
		tokens_in=$(jq -r '.tokens_in // 0' "$result_file" 2>/dev/null || echo "0")
		tokens_out=$(jq -r '.tokens_out // 0' "$result_file" 2>/dev/null || echo "0")
		error_msg=$(jq -r '.error // ""' "$result_file" 2>/dev/null || echo "")
		[[ -n "$error_msg" ]] && continue
		local cost
		cost=$(_calc_bench_cost "$m" "$tokens_in" "$tokens_out")
		# Look up judge score from parallel arrays
		local judge_score=""
		local i
		for i in "${!judge_models[@]}"; do
			if [[ "${judge_models[$i]}" == "$m" ]]; then
				judge_score="${judge_scores_vals[$i]}"
				break
			fi
		done
		_store_bench_result "$m" "$p" "$latency" "$tokens_in" "$tokens_out" "$cost" \
			"$judge_score" "$prompt_version"
	done

	echo ""
	rm -rf "$bench_dir"
	return 0
}

# Show historical bench results
_bench_show_history() {
	local limit="${1:-20}"

	if [[ ! -f "$BENCH_RESULTS_FILE" ]]; then
		echo "No bench history found."
		echo "Run a benchmark first: compare-models-helper.sh bench \"prompt\" model1 model2"
		return 0
	fi

	# Validate limit is numeric
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --limit value: $limit"
		return 1
	fi

	echo ""
	echo "Bench History (last $limit results)"
	echo "===================================="
	echo ""

	printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
		"Timestamp" "Model" "Latency" "Tok Out" "Cost" "Judge"
	printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
		"--------------------" "----------------------" "-------" "-------" "---------" "-----"

	tail -n "$limit" "$BENCH_RESULTS_FILE" | while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local ts model lat tok_out cost judge
		ts=$(echo "$line" | jq -r '.ts // "-"' 2>/dev/null || echo "-")
		model=$(echo "$line" | jq -r '.model // "-"' 2>/dev/null || echo "-")
		lat=$(echo "$line" | jq -r '.latency_ms // 0' 2>/dev/null || echo "0")
		tok_out=$(echo "$line" | jq -r '.tokens_out // 0' 2>/dev/null || echo "0")
		cost=$(echo "$line" | jq -r '.cost // 0' 2>/dev/null || echo "0")
		judge=$(echo "$line" | jq -r '.judge_score // "-"' 2>/dev/null || echo "-")

		# Format timestamp (trim seconds)
		local ts_short="${ts:0:16}"

		local lat_fmt
		if [[ "$lat" -ge 1000 ]]; then
			lat_fmt=$(awk "BEGIN{printf \"%.1fs\", ${lat}/1000.0}")
		else
			lat_fmt="${lat}ms"
		fi

		local cost_fmt
		cost_fmt=$(printf "\$%.4f" "$cost")

		printf "| %-20s | %-22s | %7s | %7s | %9s | %5s |\n" \
			"$ts_short" "$model" "$lat_fmt" "$tok_out" "$cost_fmt" "$judge"
	done

	echo ""

	# Show aggregate stats
	local total_entries
	total_entries=$(wc -l <"$BENCH_RESULTS_FILE" | tr -d ' ')
	echo "Total entries: $total_entries"
	echo "File: $BENCH_RESULTS_FILE"
	echo ""
	return 0
}


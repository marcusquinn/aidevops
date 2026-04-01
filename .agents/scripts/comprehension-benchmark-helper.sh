#!/usr/bin/env bash
# comprehension-benchmark-helper.sh — Benchmark agent file comprehension across model tiers
# Tests whether haiku/sonnet/opus can correctly follow agent file instructions.
# Uses deterministic scoring first, model adjudication second.
#
# Usage:
#   comprehension-benchmark-helper.sh test <scenario.yaml>     # Test one file
#   comprehension-benchmark-helper.sh sweep                     # Run all tests
#   comprehension-benchmark-helper.sh report                    # Generate summary
#   comprehension-benchmark-helper.sh update-state              # Write tier_minimum to state
#   comprehension-benchmark-helper.sh pre-filter <agent.md>     # Structural heuristics only
#
# Exit codes: 0=success, 1=error, 2=no API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 1
TESTS_DIR="${REPO_ROOT}/.agents/tests/comprehension"
STATE_FILE="${REPO_ROOT}/.agents/configs/simplification-state.json"
RESULTS_DIR="${TESTS_DIR}/results"

# Source shared constants if available
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Logging
log_info() {
	local msg="$1"
	echo "[BENCH] $msg" >&2
	return 0
}
log_error() {
	local msg="$1"
	echo "[BENCH:ERROR] $msg" >&2
	return 0
}
log_pass() {
	local msg="$1"
	echo "[BENCH:PASS] $msg" >&2
	return 0
}
log_fail() {
	local msg="$1"
	echo "[BENCH:FAIL] $msg" >&2
	return 0
}

# Tier ordering for escalation
tier_order() {
	local tier="$1"
	case "$tier" in
	haiku) echo 1 ;;
	sonnet) echo 2 ;;
	opus) echo 3 ;;
	*) echo 0 ;;
	esac
	return 0
}

tier_name() {
	local order="$1"
	case "$order" in
	1) echo "haiku" ;;
	2) echo "sonnet" ;;
	3) echo "opus" ;;
	*) echo "unknown" ;;
	esac
	return 0
}

#######################################
# Parse YAML scenario file using python3
# Arguments: $1 — path to YAML file
# Output: JSON on stdout
# Returns: 0 on success, 1 on failure
#######################################
parse_yaml() {
	local yaml_file="$1"
	if [[ ! -f "$yaml_file" ]]; then
		log_error "Scenario file not found: $yaml_file"
		return 1
	fi
	python3 -c "
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
" "$yaml_file" 2>/dev/null || {
		log_error "Failed to parse YAML: $yaml_file"
		return 1
	}
	return 0
}

#######################################
# Structural pre-filter: cheap heuristics before model calls
# Arguments: $1 — path to agent file
# Output: complexity rating (simple|moderate|complex) on stdout
# Returns: 0 always
#######################################
pre_filter() {
	local agent_file="$1"
	if [[ ! -f "$agent_file" ]]; then
		echo "unknown"
		return 0
	fi

	local line_count
	line_count="$(wc -l <"$agent_file" 2>/dev/null)" || line_count=0
	line_count="${line_count// /}"

	local cross_refs
	cross_refs="$(grep -cE '\.(md|sh|json|yaml|txt)' "$agent_file" 2>/dev/null)" || cross_refs=0

	local code_blocks
	code_blocks="$(grep -c '```' "$agent_file" 2>/dev/null)" || code_blocks=0

	local table_rows
	table_rows="$(grep -cE '^\|' "$agent_file" 2>/dev/null)" || table_rows=0

	local nesting_depth
	nesting_depth="$(grep -cE '^#{3,}' "$agent_file" 2>/dev/null)" || nesting_depth=0

	# Scoring: simple < 50 lines, few refs; complex > 120 lines or many refs
	local score=0
	if [[ "$line_count" -gt 120 ]]; then score=$((score + 3)); fi
	if [[ "$line_count" -gt 60 ]]; then score=$((score + 1)); fi
	if [[ "$cross_refs" -gt 10 ]]; then score=$((score + 2)); fi
	if [[ "$cross_refs" -gt 5 ]]; then score=$((score + 1)); fi
	if [[ "$code_blocks" -gt 6 ]]; then score=$((score + 1)); fi
	if [[ "$table_rows" -gt 10 ]]; then score=$((score + 1)); fi
	if [[ "$nesting_depth" -gt 5 ]]; then score=$((score + 1)); fi

	if [[ "$score" -le 2 ]]; then
		echo "simple"
	elif [[ "$score" -le 5 ]]; then
		echo "moderate"
	else
		echo "complex"
	fi
	return 0
}

#######################################
# Run deterministic checks on model output
# Arguments:
#   $1 — model output text
#   $2 — expected JSON (from scenario)
# Output: JSON result on stdout
# Returns: 0=pass, 1=fail, 2=ambiguous (needs adjudication)
#######################################
deterministic_check() {
	local output="$1"
	local expected_json="$2"

	python3 -c "
import sys, json

output = sys.argv[1]
expected = json.loads(sys.argv[2])
output_lower = output.lower()

results = {'pass': True, 'checks': [], 'ambiguous': False}

# contains checks
for kw in expected.get('contains', []):
    found = kw.lower() in output_lower
    results['checks'].append({'type': 'contains', 'value': kw, 'passed': found})
    if not found:
        results['pass'] = False

# not_contains checks
for kw in expected.get('not_contains', []):
    found = kw.lower() in output_lower
    results['checks'].append({'type': 'not_contains', 'value': kw, 'passed': not found})
    if found:
        results['pass'] = False

# action checks
for act in expected.get('action', []):
    found = act.lower() in output_lower
    results['checks'].append({'type': 'action', 'value': act, 'passed': found})
    if not found:
        # Action checks are often ambiguous — model may use synonyms
        results['ambiguous'] = True

# length checks
min_len = expected.get('min_length', 0)
max_len = expected.get('max_length', 999999)
actual_len = len(output)
if min_len > 0:
    passed = actual_len >= min_len
    results['checks'].append({'type': 'min_length', 'value': min_len, 'actual': actual_len, 'passed': passed})
    if not passed:
        results['pass'] = False
if max_len < 999999:
    passed = actual_len <= max_len
    results['checks'].append({'type': 'max_length', 'value': max_len, 'actual': actual_len, 'passed': passed})
    if not passed:
        results['pass'] = False

print(json.dumps(results))
" "$output" "$expected_json" 2>/dev/null || {
		echo '{"pass": false, "checks": [], "ambiguous": true}'
		return 2
	}
	return 0
}

#######################################
# Detect fast-fail escalation triggers
# Arguments:
#   $1 — model output text
#   $2 — fast_fail_triggers JSON array
#   $3 — scenario prompt (for context comparison)
# Output: trigger name if detected, empty if none
# Returns: 0=no trigger, 1=trigger detected
#######################################
detect_fast_fail() {
	local output="$1"
	local triggers_json="$2"
	local prompt="$3"

	python3 -c "
import sys, json

output = sys.argv[1]
triggers = json.loads(sys.argv[2])
prompt = sys.argv[3]
output_lower = output.lower()

detected = []

for trigger in triggers:
    if trigger == 'refusal':
        refusal_phrases = [
            'i don\\'t understand', 'i cannot', 'not able to',
            'i\\'m unable', 'i am unable', 'i\\'m not sure what',
            'could you clarify', 'i need more context'
        ]
        if any(p in output_lower for p in refusal_phrases):
            detected.append('refusal')

    elif trigger == 'confabulation':
        # Check for file paths not in the prompt
        import re
        output_paths = set(re.findall(r'[\\w./\\-]+\\.(?:md|sh|json|yaml|txt)', output))
        prompt_paths = set(re.findall(r'[\\w./\\-]+\\.(?:md|sh|json|yaml|txt)', prompt))
        hallucinated = output_paths - prompt_paths
        # Allow common well-known paths
        known_paths = {'build.txt', 'AGENTS.md', 'TODO.md', 'README.md'}
        hallucinated = hallucinated - known_paths
        if len(hallucinated) > 3:
            detected.append('confabulation')

    elif trigger == 'structural_violation':
        # Detected by action checks in deterministic_check, not here
        pass

    elif trigger == 'disengagement':
        if len(output.strip()) < 50:
            detected.append('disengagement')

if detected:
    print(','.join(detected))
    sys.exit(1)
else:
    print('')
    sys.exit(0)
" "$output" "$triggers_json" "$prompt" 2>/dev/null
	return $?
}

#######################################
# Run a single scenario against a model tier
# Arguments:
#   $1 — agent file path
#   $2 — scenario JSON
#   $3 — model tier (haiku|sonnet|opus)
# Output: JSON result on stdout
# Returns: 0=pass, 1=fail
#######################################
run_scenario() {
	local agent_file="$1"
	local scenario_json="$2"
	local tier="$3"

	local scenario_name
	scenario_name=$(echo "$scenario_json" | jq -r '.name // "unnamed"')
	local prompt
	prompt=$(echo "$scenario_json" | jq -r '.prompt // ""')
	local expected_json
	expected_json=$(echo "$scenario_json" | jq -c '.expected // {}')
	local fast_fail_json
	fast_fail_json=$(echo "$scenario_json" | jq -c '.fast_fail_triggers // []')

	log_info "Running scenario '$scenario_name' at tier=$tier"

	# Build the full prompt with agent file context
	local agent_content
	if [[ -f "${REPO_ROOT}/${agent_file}" ]]; then
		agent_content=$(cat "${REPO_ROOT}/${agent_file}" 2>/dev/null || echo "")
	else
		log_error "Agent file not found: ${REPO_ROOT}/${agent_file}"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"error","reason":"agent_file_not_found"}'
		return 1
	fi

	local full_prompt
	full_prompt="You are reading the following agent instruction file. Follow its instructions precisely.

--- BEGIN AGENT FILE: ${agent_file} ---
${agent_content}
--- END AGENT FILE ---

Now respond to this task:
${prompt}

Respond concisely and precisely. Follow the agent file instructions exactly."

	# Call the model via ai-research-helper.sh
	local model_output
	model_output=$("${SCRIPT_DIR}/ai-research-helper.sh" --prompt "$full_prompt" --model "$tier" --max-tokens 500 2>/dev/null) || {
		log_error "Model call failed for tier=$tier"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"error","reason":"model_call_failed"}'
		return 1
	}

	# 1. Check fast-fail triggers
	local ff_result
	ff_result=$(detect_fast_fail "$model_output" "$fast_fail_json" "$prompt" 2>/dev/null) || true
	if [[ -n "$ff_result" ]]; then
		log_fail "Fast-fail trigger: $ff_result (scenario=$scenario_name, tier=$tier)"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"fast_fail","trigger":"'"$ff_result"'","output_preview":"'"$(echo "$model_output" | head -c 200 | tr '\n' ' ')"'"}'
		return 1
	fi

	# 2. Run deterministic checks
	local det_result
	det_result=$(deterministic_check "$model_output" "$expected_json" 2>/dev/null) || true
	local det_pass
	det_pass=$(echo "$det_result" | jq -r '.pass // false')
	local det_ambiguous
	det_ambiguous=$(echo "$det_result" | jq -r '.ambiguous // false')

	if [[ "$det_pass" == "true" && "$det_ambiguous" != "true" ]]; then
		log_pass "Deterministic pass (scenario=$scenario_name, tier=$tier)"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"pass","method":"deterministic","checks":'"$det_result"'}'
		return 0
	fi

	if [[ "$det_pass" == "false" && "$det_ambiguous" != "true" ]]; then
		log_fail "Deterministic fail (scenario=$scenario_name, tier=$tier)"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"fail","method":"deterministic","checks":'"$det_result"',"output_preview":"'"$(echo "$model_output" | head -c 200 | tr '\n' ' ')"'"}'
		return 1
	fi

	# 3. Ambiguous — needs adjudication (haiku self-check or sonnet judge)
	log_info "Ambiguous result, running adjudication (scenario=$scenario_name, tier=$tier)"
	local adjudication_prompt
	adjudication_prompt="Compare this model output against the expected behavior. Answer PASS or FAIL with a one-line reason.

Expected behavior: ${expected_json}

Model output:
${model_output}

Answer format: PASS: <reason> or FAIL: <reason>"

	local adjudication_tier="haiku"
	if [[ "$tier" == "haiku" ]]; then
		adjudication_tier="haiku" # haiku self-check first
	else
		adjudication_tier="sonnet"
	fi

	local adj_result
	adj_result=$("${SCRIPT_DIR}/ai-research-helper.sh" --prompt "$adjudication_prompt" --model "$adjudication_tier" --max-tokens 100 2>/dev/null) || {
		log_error "Adjudication call failed"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"ambiguous","method":"adjudication_failed"}'
		return 1
	}

	local adj_lower
	adj_lower=$(echo "$adj_result" | tr '[:upper:]' '[:lower:]')
	if echo "$adj_lower" | grep -q "^pass"; then
		log_pass "Adjudication pass (scenario=$scenario_name, tier=$tier)"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"pass","method":"adjudication","adjudicator":"'"$adjudication_tier"'"}'
		return 0
	else
		log_fail "Adjudication fail (scenario=$scenario_name, tier=$tier)"
		echo '{"scenario":"'"$scenario_name"'","tier":"'"$tier"'","result":"fail","method":"adjudication","adjudicator":"'"$adjudication_tier"'","reason":"'"$(echo "$adj_result" | head -c 200 | tr '\n' ' ')"'"}'
		return 1
	fi
}

#######################################
# Test a single scenario file across tiers with escalation
# Arguments: $1 — path to scenario YAML file
# Output: JSON results on stdout
# Returns: 0=success
#######################################
cmd_test() {
	local yaml_file="$1"

	local scenario_data
	scenario_data=$(parse_yaml "$yaml_file") || return 1

	local agent_file
	agent_file=$(echo "$scenario_data" | jq -r '.file // ""')
	local expected_tier
	expected_tier=$(echo "$scenario_data" | jq -r '.tier_minimum // "haiku"')
	local scenario_count
	scenario_count=$(echo "$scenario_data" | jq '.scenarios | length')

	log_info "Testing: $agent_file (expected tier_minimum=$expected_tier, scenarios=$scenario_count)"

	# Pre-filter
	local complexity
	complexity=$(pre_filter "${REPO_ROOT}/${agent_file}")
	log_info "Structural complexity: $complexity"

	local all_results="[]"
	local actual_tier_minimum="haiku"

	local i=0
	while [[ "$i" -lt "$scenario_count" ]]; do
		local scenario_json
		scenario_json=$(echo "$scenario_data" | jq -c ".scenarios[$i]")

		# Start at haiku, escalate on failure
		local current_tier_order=1
		local scenario_passed=false
		local scenario_tier="haiku"

		while [[ "$current_tier_order" -le 3 ]]; do
			local tier_name
			tier_name=$(tier_name "$current_tier_order")

			local result
			result=$(run_scenario "$agent_file" "$scenario_json" "$tier_name" 2>/dev/null) || true
			local result_status
			result_status=$(echo "$result" | jq -r '.result // "error"')

			all_results=$(echo "$all_results" | jq --argjson r "$result" '. + [$r]')

			if [[ "$result_status" == "pass" ]]; then
				scenario_passed=true
				scenario_tier="$tier_name"
				break
			fi

			# Escalate
			current_tier_order=$((current_tier_order + 1))
		done

		if [[ "$scenario_passed" == "true" ]]; then
			# Update actual minimum tier
			local scenario_order
			scenario_order=$(tier_order "$scenario_tier")
			local current_min_order
			current_min_order=$(tier_order "$actual_tier_minimum")
			if [[ "$scenario_order" -gt "$current_min_order" ]]; then
				actual_tier_minimum="$scenario_tier"
			fi
		else
			actual_tier_minimum="opus" # Failed at all tiers — needs opus or test is bad
		fi

		i=$((i + 1))
	done

	# Final summary
	local summary
	summary=$(jq -n \
		--arg file "$agent_file" \
		--arg expected "$expected_tier" \
		--arg actual "$actual_tier_minimum" \
		--arg complexity "$complexity" \
		--argjson results "$all_results" \
		'{file: $file, expected_tier: $expected, actual_tier: $actual, complexity: $complexity, results: $results}')

	echo "$summary"

	if [[ "$actual_tier_minimum" == "$expected_tier" ]]; then
		log_pass "RESULT: $agent_file — tier_minimum=$actual_tier_minimum (matches expected)"
	else
		log_info "RESULT: $agent_file — tier_minimum=$actual_tier_minimum (expected=$expected_tier)"
	fi
	return 0
}

#######################################
# Sweep: run all test scenarios
# Output: JSON array of results on stdout
# Returns: 0=success
#######################################
cmd_sweep() {
	if [[ ! -d "$TESTS_DIR" ]]; then
		log_error "Tests directory not found: $TESTS_DIR"
		return 1
	fi

	local all_results="[]"
	local pass_count=0
	local fail_count=0
	local total_count=0

	while IFS= read -r yaml_file; do
		total_count=$((total_count + 1))
		local result
		result=$(cmd_test "$yaml_file" 2>/dev/null) || true

		if [[ -n "$result" ]]; then
			all_results=$(echo "$all_results" | jq --argjson r "$result" '. + [$r]')
			local actual
			actual=$(echo "$result" | jq -r '.actual_tier // "unknown"')
			local expected
			expected=$(echo "$result" | jq -r '.expected_tier // "unknown"')
			if [[ "$actual" == "$expected" ]]; then
				pass_count=$((pass_count + 1))
			else
				fail_count=$((fail_count + 1))
			fi
		fi
	done < <(find "$TESTS_DIR" -name '*.yaml' -type f | sort)

	log_info "Sweep complete: $total_count files, $pass_count matched expected, $fail_count mismatched"

	jq -n \
		--argjson results "$all_results" \
		--arg total "$total_count" \
		--arg pass "$pass_count" \
		--arg fail "$fail_count" \
		'{summary: {total: ($total|tonumber), matched: ($pass|tonumber), mismatched: ($fail|tonumber)}, results: $results}'
	return 0
}

#######################################
# Report: generate human-readable summary
# Returns: 0=success
#######################################
cmd_report() {
	log_info "Generating comprehension benchmark report..."

	local results_file="${RESULTS_DIR}/latest-sweep.json"
	if [[ ! -f "$results_file" ]]; then
		log_info "No sweep results found. Running sweep first..."
		mkdir -p "$RESULTS_DIR"
		cmd_sweep >"$results_file" 2>/dev/null || true
	fi

	if [[ ! -f "$results_file" ]]; then
		log_error "No results to report"
		return 1
	fi

	echo "# Comprehension Benchmark Report"
	echo ""
	echo "| File | Complexity | Expected Tier | Actual Tier | Match |"
	echo "|------|-----------|---------------|-------------|-------|"

	jq -r '.results[] | "| \(.file) | \(.complexity) | \(.expected_tier) | \(.actual_tier) | \(if .expected_tier == .actual_tier then "yes" else "NO" end) |"' "$results_file" 2>/dev/null || true

	echo ""
	jq -r '"**Summary:** \(.summary.total) files tested, \(.summary.matched) matched expected tier, \(.summary.mismatched) mismatched"' "$results_file" 2>/dev/null || true
	return 0
}

#######################################
# Update simplification-state.json with tier_minimum results
# Returns: 0=success, 1=error
#######################################
cmd_update_state() {
	local results_file="${RESULTS_DIR}/latest-sweep.json"
	if [[ ! -f "$results_file" ]]; then
		log_error "No sweep results found. Run 'sweep' first."
		return 1
	fi

	if [[ ! -f "$STATE_FILE" ]]; then
		log_error "State file not found: $STATE_FILE"
		return 1
	fi

	# Update state file with tier_minimum for each tested file
	python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    results = json.load(f)

with open(sys.argv[2]) as f:
    state = json.load(f)

updated = 0
for r in results.get('results', []):
    file_path = r.get('file', '')
    tier = r.get('actual_tier', '')
    if file_path and tier and file_path in state.get('files', {}):
        state['files'][file_path]['tier_minimum'] = tier
        updated += 1

with open(sys.argv[2], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')

print(f'Updated {updated} entries in simplification-state.json')
" "$results_file" "$STATE_FILE" || {
		log_error "Failed to update state file"
		return 1
	}
	return 0
}

#######################################
# Pre-filter command: structural heuristics only
# Arguments: $1 — agent file path
# Returns: 0=success
#######################################
cmd_pre_filter() {
	local agent_file="$1"
	local complexity
	complexity=$(pre_filter "$agent_file")

	local line_count
	line_count="$(wc -l <"$agent_file" 2>/dev/null)" || line_count=0
	line_count="${line_count// /}"
	local cross_refs
	cross_refs="$(grep -cE '\.(md|sh|json|yaml|txt)' "$agent_file" 2>/dev/null)" || cross_refs=0

	echo "File: $agent_file"
	echo "Lines: $line_count"
	echo "Cross-references: $cross_refs"
	echo "Complexity: $complexity"

	case "$complexity" in
	simple) echo "Predicted tier: haiku" ;;
	moderate) echo "Predicted tier: sonnet" ;;
	complex) echo "Predicted tier: opus" ;;
	*) echo "Predicted tier: unknown" ;;
	esac
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	test)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: $0 test <scenario.yaml>"
			return 1
		fi
		cmd_test "$1"
		;;
	sweep)
		cmd_sweep
		;;
	report)
		cmd_report
		;;
	update-state)
		cmd_update_state
		;;
	pre-filter)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: $0 pre-filter <agent-file.md>"
			return 1
		fi
		cmd_pre_filter "$1"
		;;
	help | --help | -h)
		echo "Usage: $0 {test|sweep|report|update-state|pre-filter|help}"
		echo ""
		echo "Commands:"
		echo "  test <file.yaml>      Run comprehension tests for one scenario file"
		echo "  sweep                 Run all tests in .agents/tests/comprehension/"
		echo "  report                Generate human-readable summary"
		echo "  update-state          Write tier_minimum to simplification-state.json"
		echo "  pre-filter <file.md>  Structural heuristics only (no model calls)"
		echo "  help                  Show this help"
		return 0
		;;
	*)
		log_error "Unknown command: $command"
		echo "Usage: $0 {test|sweep|report|update-state|pre-filter|help}" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"

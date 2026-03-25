#!/usr/bin/env bash
# email-triage-helper.sh - Inbox triage engine for category, urgency, phishing, and action routing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../configs/email-actions-config.json"
readonly PROMPT_GUARD_HELPER="${SCRIPT_DIR}/prompt-guard-helper.sh"
readonly AI_RESEARCH_HELPER="${SCRIPT_DIR}/ai-research-helper.sh"
readonly CLAIM_TASK_HELPER="${SCRIPT_DIR}/claim-task-id.sh"
readonly DEFAULT_DKIM_SELECTORS="google google1 google2 selector1 selector2 k1 k2 s1 s2 default dkim"

EMAIL_ACTIONS_CONFIG="${DEFAULT_CONFIG_FILE}"
CREATE_TODOS="false"
TODO_REPO_PATH="$PWD"

require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Missing required command: $cmd"
		return 1
	fi
	return 0
}

read_json_file() {
	local file_path="$1"
	if [[ ! -f "$file_path" ]]; then
		print_error "Input file not found: $file_path"
		return 1
	fi
	jq -c '.' "$file_path"
	return $?
}

extract_field() {
	local json_input="$1"
	local jq_filter="$2"
	local fallback="${3:-}"

	local value
	value=$(printf '%s' "$json_input" | jq -r "$jq_filter // empty" 2>/dev/null || true)
	if [[ -z "$value" || "$value" == "null" ]]; then
		printf '%s' "$fallback"
		return 0
	fi
	printf '%s' "$value"
	return 0
}

extract_domain() {
	local from_value="$1"
	local domain
	domain=$(printf '%s' "$from_value" | sed -E 's/.*<([^>]+)>.*/\1/' | awk -F'@' '{print tolower($NF)}')
	if [[ -z "$domain" || "$domain" == "$from_value" ]]; then
		domain=$(printf '%s' "$from_value" | awk -F'@' '{print tolower($NF)}')
	fi
	printf '%s' "$domain"
	return 0
}

config_has_sender() {
	local list_name="$1"
	local sender="$2"
	local sender_domain="$3"

	if [[ ! -f "$EMAIL_ACTIONS_CONFIG" ]]; then
		return 1
	fi

	local sender_lower domain_lower
	sender_lower=$(printf '%s' "$sender" | tr '[:upper:]' '[:lower:]')
	domain_lower=$(printf '%s' "$sender_domain" | tr '[:upper:]' '[:lower:]')

	if jq -e --arg s "$sender_lower" --arg d "$domain_lower" \
		".${list_name} // [] | map(ascii_downcase) | any(. == \$s or . == \$d or (startswith(\"@\") and . == (\"@\" + \$d)))" \
		"$EMAIL_ACTIONS_CONFIG" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

check_spf() {
	local domain="$1"
	if ! command -v dig >/dev/null 2>&1; then
		printf 'unknown'
		return 0
	fi
	if dig TXT "$domain" +short 2>/dev/null | grep -iq 'v=spf1'; then
		printf 'pass'
	else
		printf 'fail'
	fi
	return 0
}

check_dmarc() {
	local domain="$1"
	if ! command -v dig >/dev/null 2>&1; then
		printf 'unknown'
		return 0
	fi
	if dig TXT "_dmarc.${domain}" +short 2>/dev/null | grep -iq 'v=dmarc1'; then
		printf 'pass'
	else
		printf 'fail'
	fi
	return 0
}

check_dkim() {
	local domain="$1"
	local selectors="$DEFAULT_DKIM_SELECTORS"

	if ! command -v dig >/dev/null 2>&1; then
		printf 'unknown'
		return 0
	fi

	local selector
	for selector in $selectors; do
		if dig TXT "${selector}._domainkey.${domain}" +short 2>/dev/null | grep -q '.'; then
			printf 'pass'
			return 0
		fi
	done

	printf 'fail'
	return 0
}

prompt_guard_check() {
	local content="$1"

	if [[ ! -x "$PROMPT_GUARD_HELPER" ]]; then
		print_warning "prompt-guard-helper.sh not found; continuing without scan"
		printf 'warn'
		return 0
	fi

	if "$PROMPT_GUARD_HELPER" check "$content" >/dev/null 2>&1; then
		printf 'allow'
		return 0
	fi

	local exit_code="$?"
	if [[ "$exit_code" -eq 2 ]]; then
		printf 'warn'
		return 0
	fi

	printf 'block'
	return 0
}

detect_category_heuristic() {
	local subject="$1"
	local body="$2"
	local from_value="$3"

	local text
	text=$(printf '%s %s %s' "$subject" "$body" "$from_value" | tr '[:upper:]' '[:lower:]')

	if printf '%s' "$text" | grep -Eiq 'invoice|receipt|order|payment|billing|subscription|renewal'; then
		printf 'Transactions|0.82'
		return 0
	fi

	if printf '%s' "$text" | grep -Eiq 'newsletter|sale|discount|offer|webinar|promo|unsubscribe'; then
		printf 'Promotions|0.80'
		return 0
	fi

	if printf '%s' "$text" | grep -Eiq 'notification|alert|digest|report|status|summary|monitor'; then
		printf 'Updates|0.78'
		return 0
	fi

	if printf '%s' "$text" | grep -Eiq 'urgent transfer|crypto|wire now|verify account immediately|password reset requested by unknown'; then
		printf 'Junk/Spam|0.85'
		return 0
	fi

	printf 'Primary|0.62'
	return 0
}

detect_urgency_heuristic() {
	local subject="$1"
	local body="$2"
	local text
	text=$(printf '%s %s' "$subject" "$body" | tr '[:upper:]' '[:lower:]')

	if printf '%s' "$text" | grep -Eiq 'critical|asap|today|immediate|outage|incident|security alert'; then
		printf 'Critical'
		return 0
	fi

	if printf '%s' "$text" | grep -Eiq 'this week|deadline|due|expir|renewal|action required|follow up'; then
		printf 'High'
		return 0
	fi

	if printf '%s' "$text" | grep -Eiq 'fyi|newsletter|digest|announcement|for your information'; then
		printf 'Low'
		return 0
	fi

	printf 'Normal'
	return 0
}

detect_report_type() {
	local subject="$1"
	local body="$2"
	local text
	text=$(printf '%s %s' "$subject" "$body" | tr '[:upper:]' '[:lower:]')

	if printf '%s' "$text" | grep -Eiq 'seo|ranking|search console|backlink'; then
		printf 'seo'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'expiry|expir|renewal|domain|ssl'; then
		printf 'expiry-renewal'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'optimization|recommendation|improvement|opportunity score'; then
		printf 'optimization'
		return 0
	fi
	printf 'none'
	return 0
}

detect_emotion() {
	local subject="$1"
	local body="$2"
	local text
	text=$(printf '%s %s' "$subject" "$body" | tr '[:upper:]' '[:lower:]')

	if printf '%s' "$text" | grep -Eiq 'angry|furious|unacceptable|outrage'; then
		printf 'angry'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'frustrat|disappointed|upset'; then
		printf 'frustrated'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'worried|concern|anxious'; then
		printf 'anxious'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'thank|appreciate|grateful'; then
		printf 'appreciative'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'excited|great news|looking forward'; then
		printf 'excited'
		return 0
	fi
	if printf '%s' "$text" | grep -Eiq 'question|clarify|help me understand'; then
		printf 'curious'
		return 0
	fi
	printf 'neutral'
	return 0
}

ai_classify() {
	local message_json="$1"
	local model="$2"

	if [[ ! -x "$AI_RESEARCH_HELPER" ]]; then
		printf '{}'
		return 0
	fi

	local prompt
	prompt=$(
		cat <<EOF
Classify this email and return only valid JSON.

Schema:
{
  "category": "Primary|Transactions|Updates|Promotions|Junk/Spam",
  "urgency": "Critical|High|Normal|Low",
  "emotion": "neutral|curious|confused|frustrated|angry|anxious|excited|appreciative",
  "is_report": true|false,
  "report_type": "seo|expiry-renewal|optimization|none",
  "is_opportunity": true|false,
  "is_phishing": true|false,
  "confidence": 0.0,
  "reason": "one sentence"
}

Email JSON:
$message_json
EOF
	)

	local ai_raw
	ai_raw=$("$AI_RESEARCH_HELPER" --prompt "$prompt" --model "$model" --max-tokens 260 2>/dev/null || true)
	if [[ -z "$ai_raw" ]]; then
		printf '{}'
		return 0
	fi

	python3 - "$ai_raw" <<'PY'
import json
import re
import sys

raw = sys.argv[1]
raw = raw.strip()
if not raw:
    print("{}")
    raise SystemExit(0)

try:
    obj = json.loads(raw)
    print(json.dumps(obj))
    raise SystemExit(0)
except Exception:
    pass

match = re.search(r"\{[\s\S]*\}", raw)
if not match:
    print("{}")
    raise SystemExit(0)

snippet = match.group(0)
try:
    obj = json.loads(snippet)
    print(json.dumps(obj))
except Exception:
    print("{}")
PY
	return 0
}

create_task_from_email() {
	local subject="$1"
	local urgency="$2"
	local message_id="$3"

	if [[ "$CREATE_TODOS" != "true" ]]; then
		printf ''
		return 0
	fi

	if [[ ! -x "$CLAIM_TASK_HELPER" ]]; then
		print_warning "claim-task-id.sh not found; skipping task creation"
		printf ''
		return 0
	fi

	local priority="medium"
	if [[ "$urgency" == "Critical" ]]; then
		priority="high"
	elif [[ "$urgency" == "High" ]]; then
		priority="high"
	fi

	local title="Email: ${subject}"
	local output
	output=$(
		"$CLAIM_TASK_HELPER" \
			--repo-path "$TODO_REPO_PATH" \
			--title "$title" \
			--description "Created by email-triage-helper from message ${message_id}" \
			--labels "email,triage,priority-${priority}" 2>/dev/null || true
	)

	local task_id
	task_id=$(printf '%s' "$output" | grep -Eo 't[0-9]+' | head -1 || true)
	printf '%s' "$task_id"
	return 0
}

# _triage_parse_message: extract and classify fields from a message JSON object.
# Outputs a tab-delimited record:
#   from\tsubject\tmessage_id\tsender_domain\tguard_state\tcategory\theuristic_conf\turgency\treport_type\temotion\tis_opportunity
_triage_parse_message() {
	local message_json="$1"

	local from_value subject body message_id
	from_value=$(extract_field "$message_json" '.from // .from_email' '')
	subject=$(extract_field "$message_json" '.subject' '(no subject)')
	body=$(extract_field "$message_json" '.text // .body // .plain // .content' '')
	message_id=$(extract_field "$message_json" '.message_id // .id' 'unknown')

	local sender_domain
	sender_domain=$(extract_domain "$from_value")

	local guard_state
	guard_state=$(prompt_guard_check "${subject}\n\n${body}")

	local category_and_conf category heuristic_conf urgency report_type emotion
	category_and_conf=$(detect_category_heuristic "$subject" "$body" "$from_value")
	category=${category_and_conf%%|*}
	heuristic_conf=${category_and_conf##*|}
	urgency=$(detect_urgency_heuristic "$subject" "$body")
	report_type=$(detect_report_type "$subject" "$body")
	emotion=$(detect_emotion "$subject" "$body")

	local is_opportunity="false"
	if printf '%s %s' "$subject" "$body" | tr '[:upper:]' '[:lower:]' |
		grep -Eiq 'opportunity|partnership|proposal|lead|collaborat|intro'; then
		is_opportunity="true"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$from_value" "$subject" "$message_id" "$sender_domain" \
		"$guard_state" "$category" "$heuristic_conf" "$urgency" "$report_type" \
		"$emotion" "$is_opportunity"
	return 0
}

# _triage_check_dns_auth: run SPF/DKIM/DMARC checks and derive phishing flag.
# Outputs a tab-delimited record: spf|dkim|dmarc|is_phishing
_triage_check_dns_auth() {
	local sender_domain="$1"
	local guard_state="$2"

	local spf_result dkim_result dmarc_result
	spf_result=$(check_spf "$sender_domain")
	dkim_result=$(check_dkim "$sender_domain")
	dmarc_result=$(check_dmarc "$sender_domain")

	local is_phishing="false"
	if [[ "$spf_result" == "fail" || "$dkim_result" == "fail" || "$dmarc_result" == "fail" ]]; then
		is_phishing="true"
	fi
	if [[ "$guard_state" == "block" ]]; then
		is_phishing="true"
	fi

	printf '%s\t%s\t%s\t%s' "$spf_result" "$dkim_result" "$dmarc_result" "$is_phishing"
	return 0
}

# _triage_apply_ai_overrides: merge AI classification results over heuristic values.
# Outputs a tab-delimited record:
#   category|urgency|emotion|is_report|report_type|is_opportunity|is_phishing|ai_confidence
_triage_apply_ai_overrides() {
	local ai_json="$1"
	local category="$2"
	local urgency="$3"
	local emotion="$4"
	local is_report="$5"
	local report_type="$6"
	local is_opportunity="$7"
	local is_phishing="$8"

	local ai_category ai_urgency ai_emotion ai_is_report ai_report_type
	local ai_is_opportunity ai_is_phishing ai_confidence
	ai_category=$(extract_field "$ai_json" '.category' '')
	ai_urgency=$(extract_field "$ai_json" '.urgency' '')
	ai_emotion=$(extract_field "$ai_json" '.emotion' '')
	ai_is_report=$(extract_field "$ai_json" '.is_report' '')
	ai_report_type=$(extract_field "$ai_json" '.report_type' '')
	ai_is_opportunity=$(extract_field "$ai_json" '.is_opportunity' '')
	ai_is_phishing=$(extract_field "$ai_json" '.is_phishing' '')
	ai_confidence=$(extract_field "$ai_json" '.confidence' '0.0')

	if [[ -n "$ai_category" ]]; then category="$ai_category"; fi
	if [[ -n "$ai_urgency" ]]; then urgency="$ai_urgency"; fi
	if [[ -n "$ai_emotion" ]]; then emotion="$ai_emotion"; fi
	if [[ "$ai_is_report" == "true" || "$ai_is_report" == "false" ]]; then
		is_report="$ai_is_report"
	fi
	if [[ -n "$ai_report_type" ]]; then report_type="$ai_report_type"; fi
	if [[ "$ai_is_opportunity" == "true" || "$ai_is_opportunity" == "false" ]]; then
		is_opportunity="$ai_is_opportunity"
	fi
	if [[ "$ai_is_phishing" == "true" || "$ai_is_phishing" == "false" ]]; then
		is_phishing="$ai_is_phishing"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$category" "$urgency" "$emotion" "$is_report" \
		"$report_type" "$is_opportunity" "$is_phishing" "$ai_confidence"
	return 0
}

# _triage_emit_result: build and print the final triage JSON object.
_triage_emit_result() {
	local message_id="$1" from_value="$2" sender_domain="$3" subject="$4"
	local category="$5" urgency="$6" emotion="$7"
	local is_report="$8" report_type="$9" needs_report_attention="${10}"
	local is_opportunity="${11}" is_phishing="${12}"
	local trusted_report_sender="${13}" trusted_opportunity_sender="${14}"
	local guard_state="${15}" spf_result="${16}" dkim_result="${17}" dmarc_result="${18}"
	local selected_model="${19}" heuristic_conf="${20}" ai_confidence="${21}"
	local actionable="${22}" created_task_id="${23}"

	jq -n \
		--arg message_id "$message_id" \
		--arg from "$from_value" \
		--arg sender_domain "$sender_domain" \
		--arg subject "$subject" \
		--arg category "$category" \
		--arg urgency "$urgency" \
		--arg emotion "$emotion" \
		--arg report_type "$report_type" \
		--arg selected_model "$selected_model" \
		--arg prompt_guard "$guard_state" \
		--arg spf "$spf_result" \
		--arg dkim "$dkim_result" \
		--arg dmarc "$dmarc_result" \
		--arg heuristic_confidence "$heuristic_conf" \
		--arg ai_confidence "$ai_confidence" \
		--arg created_task_id "$created_task_id" \
		--argjson is_report "$is_report" \
		--argjson needs_report_attention "$needs_report_attention" \
		--argjson trusted_report_sender "$trusted_report_sender" \
		--argjson trusted_opportunity_sender "$trusted_opportunity_sender" \
		--argjson is_opportunity "$is_opportunity" \
		--argjson is_phishing "$is_phishing" \
		--argjson actionable "$actionable" \
		'{
			message_id: $message_id,
			from: $from,
			sender_domain: $sender_domain,
			subject: $subject,
			category: $category,
			urgency: $urgency,
			emotion: $emotion,
			is_report: $is_report,
			report_type: $report_type,
			needs_report_attention: $needs_report_attention,
			is_opportunity: $is_opportunity,
			is_phishing: $is_phishing,
			trusted_report_sender: $trusted_report_sender,
			trusted_opportunity_sender: $trusted_opportunity_sender,
			prompt_guard: $prompt_guard,
			dns_auth: {
				spf: $spf,
				dkim: $dkim,
				dmarc: $dmarc
			},
			model: {
				selected: $selected_model,
				heuristic_confidence: ($heuristic_confidence | tonumber),
				ai_confidence: ($ai_confidence | tonumber? // 0)
			},
			actionable: $actionable,
			created_task_id: (if $created_task_id == "" then null else $created_task_id end)
		}'
	return 0
}

triage_single() {
	local message_json="$1"

	# Phase 1: parse message fields and run heuristic classifiers
	local parsed_fields
	parsed_fields=$(_triage_parse_message "$message_json")
	local from_value subject message_id sender_domain guard_state
	local category heuristic_conf urgency report_type emotion is_opportunity
	IFS=$'\t' read -r from_value subject message_id sender_domain \
		guard_state category heuristic_conf urgency report_type \
		emotion is_opportunity \
		<<<"$parsed_fields"

	# Derive boolean flags from heuristic results
	local is_report="false" needs_report_attention="false"
	if [[ "$report_type" != "none" ]]; then
		is_report="true"
		if [[ "$urgency" == "Critical" || "$urgency" == "High" ]]; then
			needs_report_attention="true"
		fi
	fi

	local trusted_report_sender="false" trusted_opportunity_sender="false"
	if config_has_sender "trusted_report_senders" "$from_value" "$sender_domain"; then
		trusted_report_sender="true"
	fi
	if config_has_sender "trusted_opportunity_senders" "$from_value" "$sender_domain"; then
		trusted_opportunity_sender="true"
	fi

	# Phase 2: DNS authentication checks
	local dns_fields
	dns_fields=$(_triage_check_dns_auth "$sender_domain" "$guard_state")
	local spf_result dkim_result dmarc_result is_phishing
	IFS=$'\t' read -r spf_result dkim_result dmarc_result is_phishing <<<"$dns_fields"

	# Phase 3: AI classification (skipped when guard blocks)
	local selected_model="haiku"
	if [[ "$heuristic_conf" == "0.62" || "$guard_state" == "warn" ]]; then
		selected_model="sonnet"
	fi

	local ai_json="{}"
	if [[ "$guard_state" != "block" ]]; then
		ai_json=$(ai_classify "$message_json" "$selected_model")
	fi

	local merged_fields ai_confidence
	merged_fields=$(_triage_apply_ai_overrides \
		"$ai_json" "$category" "$urgency" "$emotion" \
		"$is_report" "$report_type" "$is_opportunity" "$is_phishing")
	IFS=$'\t' read -r category urgency emotion is_report \
		report_type is_opportunity is_phishing ai_confidence <<<"$merged_fields"

	# Phase 4: actionability and task creation
	local actionable="false"
	if [[ "$is_phishing" != "true" ]] &&
		[[ "$urgency" == "Critical" || "$urgency" == "High" ||
			"$is_report" == "true" || "$is_opportunity" == "true" ]]; then
		actionable="true"
	fi

	local created_task_id=""
	if [[ "$actionable" == "true" ]]; then
		created_task_id=$(create_task_from_email "$subject" "$urgency" "$message_id")
	fi

	# Phase 5: emit result
	_triage_emit_result \
		"$message_id" "$from_value" "$sender_domain" "$subject" \
		"$category" "$urgency" "$emotion" \
		"$is_report" "$report_type" "$needs_report_attention" \
		"$is_opportunity" "$is_phishing" \
		"$trusted_report_sender" "$trusted_opportunity_sender" \
		"$guard_state" "$spf_result" "$dkim_result" "$dmarc_result" \
		"$selected_model" "$heuristic_conf" "$ai_confidence" \
		"$actionable" "$created_task_id"
	return 0
}

run_triage_command() {
	local message_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--message-file)
			message_file="$2"
			shift 2
			;;
		--config)
			EMAIL_ACTIONS_CONFIG="$2"
			shift 2
			;;
		--create-todos)
			CREATE_TODOS="true"
			shift
			;;
		--repo-path)
			TODO_REPO_PATH="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$message_file" ]]; then
		print_error "triage requires --message-file <file>"
		return 1
	fi

	local message_json
	message_json=$(read_json_file "$message_file") || return 1
	triage_single "$message_json"
	return 0
}

run_batch_command() {
	local input_file=""
	local limit="0"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--input)
			input_file="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--config)
			EMAIL_ACTIONS_CONFIG="$2"
			shift 2
			;;
		--create-todos)
			CREATE_TODOS="true"
			shift
			;;
		--repo-path)
			TODO_REPO_PATH="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$input_file" ]]; then
		print_error "batch requires --input <json-file>"
		return 1
	fi

	if [[ ! -f "$input_file" ]]; then
		print_error "Input file not found: $input_file"
		return 1
	fi

	local total_count
	total_count=$(jq 'if type=="array" then length else 0 end' "$input_file" 2>/dev/null || echo "0")
	if [[ "$total_count" -eq 0 ]]; then
		print_error "batch input must be a JSON array"
		return 1
	fi

	local max_count="$total_count"
	if [[ "$limit" -gt 0 && "$limit" -lt "$total_count" ]]; then
		max_count="$limit"
	fi

	local i=0
	local results='[]'
	while IFS= read -r row; do
		i=$((i + 1))
		if [[ "$i" -gt "$max_count" ]]; then
			break
		fi

		local result
		result=$(triage_single "$row")
		results=$(jq -c --argjson next "$result" '. + [$next]' <<<"$results")
	done < <(jq -c '.[]' "$input_file")

	jq -n --argjson total "$total_count" --argjson processed "$max_count" --argjson results "$results" \
		'{total_messages: $total, processed_messages: $processed, results: $results}'
	return 0
}

run_check_sender_command() {
	local from_value=""
	local sender_domain=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--from)
			from_value="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$from_value" ]]; then
		print_error "check-sender requires --from <email>"
		return 1
	fi

	sender_domain=$(extract_domain "$from_value")

	local spf_result dkim_result dmarc_result
	spf_result=$(check_spf "$sender_domain")
	dkim_result=$(check_dkim "$sender_domain")
	dmarc_result=$(check_dmarc "$sender_domain")

	jq -n \
		--arg from "$from_value" \
		--arg sender_domain "$sender_domain" \
		--arg spf "$spf_result" \
		--arg dkim "$dkim_result" \
		--arg dmarc "$dmarc_result" \
		'{from: $from, sender_domain: $sender_domain, spf: $spf, dkim: $dkim, dmarc: $dmarc}'
	return 0
}

show_help() {
	cat <<'EOF'
Usage:
  email-triage-helper.sh triage --message-file <file> [--config <path>] [--create-todos] [--repo-path <path>]
  email-triage-helper.sh batch --input <file> [--limit <n>] [--config <path>] [--create-todos] [--repo-path <path>]
  email-triage-helper.sh check-sender --from <email>
  email-triage-helper.sh help

Commands:
  triage        Classify one email message JSON object
  batch         Classify an array of message JSON objects
  check-sender  Run SPF/DKIM/DMARC checks for a sender

Output:
  JSON object suitable for downstream automation

Notes:
  - Prompt injection scanning is enforced via prompt-guard-helper.sh before AI classification
  - Model routing uses haiku for bulk and sonnet for ambiguous/suspicious cases
  - Task creation uses claim-task-id.sh when --create-todos is set
EOF
	return 0
}

main() {
	require_cmd jq || return 1

	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command" in
	triage)
		run_triage_command "$@"
		return $?
		;;
	batch)
		run_batch_command "$@"
		return $?
		;;
	check-sender)
		run_check_sender_command "$@"
		return $?
		;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"

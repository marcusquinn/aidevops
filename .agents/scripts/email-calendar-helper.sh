#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh"

readonly AI_RESEARCH_HELPER_DEFAULT="${SCRIPT_DIR}/ai-research-helper.sh"
readonly DEFAULT_TIMEZONE="${TZ:-UTC}"

show_help() {
	cat <<'EOF'
email-calendar-helper.sh - Calendar event creation from email threads

Usage:
  email-calendar-helper.sh extract [--thread-file <path> | --thread-text <text> | --stdin]
                                   [--participants <csv>] [--timezone <tz>] [--output <path>]
                                   [--ai-helper <path>]

  email-calendar-helper.sh create --provider <apple|gws>
                                  [--event-file <path> | --event-json <json>]
                                  [--calendar <name-or-id>] [--source-ref <text>] [--dry-run]

  email-calendar-helper.sh from-thread --provider <apple|gws>
                                       [--thread-file <path> | --thread-text <text> | --stdin]
                                       [--participants <csv>] [--timezone <tz>] [--calendar <name-or-id>]
                                       [--source-ref <text>] [--dry-run] [--ai-helper <path>]
EOF
	return 0
}

require_command() {
	local cmd_name="$1"
	if ! command -v "$cmd_name" >/dev/null 2>&1; then
		print_error "Missing required command: $cmd_name"
		return 1
	fi
	return 0
}

load_thread_text() {
	local thread_file="$1"
	local thread_text="$2"
	local use_stdin="$3"

	if [[ -n "$thread_file" && -n "$thread_text" ]]; then
		print_error "Use either --thread-file or --thread-text, not both"
		return 1
	fi

	if [[ "$use_stdin" == "true" ]]; then
		cat
		return 0
	fi

	if [[ -n "$thread_file" ]]; then
		if [[ ! -f "$thread_file" ]]; then
			print_error "Thread file not found: $thread_file"
			return 1
		fi
		cat "$thread_file"
		return 0
	fi

	if [[ -n "$thread_text" ]]; then
		printf '%s' "$thread_text"
		return 0
	fi

	print_error "Thread input required: --thread-file, --thread-text, or --stdin"
	return 1
}

extract_participants_from_thread() {
	local thread_text="$1"
	local participants

	participants=$(printf '%s\n' "$thread_text" | grep -Eio '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//') || true
	printf '%s' "$participants"
	return 0
}

build_extraction_prompt() {
	local thread_text="$1"
	local participants_csv="$2"
	local timezone="$3"

	cat <<EOF
Extract calendar commitments from this email thread.

Return JSON only with this schema:
{
  "agreed": true|false,
  "reason": "short reason",
  "event": {
    "title": "concise title",
    "start": "YYYY-MM-DDTHH:MM",
    "end": "YYYY-MM-DDTHH:MM",
    "timezone": "IANA timezone",
    "location": "optional location or empty string",
    "attendees": ["email@example.com"],
    "context_summary": "1-3 sentence summary"
  }
}

Rules:
- agreed=true only when date and time are explicitly agreed.
- if end time is missing, assume 60 minutes after start.
- if timezone is missing, use ${timezone}.
- include these participants when relevant: ${participants_csv}.

Email thread:
${thread_text}
EOF
	return 0
}

extract_json_from_llm_output() {
	local llm_output="$1"

	# shellcheck disable=SC2016
	printf '%s' "$llm_output" | python3 -c '
import json
import re
import sys

text = sys.stdin.read().strip()
if not text:
    sys.exit(1)

candidates = []
for m in re.finditer(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", text):
    candidates.append(m.group(1).strip())

if "{" in text and "}" in text:
    candidates.append(text[text.find("{"):text.rfind("}")+1].strip())

candidates.append(text)

for candidate in candidates:
    try:
        parsed = json.loads(candidate)
        print(json.dumps(parsed, separators=(",", ":")))
        sys.exit(0)
    except Exception:
        pass

sys.exit(1)
'
	return $?
}

normalize_event_json() {
	local raw_json="$1"
	local participants_csv="$2"
	local timezone="$3"

	local normalized
	normalized=$(jq -c --arg tz "$timezone" '
		{
			agreed: (.agreed // false),
			reason: (.reason // ""),
			event: {
				title: (.event.title // ""),
				start: (.event.start // ""),
				end: (.event.end // ""),
				timezone: (.event.timezone // $tz),
				location: (.event.location // ""),
				attendees: (.event.attendees // []),
				context_summary: (.event.context_summary // "")
			}
		}
	' <<<"$raw_json") || return 1

	if [[ -n "$participants_csv" ]]; then
		normalized=$(jq -c --arg csv "$participants_csv" '
			.event.attendees += ($csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))
			| .event.attendees |= (map(ascii_downcase) | unique)
			| .
		' <<<"$normalized") || return 1
	else
		normalized=$(jq -c '.event.attendees |= (map(select(type == "string" and length > 0)) | map(ascii_downcase) | unique) | .' <<<"$normalized") || return 1
	fi

	printf '%s' "$normalized"
	return 0
}

extract_event_from_thread() {
	local thread_text="$1"
	local participants_csv="$2"
	local timezone="$3"
	local ai_helper="$4"

	if [[ ! -x "$ai_helper" ]]; then
		print_error "AI helper is not executable: $ai_helper"
		return 1
	fi

	local prompt
	prompt=$(build_extraction_prompt "$thread_text" "$participants_csv" "$timezone")

	local llm_output
	llm_output=$("$ai_helper" --model haiku --max-tokens 700 --prompt "$prompt") || {
		print_error "AI extraction failed"
		return 1
	}

	local extracted_json
	extracted_json=$(extract_json_from_llm_output "$llm_output") || {
		print_error "Failed to parse JSON from AI extraction"
		return 1
	}

	normalize_event_json "$extracted_json" "$participants_csv" "$timezone"
	return $?
}

build_event_notes() {
	local event_json="$1"
	local source_ref="$2"

	jq -r --arg source_ref "$source_ref" '
		def attendees:
			if (.event.attendees | length) == 0 then "(none)"
			else (.event.attendees | map("- " + .) | join("\n")) end;
		"Email context:\n" + (.event.context_summary // "")
		+ "\n\nParticipants:\n" + attendees
		+ "\n\nSource:\n" + (if $source_ref == "" then "email thread" else $source_ref end)
	' <<<"$event_json"
	return 0
}

validate_event_for_creation() {
	local event_json="$1"
	local silent="${2:-false}"

	local agreed title start end
	agreed=$(jq -r '.agreed // false' <<<"$event_json")
	if [[ "$agreed" != "true" ]]; then
		if [[ "$silent" != "true" ]]; then
			print_info "No agreed event found: $(jq -r '.reason // "no reason"' <<<"$event_json")"
		fi
		return 1
	fi

	title=$(jq -r '.event.title // empty' <<<"$event_json")
	start=$(jq -r '.event.start // empty' <<<"$event_json")
	end=$(jq -r '.event.end // empty' <<<"$event_json")

	if [[ -z "$title" || -z "$start" || -z "$end" ]]; then
		print_error "Event JSON missing required fields: title/start/end"
		return 1
	fi

	return 0
}

escape_applescript_string() {
	local raw="$1"
	raw="${raw//\\/\\\\}"
	raw="${raw//\"/\\\"}"
	printf '%s' "$raw"
	return 0
}

create_apple_event() {
	local event_json="$1"
	local calendar_name="$2"
	local source_ref="$3"
	local dry_run="$4"

	require_command osascript || return 1

	local title start end location notes
	title=$(jq -r '.event.title' <<<"$event_json")
	start=$(jq -r '.event.start' <<<"$event_json")
	end=$(jq -r '.event.end' <<<"$event_json")
	location=$(jq -r '.event.location // ""' <<<"$event_json")
	notes=$(build_event_notes "$event_json" "$source_ref")

	local esc_title esc_location esc_notes esc_calendar
	esc_title=$(escape_applescript_string "$title")
	esc_location=$(escape_applescript_string "$location")
	esc_notes=$(escape_applescript_string "$notes")
	esc_calendar=$(escape_applescript_string "$calendar_name")

	local start_fmt end_fmt
	start_fmt="${start/T/ }"
	end_fmt="${end/T/ }"
	if [[ "$start_fmt" != *:*:* ]]; then
		start_fmt="${start_fmt}:00"
	fi
	if [[ "$end_fmt" != *:*:* ]]; then
		end_fmt="${end_fmt}:00"
	fi

	if [[ "$dry_run" == "true" ]]; then
		print_info "DRY_RUN apple event: $title @ $start"
		return 0
	fi

	local calendar_clause
	if [[ -n "$calendar_name" ]]; then
		calendar_clause="set targetCalendar to calendar \"${esc_calendar}\""
	else
		calendar_clause="set targetCalendar to first calendar"
	fi

	osascript <<APPLESCRIPT
tell application "Calendar"
    ${calendar_clause}
    tell targetCalendar
        make new event with properties {summary:"${esc_title}", start date:date "${start_fmt}", end date:date "${end_fmt}", location:"${esc_location}", description:"${esc_notes}"}
    end tell
end tell
APPLESCRIPT

	print_success "Created Apple Calendar event: $title"
	return 0
}

create_gws_event() {
	local event_json="$1"
	local calendar_name="$2"
	local source_ref="$3"
	local dry_run="$4"

	require_command gws || return 1

	local title start end timezone notes
	title=$(jq -r '.event.title' <<<"$event_json")
	start=$(jq -r '.event.start' <<<"$event_json")
	end=$(jq -r '.event.end' <<<"$event_json")
	timezone=$(jq -r '.event.timezone // ""' <<<"$event_json")
	notes=$(build_event_notes "$event_json" "$source_ref")

	local -a cmd
	cmd=(gws calendar +insert --title "$title" --start "$start" --end "$end" --description "$notes")
	if [[ -n "$timezone" ]]; then
		cmd+=(--timezone "$timezone")
	fi
	if [[ -n "$calendar_name" ]]; then
		cmd+=(--calendar "$calendar_name")
	fi

	local attendee
	while IFS= read -r attendee; do
		[[ -z "$attendee" ]] && continue
		cmd+=(--attendee "$attendee")
	done < <(jq -r '.event.attendees[]? // empty' <<<"$event_json")

	if [[ "$dry_run" == "true" ]]; then
		print_info "DRY_RUN gws command: ${cmd[*]}"
		return 0
	fi

	"${cmd[@]}"
	print_success "Created Google Calendar event: $title"
	return 0
}

cmd_extract() {
	local thread_file=""
	local thread_text=""
	local use_stdin="false"
	local participants_csv=""
	local timezone="$DEFAULT_TIMEZONE"
	local output_path=""
	local ai_helper="$AI_RESEARCH_HELPER_DEFAULT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--thread-file)
			thread_file="$2"
			shift 2
			;;
		--thread-text)
			thread_text="$2"
			shift 2
			;;
		--stdin)
			use_stdin="true"
			shift
			;;
		--participants)
			participants_csv="$2"
			shift 2
			;;
		--timezone)
			timezone="$2"
			shift 2
			;;
		--output)
			output_path="$2"
			shift 2
			;;
		--ai-helper)
			ai_helper="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	require_command jq || return 1
	require_command python3 || return 1

	local thread
	thread=$(load_thread_text "$thread_file" "$thread_text" "$use_stdin") || return 1

	if [[ -z "$participants_csv" ]]; then
		participants_csv=$(extract_participants_from_thread "$thread")
	fi

	local event_json
	event_json=$(extract_event_from_thread "$thread" "$participants_csv" "$timezone" "$ai_helper") || return 1

	if [[ -n "$output_path" ]]; then
		printf '%s\n' "$event_json" >"$output_path"
		print_success "Wrote extracted event JSON: $output_path"
	fi

	printf '%s\n' "$event_json" | jq .
	return 0
}

cmd_create() {
	local provider=""
	local event_file=""
	local event_json=""
	local calendar_name=""
	local source_ref=""
	local dry_run="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="$2"
			shift 2
			;;
		--event-file)
			event_file="$2"
			shift 2
			;;
		--event-json)
			event_json="$2"
			shift 2
			;;
		--calendar)
			calendar_name="$2"
			shift 2
			;;
		--source-ref)
			source_ref="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$provider" ]]; then
		print_error "Missing --provider <apple|gws>"
		return 1
	fi

	if [[ -n "$event_file" ]]; then
		if [[ ! -f "$event_file" ]]; then
			print_error "Event file not found: $event_file"
			return 1
		fi
		event_json=$(cat "$event_file")
	fi

	if [[ -z "$event_json" ]]; then
		print_error "Provide event JSON via --event-file or --event-json"
		return 1
	fi

	require_command jq || return 1
	validate_event_for_creation "$event_json" || return 1

	case "$provider" in
	apple)
		create_apple_event "$event_json" "$calendar_name" "$source_ref" "$dry_run"
		return $?
		;;
	gws)
		create_gws_event "$event_json" "$calendar_name" "$source_ref" "$dry_run"
		return $?
		;;
	*)
		print_error "Unsupported provider: $provider (expected apple|gws)"
		return 1
		;;
	esac
}

cmd_from_thread() {
	local provider=""
	local thread_file=""
	local thread_text=""
	local use_stdin="false"
	local participants_csv=""
	local timezone="$DEFAULT_TIMEZONE"
	local calendar_name=""
	local source_ref=""
	local dry_run="false"
	local ai_helper="$AI_RESEARCH_HELPER_DEFAULT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="$2"
			shift 2
			;;
		--thread-file)
			thread_file="$2"
			shift 2
			;;
		--thread-text)
			thread_text="$2"
			shift 2
			;;
		--stdin)
			use_stdin="true"
			shift
			;;
		--participants)
			participants_csv="$2"
			shift 2
			;;
		--timezone)
			timezone="$2"
			shift 2
			;;
		--calendar)
			calendar_name="$2"
			shift 2
			;;
		--source-ref)
			source_ref="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		--ai-helper)
			ai_helper="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$provider" ]]; then
		print_error "Missing --provider <apple|gws>"
		return 1
	fi

	require_command jq || return 1
	require_command python3 || return 1

	local thread
	thread=$(load_thread_text "$thread_file" "$thread_text" "$use_stdin") || return 1

	if [[ -z "$participants_csv" ]]; then
		participants_csv=$(extract_participants_from_thread "$thread")
	fi

	local event_json
	event_json=$(extract_event_from_thread "$thread" "$participants_csv" "$timezone" "$ai_helper") || return 1

	if ! validate_event_for_creation "$event_json" "true"; then
		printf '%s\n' "$event_json" | jq .
		return 0
	fi

	if [[ "$dry_run" == "true" ]]; then
		cmd_create --provider "$provider" --event-json "$event_json" --calendar "$calendar_name" --source-ref "$source_ref" --dry-run
		return $?
	fi

	cmd_create --provider "$provider" --event-json "$event_json" --calendar "$calendar_name" --source-ref "$source_ref"
	return $?
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	extract)
		cmd_extract "$@"
		return $?
		;;
	create)
		cmd_create "$@"
		return $?
		;;
	from-thread)
		cmd_from_thread "$@"
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

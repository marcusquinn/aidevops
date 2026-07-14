#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Bounded cursor pagination for framework-owned GitHub GraphQL connections.

set -u

usage() {
	cat <<'EOF'
Usage:
  github-graphql-page-helper.sh \
    --query-file QUERY.graphql \
    --connection-jq '.data.repository.issues' \
    --total N --max-pages N \
    [--page-size N] [--max-retries N] [--variables-file FILE]

Contract:
  - The query accepts variables named $pageSize (Int!) and $cursor (String).
  - --connection-jq selects an object with nodes[] and pageInfo containing
    boolean hasNextPage plus nullable/string endCursor.
  - The helper emits one JSON envelope. A non-zero exit always has
    pageInfo.complete=false, preserving any safely retrieved partial items.
  - Page size is clamped to 1..100. Retries are clamped to 0..10.
EOF
	return 0
}

fail() {
	local message="$1"
	printf 'github-graphql-page-helper: %s\n' "$message" >&2
	return 1
}

is_non_negative_integer() {
	local value="$1"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	return 1
}

emit_result() {
	local complete="$1"
	local reason="$2"
	local has_next="$3"
	local end_cursor="$4"
	local cursor_json="null"
	if [[ -n "$end_cursor" ]]; then
		cursor_json=$(jq -Rn --arg value "$end_cursor" '$value') || return 1
	fi
	if jq -n \
		--slurpfile items "$ITEMS_FILE" \
		--argjson complete "$complete" \
		--arg reason "$reason" \
		--argjson pages "$PAGES" \
		--argjson item_count "$ITEM_COUNT" \
		--argjson requested_total "$TOTAL" \
		--argjson page_size "$PAGE_SIZE" \
		--argjson max_pages "$MAX_PAGES" \
		--argjson retries_used "$RETRIES_USED" \
		--argjson has_next "$has_next" \
		--argjson end_cursor "$cursor_json" \
		'{items: $items[0], pageInfo: {complete: $complete, reason: $reason, pages: $pages, itemCount: $item_count, requestedTotal: $requested_total, pageSize: $page_size, maxPages: $max_pages, retriesUsed: $retries_used, hasNextPage: $has_next, endCursor: $end_cursor}}'; then
		return 0
	fi
	return 1
}

QUERY_FILE=""
CONNECTION_JQ=""
VARIABLES_FILE=""
TOTAL=""
MAX_PAGES=""
PAGE_SIZE=100
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
	arg="$1"
	case "$arg" in
	--query-file | --connection-jq | --variables-file | --total | --max-pages | --page-size | --max-retries)
		if [[ $# -lt 2 ]]; then
			fail "$arg requires a value"
			exit 2
		fi
		value="$2"
		case "$arg" in
		--query-file) QUERY_FILE="$value" ;;
		--connection-jq) CONNECTION_JQ="$value" ;;
		--variables-file) VARIABLES_FILE="$value" ;;
		--total) TOTAL="$value" ;;
		--max-pages) MAX_PAGES="$value" ;;
		--page-size) PAGE_SIZE="$value" ;;
		--max-retries) MAX_RETRIES="$value" ;;
		esac
		shift 2
		;;
	-h | --help | help)
		usage
		exit 0
		;;
	*)
		fail "unknown argument: $arg"
		usage >&2
		exit 2
		;;
	esac
done

[[ -n "$QUERY_FILE" && -f "$QUERY_FILE" ]] || { fail "--query-file must name a readable file"; exit 2; }
[[ -n "$CONNECTION_JQ" ]] || { fail "--connection-jq is required"; exit 2; }
is_non_negative_integer "$TOTAL" && [[ "$TOTAL" -gt 0 ]] || { fail "--total must be a positive integer"; exit 2; }
is_non_negative_integer "$MAX_PAGES" && [[ "$MAX_PAGES" -gt 0 ]] || { fail "--max-pages must be a positive integer"; exit 2; }
is_non_negative_integer "$PAGE_SIZE" || { fail "--page-size must be an integer"; exit 2; }
is_non_negative_integer "$MAX_RETRIES" || { fail "--max-retries must be an integer"; exit 2; }
command -v gh >/dev/null 2>&1 || { fail "gh is required"; exit 127; }
command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 127; }

if [[ "$PAGE_SIZE" -lt 1 ]]; then PAGE_SIZE=1; fi
if [[ "$PAGE_SIZE" -gt 100 ]]; then PAGE_SIZE=100; fi
if [[ "$MAX_RETRIES" -gt 10 ]]; then MAX_RETRIES=10; fi

VARIABLES_JSON='{}'
if [[ -n "$VARIABLES_FILE" ]]; then
	[[ -f "$VARIABLES_FILE" ]] || { fail "--variables-file must name a readable file"; exit 2; }
	VARIABLES_JSON=$(jq -ce 'if type == "object" then . else error("variables must be an object") end' "$VARIABLES_FILE") || {
		fail "--variables-file must contain one JSON object"
		exit 2
	}
fi

QUERY=$(<"$QUERY_FILE") || { fail "could not read query file"; exit 2; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/github-graphql-page.XXXXXX") || { fail "could not create temporary workspace"; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT
ITEMS_FILE="$TMP_ROOT/items.json"
REQUEST_FILE="$TMP_ROOT/request.json"
RESPONSE_FILE="$TMP_ROOT/response.json"
ERROR_FILE="$TMP_ROOT/error.log"
printf '[]\n' >"$ITEMS_FILE"

PAGES=0
ITEM_COUNT=0
RETRIES_USED=0
CURSOR=""
LAST_HAS_NEXT=false
LAST_CURSOR=""

while [[ "$ITEM_COUNT" -lt "$TOTAL" ]]; do
	if [[ "$PAGES" -ge "$MAX_PAGES" ]]; then
		fail "page budget exhausted after $PAGES pages"
		emit_result false "page_budget_exhausted" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 1
	fi

	REMAINING=$((TOTAL - ITEM_COUNT))
	REQUEST_SIZE="$PAGE_SIZE"
	if [[ "$REMAINING" -lt "$REQUEST_SIZE" ]]; then REQUEST_SIZE="$REMAINING"; fi
	if [[ -z "$CURSOR" ]]; then CURSOR_IS_NULL=true; else CURSOR_IS_NULL=false; fi

	jq -n \
		--arg query "$QUERY" \
		--argjson variables "$VARIABLES_JSON" \
		--argjson page_size "$REQUEST_SIZE" \
		--arg cursor "$CURSOR" \
		--argjson cursor_is_null "$CURSOR_IS_NULL" \
		'{query: $query, variables: ($variables + {pageSize: $page_size, cursor: (if $cursor_is_null then null else $cursor end)})}' \
		>"$REQUEST_FILE" || { fail "could not build GraphQL request"; emit_result false "request_build_error" "$LAST_HAS_NEXT" "$LAST_CURSOR"; exit 1; }

	ATTEMPT=0
	PAGE_FETCHED=false
	while [[ "$ATTEMPT" -le "$MAX_RETRIES" ]]; do
		if gh api graphql --input "$REQUEST_FILE" >"$RESPONSE_FILE" 2>"$ERROR_FILE" \
			&& jq -e 'type == "object" and ((.errors // []) | length == 0)' "$RESPONSE_FILE" >/dev/null 2>&1; then
			PAGE_FETCHED=true
			break
		fi
		if [[ "$ATTEMPT" -lt "$MAX_RETRIES" ]]; then RETRIES_USED=$((RETRIES_USED + 1)); fi
		ATTEMPT=$((ATTEMPT + 1))
	done

	if [[ "$PAGE_FETCHED" != "true" ]]; then
		fail "GraphQL API failed after $((MAX_RETRIES + 1)) bounded attempts"
		if [[ -s "$ERROR_FILE" ]]; then
			fail "GraphQL API stderr from the final attempt:"
			while IFS= read -r ERROR_LINE || [[ -n "$ERROR_LINE" ]]; do
				printf '%s\n' "$ERROR_LINE" >&2
			done <"$ERROR_FILE"
		fi
		if [[ -s "$RESPONSE_FILE" ]] \
			&& jq -e 'type == "object" and (.errors | type == "array") and ((.errors | length) > 0)' "$RESPONSE_FILE" >/dev/null; then
			fail "GraphQL errors from the final attempt:"
			jq -c '.errors' "$RESPONSE_FILE" >&2
		fi
		emit_result false "api_error" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 1
	fi

	CONNECTION=$(jq -ce "$CONNECTION_JQ" "$RESPONSE_FILE" 2>/dev/null) || {
		fail "response does not contain the requested connection"
		emit_result false "malformed_response" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 1
	}
	if ! jq -e 'type == "object" and (.nodes | type == "array") and (.pageInfo | type == "object") and (.pageInfo.hasNextPage | type == "boolean") and ((.pageInfo.endCursor == null) or (.pageInfo.endCursor | type == "string"))' <<<"$CONNECTION" >/dev/null 2>&1; then
		fail "connection must contain nodes[] and valid pageInfo"
		emit_result false "malformed_response" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 1
	fi

	NODE_COUNT=$(jq '.nodes | length' <<<"$CONNECTION")
	jq --argjson remaining "$REMAINING" --argjson connection "$CONNECTION" '. + ($connection.nodes[0:$remaining])' "$ITEMS_FILE" >"$TMP_ROOT/items.next.json" || {
		fail "could not accumulate response nodes"
		emit_result false "accumulation_error" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 1
	}
	mv "$TMP_ROOT/items.next.json" "$ITEMS_FILE"
	ITEM_COUNT=$(jq 'length' "$ITEMS_FILE")
	PAGES=$((PAGES + 1))
	LAST_HAS_NEXT=$(jq -r '.pageInfo.hasNextPage' <<<"$CONNECTION")
	LAST_CURSOR=$(jq -r '.pageInfo.endCursor // ""' <<<"$CONNECTION")

	if [[ "$ITEM_COUNT" -ge "$TOTAL" ]]; then
		emit_result true "total_cap_reached" "$LAST_HAS_NEXT" "$LAST_CURSOR"
		exit 0
	fi
	if [[ "$LAST_HAS_NEXT" != "true" ]]; then
		emit_result true "source_exhausted" false "$LAST_CURSOR"
		exit 0
	fi
	if [[ -z "$LAST_CURSOR" || "$LAST_CURSOR" == "$CURSOR" ]]; then
		fail "hasNextPage requires a new non-empty endCursor"
		emit_result false "malformed_cursor" true "$LAST_CURSOR"
		exit 1
	fi
	if [[ "$NODE_COUNT" -eq 0 ]]; then
		fail "hasNextPage returned an empty nodes page"
		emit_result false "empty_page" true "$LAST_CURSOR"
		exit 1
	fi
	CURSOR="$LAST_CURSOR"
done

emit_result true "total_cap_reached" "$LAST_HAS_NEXT" "$LAST_CURSOR"
exit 0

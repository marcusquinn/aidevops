#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_SCHEMA_VERSION=1

snapshot_error() {
	local message="$1"
	printf 'issue snapshot unavailable: %s\n' "$message" >&2
	return 1
}

snapshot_hash() {
	local body_file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$body_file" | cut -d' ' -f1
		return $?
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$body_file" | cut -d' ' -f1
		return $?
	fi
	snapshot_error "SHA-256 tool is missing"
	return 1
}

snapshot_epoch_from_iso() {
	local timestamp="$1"
	local epoch=""
	epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null) || \
		epoch=$(date -u -d "$timestamp" '+%s' 2>/dev/null) || epoch=""
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$epoch"
	return 0
}

snapshot_path() {
	local repo_slug="$1"
	local issue_number="$2"
	local safe_repo=""
	safe_repo=$(printf '%s' "$repo_slug" | tr -c 'A-Za-z0-9._-' '_')
	printf '%s/%s-%s.json' "${ISSUE_BODY_SNAPSHOT_DIR:-${HOME}/.aidevops/cache/issue-body-snapshots}" "$safe_repo" "$issue_number"
	return 0
}

snapshot_scan_body() {
	local body_file="$1"
	local scanner="${ISSUE_BODY_SNAPSHOT_SCANNER:-${SCRIPT_DIR}/prompt-guard-helper.sh}"
	[[ -x "$scanner" ]] || { snapshot_error "prompt-injection scanner is unavailable"; return 1; }
	PROMPT_GUARD_POLICY="${ISSUE_BODY_SNAPSHOT_SCANNER_POLICY:-moderate}" \
		PROMPT_GUARD_QUIET=true "$scanner" check-file "$body_file" >/dev/null 2>&1 || {
		snapshot_error "prompt-injection scanner blocked the issue body"
		return 1
	}
	return 0
}

snapshot_validate() {
	local snapshot_file="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local max_bytes="$4"
	local ttl_seconds="$5"
	local mode="" body_file="" expected_hash="" actual_hash="" captured_at="" captured_epoch="" now_epoch=""

	[[ -f "$snapshot_file" ]] || { snapshot_error "no durable fallback exists"; return 1; }
	mode=$(stat -f '%Lp' "$snapshot_file" 2>/dev/null || stat -c '%a' "$snapshot_file" 2>/dev/null || true)
	[[ "$mode" == "600" ]] || { snapshot_error "snapshot permissions are ${mode:-unknown}, expected 600"; return 1; }
	jq -e --arg repo "$repo_slug" --argjson issue "$issue_number" --argjson schema "$SNAPSHOT_SCHEMA_VERSION" \
		'type == "object" and .schemaVersion == $schema and .repo == $repo and .issue == $issue and
		 (.title | type == "string") and (.body | type == "string") and
		 (.sourceUpdatedAt | type == "string") and (.capturedAt | type == "string") and
		 (.bodyHash | test("^[0-9a-f]{64}$"))' "$snapshot_file" >/dev/null 2>&1 || {
		snapshot_error "schema or issue identity validation failed"
		return 1
	}
	body_file=$(mktemp "${TMPDIR:-/tmp}/issue-snapshot-body-XXXXXX") || return 1
	trap 'rm -f "$body_file"' RETURN
	jq -rj '.body' "$snapshot_file" >"$body_file" || { snapshot_error "body extraction failed"; return 1; }
	[[ $(wc -c <"$body_file" | tr -d '[:space:]') -le "$max_bytes" ]] || { snapshot_error "body exceeds ${max_bytes}-byte limit"; return 1; }
	expected_hash=$(jq -r '.bodyHash' "$snapshot_file")
	actual_hash=$(snapshot_hash "$body_file") || return 1
	[[ "$actual_hash" == "$expected_hash" ]] || { snapshot_error "body hash validation failed"; return 1; }
	captured_at=$(jq -r '.capturedAt' "$snapshot_file")
	captured_epoch=$(snapshot_epoch_from_iso "$captured_at") || { snapshot_error "capture time is invalid"; return 1; }
	now_epoch=$(date -u '+%s')
	[[ "$captured_epoch" -le "$now_epoch" && $((now_epoch - captured_epoch)) -le "$ttl_seconds" ]] || {
		snapshot_error "snapshot is stale or has a future capture time"
		return 1
	}
	snapshot_scan_body "$body_file" || return 1
	trap - RETURN
	rm -f "$body_file"
	return 0
}

snapshot_write() {
	local live_json="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local snapshot_file="$4"
	local max_bytes="$5"
	local snapshot_dir="" body_file="" body_hash="" captured_at="" temp_file=""

	snapshot_dir="${snapshot_file%/*}"
	mkdir -p "$snapshot_dir" || return 1
	chmod 700 "$snapshot_dir" || return 1
	body_file=$(mktemp "${TMPDIR:-/tmp}/issue-live-body-XXXXXX") || return 1
	trap 'rm -f "$body_file" "${temp_file:-}"' RETURN
	jq -rj '.body' <<<"$live_json" >"$body_file" || return 1
	[[ $(wc -c <"$body_file" | tr -d '[:space:]') -le "$max_bytes" ]] || { snapshot_error "live body exceeds ${max_bytes}-byte limit"; return 1; }
	snapshot_scan_body "$body_file" || return 1
	body_hash=$(snapshot_hash "$body_file") || return 1
	captured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	temp_file=$(mktemp "${snapshot_dir}/.snapshot-XXXXXX") || return 1
	umask 077
	jq -c --argjson schema "$SNAPSHOT_SCHEMA_VERSION" --arg repo "$repo_slug" --argjson issue "$issue_number" \
		--arg captured "$captured_at" --arg hash "$body_hash" \
		'{schemaVersion: $schema, repo: $repo, issue: $issue, title: .title, body: .body,
		 sourceUpdatedAt: .updatedAt, capturedAt: $captured, bodyHash: $hash}' <<<"$live_json" >"$temp_file" || return 1
	chmod 600 "$temp_file" || return 1
	mv -f "$temp_file" "$snapshot_file" || return 1
	trap - RETURN
	rm -f "$body_file"
	return 0
}

snapshot_fetch() {
	local repo_slug="$1"
	local issue_number="$2"
	local max_bytes="${ISSUE_BODY_SNAPSHOT_MAX_BYTES:-65536}"
	local ttl_seconds="${ISSUE_BODY_SNAPSHOT_TTL_SECONDS:-86400}"
	local snapshot_file="" live_json=""
	[[ "$repo_slug" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || { snapshot_error "repository identity is invalid"; return 1; }
	[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || { snapshot_error "issue identity is invalid"; return 1; }
	[[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { snapshot_error "body limit is invalid"; return 1; }
	[[ "$ttl_seconds" =~ ^[1-9][0-9]*$ ]] || { snapshot_error "TTL is invalid"; return 1; }
	snapshot_file=$(snapshot_path "$repo_slug" "$issue_number")

	live_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json number,title,body,updatedAt 2>/dev/null) && {
		jq -e --argjson issue "$issue_number" '.number == $issue and (.title | type == "string") and (.body | type == "string") and (.updatedAt | type == "string")' \
			<<<"$live_json" >/dev/null 2>&1 || { snapshot_error "live response validation failed"; return 1; }
		if [[ "${ISSUE_BODY_SNAPSHOT_ENABLED:-1}" == "1" ]]; then
			snapshot_write "$live_json" "$repo_slug" "$issue_number" "$snapshot_file" "$max_bytes" || return 1
		else
			local live_body_file=""
			live_body_file=$(mktemp "${TMPDIR:-/tmp}/issue-live-body-XXXXXX") || return 1
			jq -rj '.body' <<<"$live_json" >"$live_body_file"
			[[ $(wc -c <"$live_body_file" | tr -d '[:space:]') -le "$max_bytes" ]] && snapshot_scan_body "$live_body_file" || { rm -f "$live_body_file"; return 1; }
			rm -f "$live_body_file"
		fi
		printf '%s' "$live_json"
		return 0
	}

	[[ "${ISSUE_BODY_SNAPSHOT_ENABLED:-1}" == "1" ]] || { snapshot_error "live GitHub read failed and snapshots are disabled"; return 1; }
	snapshot_validate "$snapshot_file" "$repo_slug" "$issue_number" "$max_bytes" "$ttl_seconds" || return 1
	jq -c '{number: .issue, title, body, updatedAt: .sourceUpdatedAt, snapshotFallback: true}' "$snapshot_file"
	return 0
}

snapshot_cleanup() {
	local snapshot_dir="${ISSUE_BODY_SNAPSHOT_DIR:-${HOME}/.aidevops/cache/issue-body-snapshots}"
	local ttl_seconds="${ISSUE_BODY_SNAPSHOT_TTL_SECONDS:-86400}"
	local file="" captured_at="" captured_epoch="" now_epoch=""
	[[ -d "$snapshot_dir" ]] || return 0
	now_epoch=$(date -u '+%s')
	for file in "$snapshot_dir"/*.json; do
		[[ -f "$file" ]] || continue
		captured_at=$(jq -r '.capturedAt // empty' "$file" 2>/dev/null || true)
		captured_epoch=$(snapshot_epoch_from_iso "$captured_at" 2>/dev/null || true)
		if [[ ! "$captured_epoch" =~ ^[0-9]+$ || $((now_epoch - captured_epoch)) -gt "$ttl_seconds" ]]; then
			rm -f "$file"
		fi
	done
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	fetch)
		[[ $# -eq 3 ]] || { snapshot_error "usage: $0 fetch OWNER/REPO ISSUE"; return 1; }
		snapshot_fetch "$2" "$3"
		return $?
		;;
	cleanup)
		snapshot_cleanup
		return $?
		;;
	*)
		snapshot_error "expected fetch or cleanup"
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
	exit $?
fi

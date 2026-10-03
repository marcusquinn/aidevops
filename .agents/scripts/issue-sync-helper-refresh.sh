#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Refresh generated issue bodies without discarding framework-owned appendages.

_refresh_audit() {
	local outcome="$1" repo="$2" issue="$3" before="$4" after="$5"
	local helper="${BODY_SYNC_AUDIT_HELPER:-${SCRIPT_DIR}/audit-log-helper.sh}"
	"$helper" log operation.verify "issue body refresh: $outcome" \
		--detail "operation=issue-body-refresh" --detail "outcome=$outcome" \
		--detail "repo=$repo" --detail "issue=$issue" \
		--detail "before_hash=${before:-none}" --detail "after_hash=${after:-none}" >/dev/null 2>&1 || {
		print_error "Refresh audit receipt failed: $outcome"
		return 1
	}
	return 0
}

# Extract only a complete signature paragraph and complete feedback-route blocks.
# Incomplete marker blocks are not silently carried into a regenerated brief.
_refresh_tail() {
	local body_file="$1" tail_file="$2" keep_signature="$3"
	awk -v sig="$keep_signature" '
		{ line[NR]=$0; if ($0 ~ /^<!-- aidevops:origin:/ && !origin) origin=NR;
		  if ($0 ~ /^<!-- aidevops:sig -->/ && !signature) signature=NR }
		END {
		  if (sig && signature) {
		    start=origin && origin < signature ? origin : signature;
		    end=signature;
		    while (end < NR && line[end+1] !~ /^<!-- feedback-route:start:/) {
		      end++; if (end > signature+1 && line[end] == "") break;
		    }
		    for (i=start;i<=end;i++) print line[i];
		  }
		  for (i=1;i<=NR;i++) if (line[i] ~ /^<!-- feedback-route:start:/) {
		    finish=0;
		    for (j=i+1;j<=NR;j++) {
		      if (line[j] ~ /^<!-- feedback-route:start:/) break;
		      if (line[j] ~ /^<!-- feedback-route:complete:/) {finish=j; break}
		    }
		    if (finish) {for (k=i;k<=finish;k++) print line[k]; i=finish}
		  }
		}' "$body_file" >"$tail_file"
	return $?
}

_refresh_hash() {
	local body="$1" canonical="" suffix=""
	canonical=$(_body_sync_hash_body "$body") || return 1
	# The common canonicalizer deliberately drops the signature and everything
	# after it. Verify those preserved bytes separately, ignoring final blank lines.
	suffix=$(printf '%s' "$body" | awk '/^<!-- aidevops:sig -->/ {seen=1} seen {lines[NR]=$0; if ($0 !~ /^[[:space:]]*$/) last=NR} END {for (i=1;i<=last;i++) if (i in lines) print lines[i]}') || return 1
	if command -v shasum >/dev/null 2>&1; then
		printf '%s\n%s' "$canonical" "$suffix" | shasum -a 256 | cut -d' ' -f1
		return $?
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s\n%s' "$canonical" "$suffix" | sha256sum | cut -d' ' -f1
		return $?
	fi
	print_error "Issue body refresh requires a SHA-256 tool"
	return 1
}

cmd_refresh_body() {
	local issue="$1" body_file="$2" repo="${REPO_SLUG:-}" self_login=""
	local initial="" immediate="" post="" current="" desired="" before="" after=""
	local source_file="" tail_file="" output_file="" rc=1
	[[ "$issue" =~ ^[1-9][0-9]*$ && -n "$repo" && -f "$body_file" && -s "$body_file" ]] || {
		print_error "refresh-body requires a positive issue number, --repo and a non-empty regular --body-file"
		return 1
	}
	_body_sync_scan_file "$body_file" desired || return 1
	#aidevops:trust-boundary — resolve current identity and maintain/admin permission per invocation.
	_gh_current_user_allows_repo_write "$repo" || { print_error "Refresh requires maintainer authority"; return 1; }
	self_login="${AIDEVOPS_GH_WRITE_PERMISSION_USER:-}"
	case "${AIDEVOPS_GH_WRITE_PERMISSION_LEVEL:-}" in admin | maintain) ;; *) print_error "Refresh requires admin or maintain"; return 1 ;; esac
	[[ -n "$self_login" ]] || return 1
	initial=$(_body_sync_fetch_state "$repo" "$issue") || { _refresh_audit blocked "$repo" "$issue" "" ""; return 1; }
	if ! _refresh_policy "$initial" "$issue" "$self_login"; then
		_refresh_audit blocked "$repo" "$issue" "" ""
		return 1
	fi
	current=$(jq -r '.body' <<<"$initial") || return 1
	source_file=$(_body_sync_temp_file refresh-current) || return 1
	tail_file=$(_body_sync_temp_file refresh-tail) || { rm -f "$source_file"; return 1; }
	output_file=$(_body_sync_temp_file refresh-output) || { rm -f "$source_file" "$tail_file"; return 1; }
	printf '%s\n' "$current" >"$source_file"
	_body_sync_scan_file "$source_file" current || { _refresh_audit blocked "$repo" "$issue" "" ""; rm -f "$source_file" "$tail_file" "$output_file"; return 1; }
	if rg -q '^<!-- aidevops:sig -->' "$body_file"; then
		_refresh_tail "$source_file" "$tail_file" 0 || return 1
	else
		_refresh_tail "$source_file" "$tail_file" 1 || return 1
	fi
	{ printf '%s\n' "$(<"$body_file")"; if [[ -s "$tail_file" ]]; then printf '\n'; cat "$tail_file"; fi; } >"$output_file"
	desired=$(<"$output_file")
	before=$(_refresh_hash "$current") || return 1
	after=$(_refresh_hash "$desired") || return 1
	immediate=$(_body_sync_fetch_state "$repo" "$issue") || { _refresh_audit blocked "$repo" "$issue" "$before" "$after"; return 1; }
	if ! _refresh_policy "$immediate" "$issue" "$self_login" || [[ "$(_body_sync_state_digest "$initial")" != "$(_body_sync_state_digest "$immediate")" ]]; then
		_refresh_audit blocked "$repo" "$issue" "$before" "$after"
		print_error "Refresh refused concurrent state change"
	elif [[ "$before" == "$after" ]]; then
		_refresh_audit no-op "$repo" "$issue" "$before" "$after" && rc=0
	elif [[ "${DRY_RUN:-false}" == true ]]; then
		printf 'Preserved signature blocks: %s; feedback blocks: %s; old lines: %s; new lines: %s\n' \
			"$(rg -c '^<!-- aidevops:sig -->' "$tail_file" || true)" \
			"$(rg -c '^<!-- feedback-route:start:' "$tail_file" || true)" \
			"$(wc -l <"$source_file")" "$(wc -l <"$output_file")"
		diff -u "$source_file" "$output_file" || true
		rc=2
	else
		_refresh_audit authorized "$repo" "$issue" "$before" "$after" || return 1
		if gh_issue_edit_safe "$issue" --repo "$repo" --body-file "$output_file"; then
			post=$(_body_sync_fetch_state "$repo" "$issue") || post=""
			if _body_sync_validate_state "$post" "$issue" && \
				[[ "$(_body_sync_metadata_digest "$immediate")" == "$(_body_sync_metadata_digest "$post")" ]] && \
				[[ "$(_refresh_hash "$(jq -r '.body' <<<"$post")")" == "$after" ]]; then
				_refresh_audit verified "$repo" "$issue" "$before" "$after" && rc=0
			fi
		fi
		if [[ "$rc" -ne 0 ]]; then _refresh_audit blocked "$repo" "$issue" "$before" "$after"; fi
	fi
	rm -f "$source_file" "$tail_file" "$output_file"
	return "$rc"
}

_refresh_policy() {
	local state="$1" issue="$2" self="$3"
	_body_sync_validate_state "$state" "$issue" && \
		[[ "$(jq -r '.state' <<<"$state")" == OPEN ]] && \
		! _body_sync_has_nonself_claim "$state" "$self" && \
		! jq -e 'any(.labels[]; .name == "status:queued" or .name == "status:in-progress" or .name == "status:in-review")' <<<"$state" >/dev/null
	return $?
}

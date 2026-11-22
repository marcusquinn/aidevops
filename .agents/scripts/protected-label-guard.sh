#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Shared containment for cross-runner protected-label oscillation (GH#35793).
# Configuration: comma-separated PROTECTED_LABEL_FLAP_LABELS; positive integer
# PROTECTED_LABEL_FLAP_THRESHOLD (transitions, default 4), WINDOW_SECONDS (21600)
# and COOLDOWN_SECONDS (21600), with the same PROTECTED_LABEL_FLAP_ prefix.
# GitHub timeline and marker comments, not runner-local counters, own cooldown.

_PL_ADD_LABEL_FLAG="--add-label"
_PL_REMOVE_LABEL_FLAG="--remove-label"
_PL_ARRAY_TYPE="array"

_protected_label_comments() {
	local number="$1" repo="$2"
	gh api --paginate --slurp "repos/${repo}/issues/${number}/comments?per_page=100" 2>/dev/null || return 1
	return 0
}

_protected_label_raw_edit() {
	local number="$1" repo="$2"
	shift 2
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$number" --repo "$repo" "$@" || return 1
	else
		gh issue edit "$number" --repo "$repo" "$@" || return 1
	fi
	return 0
}

# Output one JSON summary, validating every page before flattening. Count actual
# alternating transitions rather than repeated copies of the same event type.
_protected_label_flap_summary() {
	local timeline="$1" label="$2" window="$3" since="$4"
	printf '%s' "$timeline" | jq -ce --arg label "$label" \
		--arg array_type "$_PL_ARRAY_TYPE" --argjson window "$window" --argjson since "$since" '
		if type != $array_type or any(.[]; type != $array_type) then error("invalid timeline")
		else add // [] end
		| [.[] | select(.label.name? == $label and
			(.event == "labeled" or .event == "unlabeled"))
			| . + {epoch: (.created_at | fromdateiso8601)}
			| select(.epoch >= (now - $window) and .epoch > $since)]
		| sort_by(.epoch, .id)
		| reduce .[] as $e ({count:0, last:"", actors:[], latest:0};
			if .last != $e.event then .count += 1 else . end
			| .last = $e.event | .latest = $e.epoch
			| .actors += [$e.actor.login // "unknown"])
		| .actors |= unique'
	return $?
}

# Return 1 for a held label, including when containment/diagnostics cannot be
# verified. Never turn missing history into permission to remove a trust gate.
_protected_label_marker_since() {
	local comments="$1" marker="$2" repo="$3"
	local rows="" login="" association="" epoch="" app_write="" permission="" checked=","
	local response=""
	rows=$(printf '%s' "$comments" | jq -r --arg marker "$marker" --arg array_type "$_PL_ARRAY_TYPE" '
		if type != $array_type or any(.[]; type != $array_type) then error("invalid comments")
		else add // [] end
		| [.[] | select((.body // "") | startswith($marker))
			| {login:(.user.login // "unknown"), association:.author_association,
				epoch:(.created_at | fromdateiso8601),
				app_write:(.user.type == "Bot" and .performed_via_github_app.permissions.issues == "write")}]
		| sort_by(.epoch) | reverse
		| .[] | [.login, .association, .epoch, .app_write] | @tsv') || return 1
	while IFS=$'\t' read -r login association epoch app_write; do
		[[ -n "$epoch" ]] || continue
		if [[ "$association" == "OWNER" || "$association" == "MEMBER" || "$app_write" == "true" ]]; then
			printf '%s\n' "$epoch"
			return 0
		fi
		# A legitimate runner may be a collaborator (or be viewed differently by
		# another token). Check live authority instead of trusting association alone.
		[[ "$login" =~ ^[A-Za-z0-9_-]+$ ]] || continue
		# Rows are newest first: a denied login needs only one lookup per scan.
		# Association and app authority are still evaluated for every comment.
		[[ "$checked" == *",${login},"* ]] && continue
		checked="${checked}${login},"
		if ! response=$(gh api --include "repos/${repo}/collaborators/${login}/permission" --jq '.permission' 2>/dev/null); then
			# A missing user/collaborator is not an authoritative marker author.
			# Inspect only the HTTP status line, never error-body or stderr text.
			# All other failures leave authority unverifiable and hold removals.
			[[ "$response" =~ ^HTTP/[0-9.]+[[:space:]]+404[[:space:]] ]] && continue
			return 1
		fi
		# gh --include emits response headers before the --jq filtered value.
		permission="${response##*$'\n'}"
		case "$permission" in
		admin | maintain | write)
			printf '%s\n' "$epoch"
			return 0
			;;
		esac
	done <<<"$rows"
	printf '0\n'
	return 0
}

_protected_label_check() {
	local number="$1" repo="$2" label="$3" operation="$4" decision="$5"
	_PL_CHECK_APPLIED=0
	_PL_CHECK_CONTAINMENT_ONLY=1
	local threshold="${PROTECTED_LABEL_FLAP_THRESHOLD:-4}"
	local window="${PROTECTED_LABEL_FLAP_WINDOW_SECONDS:-21600}"
	local cooldown="${PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS:-21600}"
	local value="" setting="" timeline="" comments="" marker="" since=0 active=0 summary=""
	for setting in PROTECTED_LABEL_FLAP_THRESHOLD PROTECTED_LABEL_FLAP_WINDOW_SECONDS PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS; do
		case "$setting" in
		PROTECTED_LABEL_FLAP_THRESHOLD) value="$threshold" ;;
		PROTECTED_LABEL_FLAP_WINDOW_SECONDS) value="$window" ;;
		PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS) value="$cooldown" ;;
		esac
		if ! [[ "$value" =~ ^[1-9][0-9]{0,7}$ ]]; then
			printf 'protected-label-guard: invalid %s value %q\n' "$setting" "$value" >&2
			# Bad configuration must not prevent fail-closed containment.
			[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
			return 1
		fi
	done
	# Retry locally pending audit writes even when a remote marker already holds
	# the label, or its cooldown has expired. Never republish for an audit retry.
	_protected_label_report "$number" "$repo" "$label" "" "" "$decision" "$cooldown" 0 || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	marker="<!-- aidevops:protected-label-flap:${label}:v1 -->"
	# The remote cooldown survives missing timeline reads and runner restarts.
	comments=$(_protected_label_comments "$number" "$repo") || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	since=$(_protected_label_marker_since "$comments" "$marker" "$repo") || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	active=$(jq -nr --argjson since "$since" --argjson cooldown "$cooldown" \
		'if $since > 0 and now < ($since + $cooldown) then 1 else 0 end') || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	# A failed read may not prevent an add: adding is always containment, never
	# authority to dispatch. Removals require complete live evidence.
	if [[ "$active" -eq 0 ]]; then
		timeline=$(gh api --paginate --slurp "repos/${repo}/issues/${number}/timeline?per_page=100" 2>/dev/null) || {
			[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
			return 1
		}
		# An expired incident must not retrigger forever on its old events.
		summary=$(_protected_label_flap_summary "$timeline" "$label" "$window" "$since") || {
			[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
			return 1
		}
		if [[ "$(printf '%s' "$summary" | jq -r '.count')" -lt "$threshold" ]]; then
			_PL_CHECK_CONTAINMENT_ONLY=0
			return 0
		fi
	fi
	local live=""
	live=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || {
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" ]] && return 0
		return 1
	}
	if ! printf '%s' "$live" | jq -e --arg label "$label" --arg array_type "$_PL_ARRAY_TYPE" \
		'.labels | if type != $array_type then error("invalid labels") else any(.[]; .name == $label) end' >/dev/null; then
		# Restore once if the final observed transition was a removal. Never clear
		# unrelated labels or promote lifecycle state while held.
		_protected_label_raw_edit "$number" "$repo" "$_PL_ADD_LABEL_FLAG" "$label" || return 1
	fi
	_PL_CHECK_APPLIED=1
	if [[ "$active" -eq 0 ]]; then
		# Re-read immediately before publication: a peer may have reported while
		# we fetched history/restored the label. GitHub comments have no atomic
		# create-if-absent; this is bounded best-effort cross-host deduplication.
		comments=$(_protected_label_comments "$number" "$repo") || return 1
		local latest_since=""
		latest_since=$(_protected_label_marker_since "$comments" "$marker" "$repo") || return 1
		[[ "$latest_since" -le "$since" ]] || return 1
		decision="${decision}; live_association=$(printf '%s' "$live" | jq -r '.author_association // "unknown"')"
		_protected_label_report "$number" "$repo" "$label" "$marker" "$summary" "$decision" "$cooldown" "$since" || return 1
	fi
	return 1
}

_protected_label_report() {
	local number="$1" repo="$2"
	local state_dir="${PROTECTED_LABEL_FLAP_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/protected-label-flap}"
	local lock="${state_dir}/${repo//\//_}-${number}.lock"
	# Serialize publishers sharing a host. The kernel releases flock on the last
	# descriptor close, including SIGKILL/crashes; never unlink its stable inode.
	# Python's fcntl works on macOS as well as Linux without a flock executable.
	# Use a separate path so legacy orphaned mkdir locks cannot block recovery.
	(
		umask 077
		mkdir -p "$state_dir" || return 1
		(
			# The Python child and this subshell share fd 9's open description;
			# the subshell keeps the lock after Python exits, through publication.
			if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)'; then
				printf 'protected-label-guard: report lock busy or unavailable for %s#%s\n' "$repo" "$number" >&2
				return 1
			fi
			_protected_label_publish "$@"
		) 9>>"${lock%.lock}.publish-lock"
	)
	return $?
}

_protected_label_publish() {
	local number="$1" repo="$2" label="$3" marker="$4" summary="$5" decision="$6" cooldown="$7" previous_since="$8"
	local comments="" since="" dir="" pending="" flags=""
	dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	# The target lock serializes this journal, but removing that lock must never
	# discard a failed audit. Keep the successful receipt independently as well.
	pending="${lock%.lock}.audit-pending"
	if [[ -f "$pending" ]]; then
		IFS= read -r flags <"$pending" || return 1
		"${dir}/gh-audit-log-helper.sh" record --op issue_edit --repo "$repo" --number "$number" \
			--caller-script protected-label-guard.sh --caller-function _protected_label_report \
			--flags-json "$flags" >/dev/null || return 1
		mv "$pending" "${lock%.lock}.audit-recorded" || return 1
	fi
	[[ -n "$summary" ]] || return 0
	comments=$(_protected_label_comments "$number" "$repo") || return 1
	since=$(_protected_label_marker_since "$comments" "$marker" "$repo") || return 1
	[[ "$since" -le "$previous_since" ]] || return 0
	local body="" version="unknown" actors=""
	if [[ -r "${dir}/../../VERSION" ]]; then
		IFS= read -r version <"${dir}/../../VERSION" || true
	fi
	actors=$(printf '%s' "$summary" | jq -r '.actors | join(", ")') || return 1
	body="${marker}
Protected label \`${label}\` is held applied for ${cooldown}s after repeated timeline transitions.
Timeline actors: ${actors}.
Detecting runner: ${AIDEVOPS_PUBLIC_RUNNER_ID:-unknown}; aidevops ${version}; decision: ${decision}.
GitHub timeline events do not expose historical runner versions or trust decisions; these are unavailable, not inferred from actor identity.
Investigate token authority, permission caches and version skew before retrying."
	# Journal before publication so a successful marker can never hide a missing
	# anomaly. A failed publication still describes a detected flap incident.
	jq -cn --arg label "$label" '{protected_label_flap:$label}' >"$pending" || return 1
	printf '%s\n' "$body" | "${dir}/gh-write-helper.sh" issue comment "$number" --repo "$repo" --body-file - || return 1
	"${dir}/gh-audit-log-helper.sh" record --op issue_edit --repo "$repo" --number "$number" \
		--caller-script protected-label-guard.sh --caller-function _protected_label_report \
		--flags-json "$(jq -cn --arg label "$label" '{protected_label_flap:$label}')" >/dev/null || return 1
	mv "$pending" "${lock%.lock}.audit-recorded" || return 1
	return 0
}

# Args: number, repository, diagnostic trust decision, followed by edit flags.
# A held edit returns failure so callers cannot report successful normalization.
protected_label_edit() {
	local number="$1" repo="$2" decision="$3"
	shift 3
	local operation="" label="" previous=""
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$number" =~ ^[1-9][0-9]*$ ]] || return 1
	# This interface accepts only separate, single-label arguments. Reject other
	# gh flag forms rather than allowing an unguarded protected-label removal.
	local -a edits=("$@")
	while [[ $# -gt 0 ]]; do
		local operation="$1" label="${2:-}"
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" || "$operation" == "$_PL_REMOVE_LABEL_FLAG" ]] || return 1
		[[ -n "$label" && "$label" != *,* && "$label" != --* ]] || return 1
		shift 2 || return 1
	done
	for label in "${edits[@]}"; do
		operation="$previous"
		previous="$label"
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" || "$operation" == "$_PL_REMOVE_LABEL_FLAG" ]] || continue
		case ",${PROTECTED_LABEL_FLAP_LABELS:-needs-maintainer-review}," in
		*,"$label",*)
			_protected_label_check "$number" "$repo" "$label" "$operation" "$decision" || return 1
			if [[ "$_PL_CHECK_CONTAINMENT_ONLY" -eq 1 ]]; then
				# Missing evidence authorizes only the containment add, never a
				# mixed batch's dispatch or lifecycle changes.
				_protected_label_raw_edit "$number" "$repo" "$_PL_ADD_LABEL_FLAG" "$label" || return 1
				[[ "${#edits[@]}" -eq 2 ]] && return 0
				return 1
			fi
			;;
		esac
	done
	# A stale remover must repair containment if a peer published a cooldown
	# between our preflight and write. Do not poll; take one fresh observation.
	# Isolate protected removals so a postflight hold cannot leave this batch's
	# auto-dispatch or other lifecycle edits applied alongside restored NMR.
	local -a remaining=()
	previous=""
	for label in "${edits[@]}"; do
		operation="$previous" previous="$label"
		[[ "$operation" == "$_PL_ADD_LABEL_FLAG" || "$operation" == "$_PL_REMOVE_LABEL_FLAG" ]] || continue
		if [[ "$operation" == "$_PL_REMOVE_LABEL_FLAG" && ",${PROTECTED_LABEL_FLAP_LABELS:-needs-maintainer-review}," == *",${label},"* ]]; then
			_protected_label_raw_edit "$number" "$repo" "$operation" "$label" || return 1
			if ! _protected_label_check "$number" "$repo" "$label" "$operation" "$decision"; then
				if [[ "$_PL_CHECK_APPLIED" -eq 0 ]]; then
					_protected_label_raw_edit "$number" "$repo" "$_PL_ADD_LABEL_FLAG" "$label" || true
				fi
				return 1
			fi
		else
			remaining+=("$operation" "$label")
		fi
	done
	if [[ "${#remaining[@]}" -gt 0 ]]; then
		_protected_label_raw_edit "$number" "$repo" "${remaining[@]}" || return 1
	fi
	return 0
}

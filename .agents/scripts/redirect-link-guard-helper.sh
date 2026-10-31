#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# redirect-link-guard-helper.sh — strict no-redirect-link enforcement (GH#35655, t18771).
#
# Any issue, PR, comment, review comment, discussion or discussion comment
# from a non-collaborator that contains a URL-shortener/redirector link
# (configs/redirect-hosts.conf) is spam:
#   issue/PR            -> label `spam`, close (not planned), lock (spam)
#   comment kinds       -> minimize as SPAM
#   discussion          -> close (outdated), lock (spam)
#   author              -> blocked at user level and in every org where the
#                          token holder is an active admin (maintainer token
#                          only; GITHUB_TOKEN cannot block, so the pulse sweep
#                          completes the ban)
#
# Invariants:
#   - NEVER posts a comment (spam closures get no attention or notification).
#   - NEVER resolves, fetches or opens the link (lexical detection only).
#   - NEVER acts on OWNER/MEMBER/COLLABORATOR authors, repo collaborators, or bots.
#     #aidevops:trust-boundary
#   - Log lines carry host names only, never the spam URL.
#
# Usage:
#   redirect-link-guard-helper.sh scan [--file PATH]          exit 1 if redirect link found
#   redirect-link-guard-helper.sh enforce-event EVENT_NAME EVENT_JSON_PATH [REPO]
#   redirect-link-guard-helper.sh enforce-issue REPO NUMBER   (issue or PR)
#   redirect-link-guard-helper.sh block LOGIN [REPO]
#   redirect-link-guard-helper.sh sweep [--repo OWNER/REPO] [--force] [--dry-run]
#
# Module use (sourced by pulse-wrapper.sh): redirect_spam_sweep_all_repos
#
# Environment:
#   DRY_RUN=1                              print actions only
#   REDIRECT_SPAM_SWEEP_INTERVAL=900       pulse cadence gate (seconds)
#   REDIRECT_SPAM_SWEEP_LOOKBACK=604800    first-run lookback (seconds)

[[ -n "${_REDIRECT_LINK_GUARD_LOADED:-}" ]] && return 0 2>/dev/null
_REDIRECT_LINK_GUARD_LOADED=1

_RLG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
[[ -f "${_RLG_DIR}/shared-constants.sh" ]] && source "${_RLG_DIR}/shared-constants.sh" 2>/dev/null

_RLG_SCANNER="${_RLG_DIR}/redirect_link_policy.py"
_RLG_SPAM_LABEL="spam"
_RLG_STATE_DIR="${REDIRECT_SPAM_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
REDIRECT_SPAM_SWEEP_INTERVAL="${REDIRECT_SPAM_SWEEP_INTERVAL:-900}"
REDIRECT_SPAM_SWEEP_LOOKBACK="${REDIRECT_SPAM_SWEEP_LOOKBACK:-604800}"
REDIRECT_SPAM_SWEEP_LAST_RUN="${REDIRECT_SPAM_SWEEP_LAST_RUN:-${HOME}/.aidevops/logs/redirect-spam-sweep-last-run}"
_RLG_ADMIN_ORGS=""
_RLG_ADMIN_ORGS_LOADED=0

_rlg_log() {
	local message="$1"
	printf '[redirect-link-guard] %s\n' "$message" >&2
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[redirect-link-guard] %s\n' "$message" >>"$LOGFILE" 2>/dev/null || true
	fi
	return 0
}

_rlg_dry_run() {
	[[ "${DRY_RUN:-0}" == "1" ]]
	return $?
}

# Run a mutating gh command unless dry-run. Failures are logged, not fatal.
_rlg_gh_write() {
	local description="$1"
	shift
	if _rlg_dry_run; then
		_rlg_log "DRY-RUN would ${description}"
		return 0
	fi
	if gh "$@" >/dev/null 2>&1; then
		_rlg_log "${description}: ok"
		return 0
	fi
	_rlg_log "${description}: failed (non-fatal)"
	return 1
}

# Scan text on stdin. Prints comma-separated hosts; returns 0 when a redirect
# link is found, 1 when clean, 2 on scanner error (fail closed for callers
# that need certainty; enforcement treats 2 as "do nothing, log").
_rlg_scan_stdin() {
	local output=""
	local status=0
	output="$(python3 "$_RLG_SCANNER" scan)" || status=$?
	if [[ "$status" -eq 1 ]]; then
		printf '%s' "$output" | jq -r '[.redirect_links[].host] | unique | join(",")' 2>/dev/null || true
		return 0
	fi
	[[ "$status" -eq 0 ]] && return 1
	_rlg_log "scanner error (exit ${status})"
	return 2
}

_rlg_is_trusted() {
	local association="$1"
	local login="$2"
	local user_type="${3:-User}"
	case "$association" in
	OWNER | MEMBER | COLLABORATOR) return 0 ;;
	*) ;;
	esac
	[[ "$user_type" == "Bot" || "$login" == *"[bot]" || -z "$login" ]] && return 0
	return 1
}

# #aidevops:trust-boundary — confirm the author has no push access before
# blocking, independent of the event's author_association field.
_rlg_is_repo_collaborator() {
	local repo="$1"
	local login="$2"
	[[ -n "$repo" ]] || return 1
	gh api "repos/${repo}/collaborators/${login}" --silent >/dev/null 2>&1
	return $?
}

_rlg_admin_orgs() {
	if [[ "$_RLG_ADMIN_ORGS_LOADED" -eq 0 ]]; then
		_RLG_ADMIN_ORGS="$(gh api user/memberships/orgs --paginate \
			--jq '.[] | select(.role == "admin" and .state == "active") | .organization.login' 2>/dev/null || true)"
		_RLG_ADMIN_ORGS_LOADED=1
	fi
	printf '%s' "$_RLG_ADMIN_ORGS"
	return 0
}

# Block LOGIN at user level and in every org where the token holder is admin.
rlg_block_user() {
	local login="$1"
	local repo="${2:-}"
	local association="${3:-NONE}"
	local user_type="${4:-User}"
	local org=""
	if [[ ! "$login" =~ ^[A-Za-z0-9-]{1,39}$ ]]; then
		_rlg_log "block skipped: invalid login"
		return 1
	fi
	if _rlg_is_trusted "$association" "$login" "$user_type"; then
		_rlg_log "block skipped: ${login} is trusted (${association})"
		return 1
	fi
	if _rlg_is_repo_collaborator "$repo" "$login"; then
		_rlg_log "block skipped: ${login} is a collaborator on ${repo}"
		return 1
	fi
	if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
		_rlg_log "block deferred to pulse sweep: Actions tokens cannot block users"
		return 0
	fi
	_rlg_gh_write "block ${login} (user level)" api -X PUT "user/blocks/${login}" || true
	while IFS= read -r org; do
		[[ -n "$org" ]] || continue
		_rlg_gh_write "block ${login} in org ${org}" api -X PUT "orgs/${org}/blocks/${login}" || true
	done <<<"$(_rlg_admin_orgs)"
	return 0
}

_rlg_ensure_label() {
	local repo="$1"
	_rlg_dry_run && return 0
	gh label create "$_RLG_SPAM_LABEL" --repo "$repo" --color "b60205" \
		--description "Spam: closed without comment" >/dev/null 2>&1 || true
	return 0
}

# Read author fields from a payload into _RLG_LOGIN/_RLG_ASSOC/_RLG_TYPE and
# return 0 only for untrusted authors (the only ones ever scanned/enforced).
_rlg_untrusted_author() {
	local payload="$1"
	_RLG_LOGIN="$(_rlg_jq "$payload" '.user.login // .author.login // empty')"
	_RLG_ASSOC="$(_rlg_jq "$payload" '.author_association // .authorAssociation // "NONE"')"
	_RLG_TYPE="$(_rlg_jq "$payload" '.user.type // "User"')"
	if _rlg_is_trusted "$_RLG_ASSOC" "$_RLG_LOGIN" "$_RLG_TYPE"; then
		return 1
	fi
	return 0
}

# Scan title+body of a payload; sets _RLG_HOSTS and returns 0 when found.
_rlg_scan_payload() {
	local payload="$1"
	_RLG_HOSTS="$(_rlg_jq "$payload" '[.title // "", .body // ""] | join("\n")' | _rlg_scan_stdin)"
	return $?
}

# Evaluate a jq filter against a JSON payload string.
_rlg_jq() {
	local payload="$1"
	local filter="$2"
	jq -r "$filter" <<<"$payload"
	return $?
}

# Close/label/lock an issue or PR. Idempotent: skips steps already applied.
_rlg_enforce_issue_payload() {
	local repo="$1"
	local payload="$2"
	local number="" state="" locked="" is_pr=""
	_rlg_untrusted_author "$payload" || return 1
	local login="$_RLG_LOGIN" association="$_RLG_ASSOC" user_type="$_RLG_TYPE"
	number="$(_rlg_jq "$payload" '.number')"
	_rlg_scan_payload "$payload" || return 1
	state="$(_rlg_jq "$payload" '.state // "open"')"
	locked="$(_rlg_jq "$payload" '.locked // false')"
	is_pr="$(_rlg_jq "$payload" 'if (.pull_request // null) != null or (.head // null) != null then "1" else "0" end')"
	_rlg_log "redirect link (${_RLG_HOSTS}) in ${repo}#${number} by ${login}"
	if ! jq -e --arg label "$_RLG_SPAM_LABEL" 'any(.labels[]?; .name == $label)' <<<"$payload" >/dev/null 2>&1; then
		_rlg_ensure_label "$repo"
		_rlg_gh_write "label ${repo}#${number} spam" api -X POST "repos/${repo}/issues/${number}/labels" \
			-f "labels[]=${_RLG_SPAM_LABEL}" || true
	fi
	if [[ "$state" == "open" ]]; then
		if [[ "$is_pr" == "1" ]]; then
			_rlg_gh_write "close PR ${repo}#${number}" api -X PATCH "repos/${repo}/pulls/${number}" -f state=closed || true
		else
			_rlg_gh_write "close issue ${repo}#${number}" api -X PATCH "repos/${repo}/issues/${number}" \
				-f state=closed -f state_reason=not_planned || true
		fi
	fi
	if [[ "$locked" != "true" ]]; then
		_rlg_gh_write "lock ${repo}#${number}" api -X PUT "repos/${repo}/issues/${number}/lock" -f lock_reason=spam || true
	fi
	rlg_block_user "$login" "$repo" "$association" "$user_type" || true
	return 0
}

# Minimize a comment (issue, review or discussion comment) as SPAM.
_rlg_enforce_comment_payload() {
	local repo="$1"
	local payload="$2"
	local node_id=""
	_rlg_untrusted_author "$payload" || return 1
	local login="$_RLG_LOGIN" association="$_RLG_ASSOC" user_type="$_RLG_TYPE"
	node_id="$(_rlg_jq "$payload" '.node_id // empty')"
	_rlg_scan_payload "$payload" || return 1
	_rlg_log "redirect link (${_RLG_HOSTS}) in comment on ${repo} by ${login}"
	if [[ -n "$node_id" ]]; then
		# shellcheck disable=SC2016 # GraphQL variables, not shell expansion
		_rlg_gh_write "minimize comment as spam on ${repo}" api graphql \
			-f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:SPAM}){clientMutationId}}' \
			-f id="$node_id" || true
	fi
	rlg_block_user "$login" "$repo" "$association" "$user_type" || true
	return 0
}

_rlg_enforce_discussion_payload() {
	local repo="$1"
	local payload="$2"
	local node_id="" number=""
	_rlg_untrusted_author "$payload" || return 1
	local login="$_RLG_LOGIN" association="$_RLG_ASSOC" user_type="$_RLG_TYPE"
	node_id="$(_rlg_jq "$payload" '.node_id // empty')"
	number="$(_rlg_jq "$payload" '.number // empty')"
	_rlg_scan_payload "$payload" || return 1
	_rlg_log "redirect link (${_RLG_HOSTS}) in discussion ${repo}#${number} by ${login}"
	if [[ -n "$node_id" ]]; then
		# shellcheck disable=SC2016 # GraphQL variables, not shell expansion
		_rlg_gh_write "close discussion ${repo}#${number}" api graphql \
			-f query='mutation($id:ID!){closeDiscussion(input:{discussionId:$id,reason:OUTDATED}){clientMutationId}}' \
			-f id="$node_id" || true
		# shellcheck disable=SC2016 # GraphQL variables, not shell expansion
		_rlg_gh_write "lock discussion ${repo}#${number}" api graphql \
			-f query='mutation($id:ID!){lockLockable(input:{lockableId:$id,lockReason:SPAM}){clientMutationId}}' \
			-f id="$node_id" || true
	fi
	rlg_block_user "$login" "$repo" "$association" "$user_type" || true
	return 0
}

# Enforce from a GitHub Actions event payload. Payload text is only ever read
# through jq from the event file — never interpolated into shell.
rlg_enforce_event() {
	local event_name="$1"
	local event_path="$2"
	local repo="${3:-${GITHUB_REPOSITORY:-}}"
	local payload=""
	if [[ ! -f "$event_path" || -z "$repo" ]]; then
		_rlg_log "enforce-event: missing event file or repository"
		return 2
	fi
	case "$event_name" in
	issues) payload="$(jq -c '.issue' "$event_path")" ;;
	pull_request | pull_request_target) payload="$(jq -c '.pull_request' "$event_path")" ;;
	issue_comment | pull_request_review_comment | discussion_comment)
		payload="$(jq -c '.comment' "$event_path")"
		_rlg_enforce_comment_payload "$repo" "$payload" || true
		return 0
		;;
	discussion)
		payload="$(jq -c '.discussion' "$event_path")"
		_rlg_enforce_discussion_payload "$repo" "$payload" || true
		return 0
		;;
	*)
		_rlg_log "enforce-event: unsupported event ${event_name}"
		return 0
		;;
	esac
	_rlg_enforce_issue_payload "$repo" "$payload" || true
	return 0
}

rlg_enforce_issue() {
	local repo="$1"
	local number="$2"
	local payload=""
	payload="$(gh api "repos/${repo}/issues/${number}" 2>/dev/null)" || {
		_rlg_log "enforce-issue: cannot read ${repo}#${number}"
		return 2
	}
	_rlg_enforce_issue_payload "$repo" "$payload" || true
	return 0
}

_rlg_iso_ago() {
	local seconds="$1"
	python3 -c 'import datetime, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[1]))
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$seconds"
	return 0
}

_rlg_state_file() {
	local repo="$1"
	printf '%s/redirect-spam-sweep-%s.since' "$_RLG_STATE_DIR" "${repo//\//__}"
	return 0
}

# Enforce every untrusted item from one paginated REST list endpoint.
_rlg_sweep_endpoint() {
	local repo="$1"
	local endpoint="$2"
	local handler="$3"
	local item=""
	local untrusted_filter='.[] | select((.author_association // "NONE") | IN("OWNER","MEMBER","COLLABORATOR") | not) | select((.user.type // "User") != "Bot") | @json'
	while IFS= read -r item; do
		[[ -n "$item" ]] || continue
		"$handler" "$repo" "$item" || true
	done < <(gh api "$endpoint" --paginate --jq "$untrusted_filter" 2>/dev/null || true)
	return 0
}

# Sweep one repo: issues/PRs, issue comments and review comments updated since
# the last checkpoint. Untrusted authors only; trusted items are not scanned.
rlg_sweep_repo() {
	local repo="$1"
	local state_file="" since="" started=""
	state_file="$(_rlg_state_file "$repo")"
	since="$(cat "$state_file" 2>/dev/null || true)"
	[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || since="$(_rlg_iso_ago "$REDIRECT_SPAM_SWEEP_LOOKBACK")"
	started="$(_rlg_iso_ago 60)"
	_rlg_sweep_endpoint "$repo" "repos/${repo}/issues?state=all&since=${since}&per_page=100" _rlg_enforce_issue_payload
	_rlg_sweep_endpoint "$repo" "repos/${repo}/issues/comments?since=${since}&per_page=100" _rlg_enforce_comment_payload
	_rlg_sweep_endpoint "$repo" "repos/${repo}/pulls/comments?since=${since}&per_page=100" _rlg_enforce_comment_payload
	if ! _rlg_dry_run; then
		mkdir -p "$_RLG_STATE_DIR" 2>/dev/null || true
		printf '%s\n' "$started" >"$state_file" 2>/dev/null || true
	fi
	return 0
}

_rlg_sweep_due() {
	local now="" last=""
	now="$(date +%s)"
	last="$(cat "$REDIRECT_SPAM_SWEEP_LAST_RUN" 2>/dev/null || printf '0')"
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	[[ $((now - last)) -ge "$REDIRECT_SPAM_SWEEP_INTERVAL" ]]
	return $?
}

_rlg_mark_run() {
	_rlg_dry_run && return 0
	mkdir -p "$(dirname "$REDIRECT_SPAM_SWEEP_LAST_RUN")" 2>/dev/null || true
	date +%s >"$REDIRECT_SPAM_SWEEP_LAST_RUN" 2>/dev/null || true
	return 0
}

# Pulse entry point: interval-gated sweep over maintainer-role repos.
redirect_spam_sweep_all_repos() {
	local force="${1:-0}"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local repo=""
	if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
		return 0
	fi
	if [[ "$force" != "1" ]] && ! _rlg_sweep_due; then
		return 0
	fi
	[[ -f "$repos_json" ]] || return 0
	while IFS= read -r repo; do
		[[ -n "$repo" ]] || continue
		if declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 &&
			! repo_allows_pulse_write_actions "$repo"; then
			continue
		fi
		rlg_sweep_repo "$repo" || true
		if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
			break
		fi
	done < <(jq -r '.initialized_repos[] | select((.local_only // false) == false and (.slug // "") != "") | .slug' "$repos_json" 2>/dev/null)
	_rlg_mark_run
	return 0
}

_rlg_usage() {
	sed -n '4,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

_rlg_sweep_cli() {
	local repo="" force=0 arg=""
	local -a args=("$@")
	local index=0
	while [[ "$index" -lt "${#args[@]}" ]]; do
		arg="${args[$index]}"
		case "$arg" in
		--repo)
			index=$((index + 1))
			repo="${args[$index]:-}"
			;;
		--force) force=1 ;;
		--dry-run) export DRY_RUN=1 ;;
		*) ;;
		esac
		index=$((index + 1))
	done
	if [[ -n "$repo" ]]; then
		rlg_sweep_repo "$repo"
		return $?
	fi
	redirect_spam_sweep_all_repos "$force"
	return $?
}

_rlg_main() {
	local command="${1:-help}"
	local first="${2:-}"
	local second="${3:-}"
	local third="${4:-}"
	shift || true
	case "$command" in
	scan)
		if [[ "$first" == "--file" && -n "$second" ]]; then
			python3 "$_RLG_SCANNER" scan --file "$second"
			return $?
		fi
		python3 "$_RLG_SCANNER" scan
		return $?
		;;
	enforce-event)
		rlg_enforce_event "$first" "$second" "$third"
		return $?
		;;
	enforce-issue)
		rlg_enforce_issue "$first" "$second"
		return $?
		;;
	block)
		rlg_block_user "$first" "$second"
		return $?
		;;
	sweep)
		_rlg_sweep_cli "$@"
		return $?
		;;
	help | --help | -h)
		_rlg_usage
		return 0
		;;
	*)
		_rlg_usage
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_rlg_main "$@"
	exit $?
fi

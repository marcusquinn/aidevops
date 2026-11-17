#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ -n "${_DEPENDENCY_EVENT_RECONCILER_LOADED:-}" ]] && return 0
_DEPENDENCY_EVENT_RECONCILER_LOADED=1
DER_SEARCH_QUOTE=$(printf '\042')
DER_STATE_CLOSED="CLOSED"
DER_NOT_READY=2
DER_SWEEP_PARTIAL=3
_DER_NATIVE_BLOCKERS_PRESENT=false

_der_dir="${BASH_SOURCE[0]%/*}"
[[ "$_der_dir" == "${BASH_SOURCE[0]}" ]] && _der_dir="."
: "${DER_WORKER_BLOCKER_LOGGER:=${_der_dir}/worker-blocker-log.mjs}"
DER_BLOCKED_BY_VALUE_AWK="${_der_dir}/blocked-by-value.awk"
# shellcheck source=./issue-hold-marker-lib.sh
source "${_der_dir}/issue-hold-marker-lib.sh"
# shellcheck source=./task-identity-lib.sh
source "${_der_dir}/task-identity-lib.sh"
# shellcheck source=./dependency-supersession-lib.sh
source "${_der_dir}/dependency-supersession-lib.sh"
# shellcheck source=./dependency-supersession-repoint-lib.sh
source "${_der_dir}/dependency-supersession-repoint-lib.sh"
# shellcheck source=./upstream-release-gate-lib.sh
source "${_der_dir}/upstream-release-gate-lib.sh"
unset _der_dir

_der_reconcile_terminal_worker_blockers() {
	local repo="$1"
	local issue_number="$2"
	local logger="${DER_WORKER_BLOCKER_LOGGER}"

	if [[ "$repo" != */* || ! "$issue_number" =~ ^[0-9]+$ || ! -f "$logger" || -L "$logger" ]]; then
		return 1
	fi
	command -v node >/dev/null 2>&1 || return 1
	if node "$logger" resolve-issue \
		--repo-slug "$repo" \
		--issue-number "$issue_number" \
		--event "issue_terminal_reconciled" \
		--status "resolved" \
		--reason "issue_closed_verified" \
		--source "dependency-event-reconciler" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Emit each blocked-by declaration from its label to end of line, with the value
# reduced by the shared grammar (GH#33881). "none (t136 merged)" yields no refs,
# and a leading list stops before trailing prose. Prose-led values stay whole
# (fail closed). Without the grammar file, whole-line extraction is kept.
_der_dependency_text() {
	local body="$1"
	local matches=""
	matches=$(printf '%s' "$body" | grep -ioE 'blocked[- ][Bb]y[^[:cntrl:]]*' || true)
	[[ -n "$matches" ]] || return 0
	if [[ -r "$DER_BLOCKED_BY_VALUE_AWK" ]]; then
		awk -f "$DER_BLOCKED_BY_VALUE_AWK" <<<"$matches" || printf '%s\n' "$matches"
	else
		printf '%s\n' "$matches"
	fi
	return 0
}

_der_issue_refs() {
	local text="$1"
	_der_dependency_text "$text" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -u || true
	return 0
}

_der_task_refs() {
	local text="$1"
	task_identity_extract_all "$(_der_dependency_text "$text")" | sort -u || true
	return 0
}

_der_todo_blocker_tokens_valid() {
	local text="$1"
	local marker=""
	local value=""
	local token=""
	local marker_count=0

	while IFS= read -r marker; do
		[[ -n "$marker" ]] || continue
		marker_count=$((marker_count + 1))
		value="${marker#*blocked-by:}"
		[[ -n "$value" ]] || return 1
		while IFS= read -r token; do
			[[ -n "$token" ]] || return 1
			if [[ "$token" =~ ^#[0-9]+$ ]]; then
				continue
			fi
			task_identity_validate "$token" || return 1
		done <<<"${value//,/$'\n'}"
	done < <(printf '%s\n' "$text" | grep -oE '(^|[[:space:]])blocked-by:[^[:space:]]+' || true)

	[[ "$marker_count" -gt 0 ]] || return 1
	return 0
}

_der_labels_have_hold() {
	local labels="$1"
	local expected=""
	# GH#38360: a human-owned blocked companion outlives a closed dependency.
	for expected in needs-maintainer-review needs-maintainer-permissions needs-maintainer-input needs-credentials $ISSUE_HUMAN_HOLD_LABELS; do
		_der_labels_has "$labels" "$expected" && return 0
	done
	return 1
}

# Strong machine hold markers. Terminal-blocker vocabulary counts only in
# trusted comments: the runtime records terminal blockers as comments
# (_apply_terminal_blocker, terminal-blocker-circuit.sh), while issue bodies
# document the worker protocol (`TERMINAL_BLOCKER_REASON=...`) as instructions.
DER_STRONG_HOLD_RE='HUMAN_UNBLOCK_REQUIRED|Worker Watchdog Kill|ACTION REQUIRED|worker[_ -]blocked|aidevops:brief-hold'
DER_TERMINAL_BLOCKER_RE='Terminal[_ -]blocker([_ -]detected)?|^CLAIM_RELEASED reason=blocked([[:space:]]|$)'
# jq (Oniguruma) twin of DER_TERMINAL_BLOCKER_RE; ^ is line-anchored via \n.
DER_TERMINAL_BLOCKER_RE_JQ='Terminal[_ -]blocker|^CLAIM_RELEASED reason=blocked(\s|$)'

# $1: issue body plus trusted comments; $2: trusted comments only.
_der_text_has_strong_hold() {
	local text="$1"
	local comments="${2:-}"
	printf '%s\n' "$text" | grep -qiE "$DER_STRONG_HOLD_RE" && return 0
	printf '%s\n' "$comments" | grep -qiE "$DER_TERMINAL_BLOCKER_RE" && return 0
	if printf '%s\n' "$text" | grep -qiE '\*\*BLOCKED\*\*' &&
		printf '%s\n' "$text" | grep -qiE 'cannot proceed'; then
		return 0
	fi
	return 1
}

_der_has_hold() {
	local body="$1"
	local comments="$2"
	local labels="$3"
	local comments_json="${4:-}"
	if [[ -n "$comments_json" ]] && declare -F issue_has_active_brief_hold >/dev/null 2>&1 &&
		! issue_has_active_brief_hold "$comments_json" "$body"; then
		# Historical markers refer to an older body, not the current hold.
		comments="${comments//aidevops:brief-hold/expired-brief-hold}"
	fi
	local text="${body}"$'\n'"${comments}"
	_der_labels_have_hold "$labels" || _der_text_has_strong_hold "$text" "$comments" || issue_hold_text_has_operational_hold "$text"
	return $?
}

_der_labels_has() {
	local labels="$1"
	local expected="$2"
	[[ ",${labels}," == *",${expected},"* ]]
	return $?
}

_der_json_pages_valid() {
	local pages="$1"
	printf '%s' "$pages" | jq -e 'type == "array" and all(.[]; type == "array")' >/dev/null 2>&1
	return $?
}

_der_seen_has() {
	local seen="$1"
	local issue_number="$2"
	[[ "$seen" == *",${issue_number},"* ]]
	return $?
}

_der_seen_add() {
	local seen="$1"
	local issue_number="$2"
	printf '%s%s,' "$seen" "$issue_number"
	return 0
}

_der_has_active_status() {
	local labels="$1"
	_der_labels_has "$labels" status:queued || _der_labels_has "$labels" status:claimed ||
		_der_labels_has "$labels" status:in-progress || _der_labels_has "$labels" status:in-review ||
		_der_labels_has "$labels" status:done
	return $?
}

_der_fetch_closed_context() {
	local owner="$1"
	local name="$2"
	local closed_number="$3"
	# shellcheck disable=SC2016
	gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    nameWithOwner
    issue(number:$number) {
      number state title
      blocking(first:100) {
        nodes { number state title body repository { nameWithOwner } labels(first:100) { nodes { name } pageInfo { hasNextPage } } }
        pageInfo { hasNextPage }
      }
    }
  }
}' -F owner="$owner" -F name="$name" -F number="$closed_number" 2>/dev/null
	return $?
}

# Search is deliberately capped. More than 100 matches, another page, malformed
# nodes, or a repository mismatch is ambiguity and therefore blocks mutation.
_der_search_issues() {
	local repo="$1"
	local search_query="$2"
	local result=""
	# shellcheck disable=SC2016
	result=$(gh api graphql -f query='
query($searchQuery:String!) {
  search(query:$searchQuery,type:ISSUE,first:100) {
    issueCount pageInfo { hasNextPage }
    nodes {
      __typename
      ... on Issue {
        number state title body repository { nameWithOwner }
        labels(first:100) { nodes { name } pageInfo { hasNextPage } }
      }
    }
  }
}' -F searchQuery="$search_query" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -ce --arg repo "$repo" '
      .data.search
      | select((.issueCount | type) == "number" and .issueCount <= 100)
      | select(.pageInfo.hasNextPage == false)
      | select(all(.nodes[];
          .__typename == "Issue"
          and .repository.nameWithOwner == $repo
          and .labels.pageInfo.hasNextPage == false))
      | .nodes' 2>/dev/null
	return $?
}

# Text that declares a candidate's blockers: its body plus label names.
_der_candidate_dependency_text() {
	local candidate_json="$1"
	printf '%s' "$candidate_json" | jq -r '(.body // "") + "\n" + ([.labels.nodes[].name] | join("\n"))'
	return $?
}

_der_candidate_declares() {
	local candidate_json="$1"
	local closed_number="$2"
	local closed_task_id="$3"
	local text="" ref=""
	text=$(_der_candidate_dependency_text "$candidate_json") || return 1
	while IFS= read -r ref; do
		[[ "$ref" == "$closed_number" ]] && return 0
	done < <(_der_issue_refs "$text")
	if [[ -n "$closed_task_id" ]]; then
		while IFS= read -r ref; do
			[[ "$ref" == "$closed_task_id" ]] && return 0
		done < <(_der_task_refs "$text")
	fi
	return 1
}

_der_collect_candidates() {
	local repo="$1"
	local closed_number="$2"
	local closed_task_id="$3"
	local context="$4"
	local query="" result="" number="" seen="," candidate_repo="" candidate_key=""
	local candidate
	local native_numbers=""
	local quote="$DER_SEARCH_QUOTE"
	native_numbers=$(printf '%s' "$context" | jq -r '.data.repository.issue.blocking.nodes[].number' 2>/dev/null) || return 1

	for query in \
		"repo:${repo} is:issue is:open in:body ${quote}#${closed_number}${quote}" \
		"repo:${repo} is:issue is:open label:${quote}blocked-by:#${closed_number}${quote}" \
		"repo:${repo} is:issue is:open label:${quote}blocked-by:GH#${closed_number}${quote}"; do
		result=$(_der_search_issues "$repo" "$query") || return 1
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			_der_candidate_declares "$candidate" "$closed_number" "$closed_task_id" || continue
			number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
			candidate_key="${repo}#${number}"
			_der_seen_has "$seen" "$candidate_key" && continue
			printf '%s\n' "$candidate"
			seen=$(_der_seen_add "$seen" "$candidate_key")
		done < <(printf '%s' "$result" | jq -c '.[]')
	done

	if [[ -n "$closed_task_id" ]]; then
		for query in \
			"repo:${repo} is:issue is:open in:body ${quote}${closed_task_id}${quote}" \
			"repo:${repo} is:issue is:open label:${quote}blocked-by:${closed_task_id}${quote}"; do
			result=$(_der_search_issues "$repo" "$query") || return 1
			while IFS= read -r candidate; do
				[[ -n "$candidate" ]] || continue
				_der_candidate_declares "$candidate" "$closed_number" "$closed_task_id" || continue
				number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
				candidate_key="${repo}#${number}"
				_der_seen_has "$seen" "$candidate_key" && continue
				printf '%s\n' "$candidate"
				seen=$(_der_seen_add "$seen" "$candidate_key")
			done < <(printf '%s' "$result" | jq -c '.[]')
		done
	fi

	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
		candidate_repo=$(printf '%s' "$candidate" | jq -r '.repository.nameWithOwner // ""') || return 1
		[[ "$candidate_repo" == */* ]] || return 1
		candidate_key="${candidate_repo}#${number}"
		_der_seen_has "$seen" "$candidate_key" && continue
		printf '%s\n' "$candidate"
		seen=$(_der_seen_add "$seen" "$candidate_key")
	done < <(printf '%s' "$context" | jq -c '.data.repository.issue.blocking.nodes[]')
	# Empty native relationships are valid; ensure malformed extraction did not
	# silently turn a non-empty connection into no candidates.
	[[ -z "$native_numbers" || "$native_numbers" =~ ^[0-9] ]] || return 1
	return 0
}

_der_live_issue_closed() {
	local repo="$1"
	local issue_number="$2"
	local state=""
	state=$(gh issue view "$issue_number" --repo "$repo" --json state --jq '.state' 2>/dev/null) || return 1
	[[ "$state" == "$DER_STATE_CLOSED" || "$state" == "closed" ]] && return 0
	[[ "$state" == "OPEN" || "$state" == "open" ]] && return "$DER_NOT_READY"
	return 1
}

# Declared-blocker check. A dependant ref ("owner/repo#N") selects the readiness
# rule (GH#34341): a blocker closed as superseded is not ready while its
# successor chain is open. Completion checks omit it and keep closed-is-done.
_der_live_blocker_resolved() {
	local repo="$1"
	local issue_number="$2"
	local dependant_ref="${3:-}"
	local row="" state="" reason=""
	if [[ -z "$dependant_ref" ]]; then
		_der_live_issue_closed "$repo" "$issue_number"
		return $?
	fi
	row=$(gh issue view "$issue_number" --repo "$repo" --json state,stateReason --jq '"\(.state):\(.stateReason // "")"' 2>/dev/null) || return 1
	IFS=':' read -r state reason <<<"$row"
	case "$state" in
	"$DER_STATE_CLOSED" | closed) ;;
	OPEN | open) return "$DER_NOT_READY" ;;
	*) return 1 ;;
	esac
	dep_supersession_blocks "[dependency-reconciler] ${dependant_ref}" "$repo" "$issue_number" "$reason" "$dependant_ref" && return "$DER_NOT_READY"
	return 0
}

_der_find_task_issue() {
	local repo="$1"
	local task_id="$2"
	local result="" parsed="" number="" match="" count=0
	local candidate
	local quote="$DER_SEARCH_QUOTE"
	task_identity_validate "$task_id" || return 1
	result=$(_der_search_issues "$repo" "repo:${repo} is:issue in:title ${quote}${task_id}:${quote}") || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		parsed=$(task_identity_parse_title_prefix "$(printf '%s' "$candidate" | jq -r '.title')" || true)
		[[ "$parsed" == "$task_id" ]] || continue
		number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
		match="$number"
		count=$((count + 1))
	done < <(printf '%s' "$result" | jq -c '.[]')
	[[ "$count" -eq 1 && "$match" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$match"
	return 0
}

# Positive dependency evidence without a native edge: a declared blocker ref in
# the body or a blocked-by: label (cf. _hold_dependency_sync_retry). A jq
# failure counts as no evidence, so the caller leaves the issue blocked.
_der_declares_blockers() {
	local candidate_json="$1"
	local text="" refs=""
	text=$(_der_candidate_dependency_text "$candidate_json" 2>/dev/null) || return 1
	refs=$(_der_issue_refs "$text")
	[[ -n "$refs" ]] && return 0
	refs=$(_der_task_refs "$text")
	[[ -n "$refs" ]]
	return $?
}

# Optional $3 dependant ref selects the readiness rule (_der_live_blocker_resolved).
_der_all_declared_blockers_closed() {
	local repo="$1"
	local candidate_json="$2"
	local dependant_ref="${3:-}"
	local blocker="" task_id="" issue_number="" text=""
	text=$(_der_candidate_dependency_text "$candidate_json") || return 1
	while IFS= read -r blocker; do
		[[ -n "$blocker" ]] || continue
		_der_live_blocker_resolved "$repo" "$blocker" "$dependant_ref" || return $?
	done < <(_der_issue_refs "$text")
	while IFS= read -r task_id; do
		[[ -n "$task_id" ]] || continue
		issue_number=$(_der_find_task_issue "$repo" "$task_id") || return 1
		_der_live_blocker_resolved "$repo" "$issue_number" "$dependant_ref" || return $?
	done < <(_der_task_refs "$text")
	return 0
}

# Optional $3 "readiness" also keeps blockers closed as superseded not ready
# while their successor chain is open (GH#34341); completion checks omit it.
_der_native_blockers_closed() {
	local repo="$1"
	local issue_number="$2"
	local mode="${3:-}"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local result="" blocker_count="" nodes="" node_repo="" node_number="" node_reason=""
	_DER_NATIVE_BLOCKERS_PRESENT=false
	# shellcheck disable=SC2016
	result=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){blockedBy(first:100){nodes{number state stateReason repository{nameWithOwner}}pageInfo{hasNextPage}}}}}' -F o="$owner" -F r="$name" -F n="$issue_number" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -e --arg closed "$DER_STATE_CLOSED" '
      def is_object: type == "object";
      def is_array: type == ([] | type);
      .data.repository.issue.blockedBy
      | is_object
        and (.pageInfo | is_object)
        and .pageInfo.hasNextPage == false
        and (.nodes | is_array)
        and all(.nodes[];
          is_object
          and (.number | type == "number")
          and (.state == "OPEN" or .state == $closed)
          and (.repository | is_object)
          and (.repository.nameWithOwner | type == "string")
          and (.repository.nameWithOwner | test("^[^/[:space:]]+/[^/[:space:]]+$")))' >/dev/null 2>&1 || return 1
	blocker_count=$(printf '%s' "$result" | jq -r '.data.repository.issue.blockedBy.nodes | length' 2>/dev/null) || return 1
	if [[ "$blocker_count" -gt 0 ]]; then
		_DER_NATIVE_BLOCKERS_PRESENT=true
	fi
	printf '%s' "$result" | jq -e --arg closed "$DER_STATE_CLOSED" '
      all(.data.repository.issue.blockedBy.nodes[]; .state == $closed)' >/dev/null 2>&1 || return "$DER_NOT_READY"
	[[ "$mode" == "readiness" ]] || return 0
	nodes=$(printf '%s' "$result" | jq -r '.data.repository.issue.blockedBy.nodes[] | "\(.repository.nameWithOwner) \(.number) \(.stateReason // "")"' 2>/dev/null) || return 1
	while read -r node_repo node_number node_reason; do
		[[ -n "$node_repo" ]] || continue
		dep_supersession_blocks "[dependency-reconciler] ${repo}#${issue_number}" "$node_repo" "$node_number" "$node_reason" "${repo}#${issue_number}" && return "$DER_NOT_READY"
	done <<<"$nodes"
	return 0
}

_der_completion_blockers_closed() {
	local repo="$1"
	local issue_number="$2"
	local dependency_text="$3"
	local candidate_json=""

	[[ "$repo" == */* && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	_der_todo_blocker_tokens_valid "$dependency_text" || return 1
	candidate_json=$(jq -cn --arg body "$dependency_text" \
		'{body: $body, labels: {nodes: []}}') || return 1
	_der_native_blockers_closed "$repo" "$issue_number" || return $?
	[[ "$_DER_NATIVE_BLOCKERS_PRESENT" == true ]] && return 0
	_der_all_declared_blockers_closed "$repo" "$candidate_json"
	return $?
}

# GH#37696: upstream-release gates count only on an issue whose author is
# trusted; the body is editable only by its author and write collaborators.
_der_upstream_gates_ready() {
	local repo="$1"
	local issue_number="$2"
	local body="$3"
	local association=""
	association=$(gh api "repos/${repo}/issues/${issue_number}" --jq '.author_association // ""' 2>/dev/null) || return 1
	# aidevops:trust-boundary — an untrusted author cannot self-unblock via a gate.
	case "$association" in
	OWNER | MEMBER | COLLABORATOR) ;;
	*) return "$DER_NOT_READY" ;;
	esac
	upstream_release_gates_ready "$body" "[dependency-reconciler] ${repo}#${issue_number}"
	return $?
}

# GH#38866: a terminal-blocker observation older than the latest transition to
# needs-dependency was superseded by that recovery decision; the dependency pass
# owns release. Prints trusted comment bodies minus the terminal-blocker lines of
# such superseded observations (other hold text is kept). Fails closed
# (non-zero) when the label history is unreadable or has no transition.
_der_comments_after_dependency_conversion() {
	local repo="$1"
	local issue_number="$2"
	local comments_json="$3"
	local events="" cutoff=""
	events=$(gh api --paginate --slurp "repos/${repo}/issues/${issue_number}/events?per_page=100" 2>/dev/null) || return 1
	cutoff=$(printf '%s' "$events" | jq -r '[.[][] | select(.event == "labeled" and .label.name == "needs-dependency") | .created_at] | max // ""' 2>/dev/null) || return 1
	[[ -n "$cutoff" ]] || return 1
	# aidevops:trust-boundary — only trusted comments are considered at all.
	# Older comments lose only their terminal-blocker lines, so every other hold
	# marker or operational hold in the same comment still counts.
	printf '%s' "$comments_json" | jq -r --arg cutoff "$cutoff" --arg tb "$DER_TERMINAL_BLOCKER_RE_JQ" '
		.[][] | select((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
		| (.body // "") as $body
		| if (.created_at // "9999") >= $cutoff then $body
		  else ($body | split("\n") | map(select(test($tb; "i") | not)) | join("\n")) end' 2>/dev/null
	return $?
}

_der_try_unblock() {
	local repo="$1"
	local issue_number="$2"
	local candidate_json="$3"
	local labels="" body="" comments_json="" comments="" upstream_gated=false
	_DER_RESULT=not_ready
	labels=$(printf '%s' "$candidate_json" | jq -r '[.labels.nodes[].name] | join(",")') || return 1
	body=$(printf '%s' "$candidate_json" | jq -r '.body // ""') || return 1
	_der_labels_has "$labels" status:blocked || return 0
	_der_has_active_status "$labels" && return 0
	comments_json=$(gh api --paginate --slurp "repos/${repo}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	_der_json_pages_valid "$comments_json" || return 1
	# aidevops:trust-boundary — external comments cannot assert a hold.
	comments=$(printf '%s' "$comments_json" | jq -r '.[][] | select((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR")) | .body // ""' 2>/dev/null) || return 1
	if _der_labels_has "$labels" needs-dependency; then
		local filtered=""
		# Unreadable label history keeps every observation (fail closed).
		if filtered=$(_der_comments_after_dependency_conversion "$repo" "$issue_number" "$comments_json"); then
			comments="$filtered"
		fi
	fi
	if _der_has_hold "$body" "$comments" "$labels" "$comments_json"; then
		_DER_RESULT=held
		return 0
	fi
	upstream_release_gate_declared "$body" && upstream_gated=true
	_der_native_blockers_closed "$repo" "$issue_number" readiness || return $?
	if [[ "$upstream_gated" == true ]]; then
		# GH#37696: a gated issue also honours every declared blocker, with or
		# without native edges; a text read failure returns 1, never "none".
		_der_all_declared_blockers_closed "$repo" "$candidate_json" "${repo}#${issue_number}" || return $?
		_der_upstream_gates_ready "$repo" "$issue_number" "$body" || return $?
	elif [[ "$_DER_NATIVE_BLOCKERS_PRESENT" != true ]]; then
		# No native edge and no declared blocker: status:blocked came from another
		# mechanism (cost breaker, infrastructure failure, sync retry hold) that
		# owns its own release.
		_der_declares_blockers "$candidate_json" || return 0
		_der_all_declared_blockers_closed "$repo" "$candidate_json" "${repo}#${issue_number}" || return $?
	fi
	labels=$(gh issue view "$issue_number" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
	_der_labels_has "$labels" status:blocked || return 0
	_der_has_active_status "$labels" && return 0
	# A human hold added after the initial check keeps the issue blocked.
	if _der_labels_have_hold "$labels"; then
		_DER_RESULT=held
		return 0
	fi
	# GH#38360: the dependency companion leaves together with status:blocked.
	local -a unblock_args=(--remove-label status:blocked --add-label status:available)
	_der_labels_has "$labels" needs-dependency && unblock_args+=(--remove-label needs-dependency)
	gh issue edit "$issue_number" --repo "$repo" "${unblock_args[@]}" >/dev/null 2>&1 || return 1
	_DER_RESULT=unblocked
	return 0
}

# Append-only retry records avoid losing concurrently recorded failures. A stale
# sweep consumes a snapshot; duplicate entries are harmless guarded retries.
_der_retry_append() {
	local repo="$1" kind="$2" number="$3"
	local dir="${DER_RETRY_DIR:-${HOME}/.aidevops/cache/dep-unblock-retry}"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$number" =~ ^[0-9]+$ ]] || return 1
	mkdir -p "$dir" || return 1
	printf '%s %s\n' "$kind" "$number" >>"${dir}/${repo//\//__}.txt" || return 1
	return 0
}

_der_closure_failure() {
	local repo="$1" number="$2" reason="$3"
	printf '[dependency-reconciler] closure repo=%s closed=#%s reason=%s dependants=0 unblocked=0 not_ready=0 held=0 failed=1\n' "$repo" "$number" "$reason" >&2
	_der_retry_append "$repo" closure "$number" || printf '[dependency-reconciler] retry ledger write failed repo=%s closed=#%s\n' "$repo" "$number" >&2
	return 1
}

# Reconcile only direct dependants after the named issue is positively closed.
reconcile_dependants_after_verified_closure() {
	local repo="$1"
	local closed_number="$2"
	local deadline="${3:-}"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local context="" closed_task_id="" candidates="" issue_number="" candidate_repo="" try_status=0
	local candidate count=0 unblocked=0 not_ready=0 held=0 failed=0 deferred=0
	[[ "$repo" == */* && "$closed_number" =~ ^[0-9]+$ && -n "$owner" && -n "$name" ]] || { _der_closure_failure "$repo" "$closed_number" invalid_input; return 1; }
	_der_live_issue_closed "$repo" "$closed_number" || { _der_closure_failure "$repo" "$closed_number" live_closed_check; return 1; }
	context=$(_der_fetch_closed_context "$owner" "$name" "$closed_number") || { _der_closure_failure "$repo" "$closed_number" context_fetch; return 1; }
	printf '%s' "$context" | jq -e --arg repo "$repo" --arg closed "$DER_STATE_CLOSED" '
      .data.repository.nameWithOwner == $repo
      and .data.repository.issue.state == $closed
      and .data.repository.issue.blocking.pageInfo.hasNextPage == false
      and all(.data.repository.issue.blocking.nodes[];
          (.repository.nameWithOwner | type == "string")
          and (.repository.nameWithOwner | test("^[^/[:space:]]+/[^/[:space:]]+$"))
          and .labels.pageInfo.hasNextPage == false)' >/dev/null 2>&1 || { _der_closure_failure "$repo" "$closed_number" invalid_context; return 1; }
	_der_reconcile_terminal_worker_blockers "$repo" "$closed_number" || true
	closed_task_id=$(task_identity_parse_title_prefix "$(printf '%s' "$context" | jq -r '.data.repository.issue.title')" || true)
	candidates=$(_der_collect_candidates "$repo" "$closed_number" "$closed_task_id" "$context") || { _der_closure_failure "$repo" "$closed_number" candidate_collection; return 1; }
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		count=$((count + 1))
		issue_number=$(printf '%s' "$candidate" | jq -r '.number') || issue_number=""
		candidate_repo=$(printf '%s' "$candidate" | jq -r '.repository.nameWithOwner // ""') || candidate_repo=""
		if [[ ! "$issue_number" =~ ^[0-9]+$ || "$candidate_repo" != */* ]]; then
			failed=$((failed + 1))
			_der_retry_append "$repo" closure "$closed_number" || true
			printf '[dependency-reconciler] invalid candidate repo=%s closed=#%s\n' "$repo" "$closed_number" >&2
			continue
		fi
		# Transfer unvisited dependants to individual retries instead of replaying
		# held predecessors on every bounded closure pass. Only acknowledge the
		# closure when every deferred candidate has been durably queued.
		if [[ -n "$deadline" ]] && _der_stale_epoch_reached "$deadline"; then
			if _der_retry_append "$candidate_repo" issue "$issue_number"; then
				deferred=$((deferred + 1))
			else
				failed=$((failed + 1))
				_der_closure_failure "$repo" "$closed_number" deferred_retry_write || true
			fi
			continue
		fi
		try_status=0
		_der_try_unblock "$candidate_repo" "$issue_number" "$candidate" || try_status=$?
		if [[ "$try_status" -ne 0 && "$try_status" -ne "$DER_NOT_READY" ]]; then
			failed=$((failed + 1))
			printf '[dependency-reconciler] dependant failed repo=%s issue=#%s status=%s\n' "$candidate_repo" "$issue_number" "$try_status" >&2
			_der_retry_append "$candidate_repo" issue "$issue_number" || printf '[dependency-reconciler] retry ledger write failed repo=%s issue=#%s\n' "$candidate_repo" "$issue_number" >&2
		elif [[ "$try_status" -eq "$DER_NOT_READY" ]]; then
			not_ready=$((not_ready + 1))
		else
			case "${_DER_RESULT:-not_ready}" in
			unblocked) unblocked=$((unblocked + 1)) ;;
			held) held=$((held + 1)) ;;
			*) not_ready=$((not_ready + 1)) ;;
			esac
		fi
	done <<<"$candidates"
	printf '[dependency-reconciler] closure repo=%s closed=#%s dependants=%s unblocked=%s not_ready=%s held=%s failed=%s deferred=%s\n' "$repo" "$closed_number" "$count" "$unblocked" "$not_ready" "$held" "$failed" "$deferred" >&2
	[[ "$failed" -eq 0 ]] || return 3
	return 0
}

# GH#33957: per-repo resume cursor (last visited issue number) so a bounded
# stage traverses every blocked issue across cycles instead of restarting.
_der_stale_cursor_file() {
	local repo="$1"
	local dir="${DER_STALE_BLOCKED_CURSOR_DIR:-}"
	if [[ -z "$dir" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		dir="${HOME}/.aidevops/cache/stale-blocked-cursor"
	fi
	printf '%s/%s.cursor\n' "$dir" "${repo//\//__}"
	return 0
}

_der_stale_cursor_read() {
	local file="$1"
	local value=""
	if [[ -f "$file" ]]; then
		IFS= read -r value <"$file" 2>/dev/null || true
	fi
	[[ "$value" =~ ^[0-9]+$ ]] || value=0
	printf '%s\n' "$value"
	return 0
}

_der_stale_cursor_write() {
	local file="$1"
	local value="$2"
	local tmp_file="${file}.tmp.$$"
	mkdir -p "${file%/*}" 2>/dev/null || return 1
	printf '%s\n' "$value" >"$tmp_file" 2>/dev/null || return 1
	mv -f "$tmp_file" "$file" 2>/dev/null || return 1
	return 0
}

_der_stale_epoch_reached() {
	local deadline="$1"
	local now=""
	[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 1
	now=$(date +%s 2>/dev/null) || return 0
	[[ "$now" -ge "$deadline" ]]
	return $?
}

_der_retry_drain() {
	local repo="$1" deadline="$2" kind="" retry_number="" candidate="" status=0 complete=true
	local file="${DER_RETRY_DIR:-${HOME}/.aidevops/cache/dep-unblock-retry}/${repo//\//__}.txt"
	local pending="${file}.pending" incoming="${file}.incoming.$$" remaining="${file}.remaining.$$"
	local stopped=false
	# Merge newly appended records into the pending snapshot so one failing
	# retry cannot hide later independent records.
	if [[ -s "$file" ]]; then
		mv "$file" "$incoming" || return 1
		cat "$incoming" >>"$pending" || return 1
		rm -f "$incoming"
	fi
	[[ -s "$pending" ]] || return 0
	# A failed closure can be present in both the retained snapshot and the
	# append-only ledger. Attempt each record only once in this pass.
	awk '!seen[$0]++' "$pending" >"$incoming" && mv -f "$incoming" "$pending" || return 1
	: >"$remaining" || return 1
	while read -r kind retry_number <&3; do
		[[ "$retry_number" =~ ^[0-9]+$ ]] || continue
		if [[ "$stopped" == true ]] || _der_stale_epoch_reached "$deadline"; then
			# Deadline reached: keep this and every unvisited entry.
			stopped=true
			complete=false
			printf '%s %s\n' "$kind" "$retry_number" >>"$remaining"
			continue
		fi
		status=0
		if [[ "$kind" == closure ]]; then
			reconcile_dependants_after_verified_closure "$repo" "$retry_number" "$deadline" || status=$?
		elif [[ "$kind" == issue ]]; then
			status=1
			if candidate=$(gh issue view "$retry_number" --repo "$repo" --json number,title,body,labels,updatedAt 2>/dev/null) &&
				candidate=$(printf '%s' "$candidate" | jq -ce --arg repo "$repo" 'select((.number | type) == "number" and (.labels | type) == "array") | . + {updated_at:.updatedAt,repository:{nameWithOwner:$repo},labels:{nodes:.labels,pageInfo:{hasNextPage:false}}}'); then
				status=0
				_der_try_unblock "$repo" "$retry_number" "$candidate" || status=$?
			fi
		else
			continue
		fi
		if [[ "$status" -ne 0 && "$status" -ne "$DER_NOT_READY" ]]; then
			# Failed (or partial) entries stay queued; completed ones are dropped.
			complete=false
			printf '%s %s\n' "$kind" "$retry_number" >>"$remaining"
		fi
	done 3<"$pending"
	if [[ -s "$remaining" ]]; then
		awk '!seen[$0]++' "$remaining" >"${remaining}.dedup" && mv -f "${remaining}.dedup" "$pending" || { rm -f "$remaining" "${remaining}.dedup"; return 1; }
	else
		rm -f "$pending" || return 1
	fi
	rm -f "$remaining"
	[[ "$complete" == true ]] || return "$DER_SWEEP_PARTIAL"
	return 0
}

# Print candidates from one paginated listing. An incomplete blockedBy
# connection can prove an open blocker, but cannot prove readiness. Any read or
# shape failure prints nothing (including no memo eligibility). Never a verdict
# authorizing release: _der_try_unblock still checks every ready candidate.
_der_stale_listing() {
	local repo="$1"
	local owner="${repo%%/*}" name="${repo#*/}" pages=""
	[[ "$repo" == */* && -n "$owner" && -n "$name" ]] || return 1
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	pages=$(gh api graphql --paginate --slurp -F owner="$owner" -F name="$name" \
		-f query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){issues(states:OPEN,labels:["status:blocked"],first:100,after:$endCursor){nodes{number updatedAt labels(first:100){nodes{name} pageInfo{hasNextPage}} blockedBy(first:20){totalCount nodes{number state}}} pageInfo{hasNextPage endCursor}}}}' \
		2>/dev/null) || return 1
	printf '%s' "$pages" | jq -ce --arg closed "$DER_STATE_CLOSED" '
		select(type == "array" and length > 0)
		| select(all(.[]; (.errors // [] | length) == 0
			and (.data.repository.issues.nodes | type) == "array"
			and (.data.repository.issues.pageInfo.hasNextPage | type) == "boolean"
			and (if .data.repository.issues.pageInfo.hasNextPage then
				(.data.repository.issues.pageInfo.endCursor | type) == ("" | type)
				and (.data.repository.issues.pageInfo.endCursor | length) > 0 else true end)))
		| select(.[-1].data.repository.issues.pageInfo.hasNextPage == false)
		| [.[] | .data.repository.issues.nodes[]]
		| select(all(.[]; (.number | type) == "number"
			and (.blockedBy.nodes | type) == "array"
			and (.updatedAt | type) == ("" | type)
			and (.labels.nodes | type) == "array" and .labels.pageInfo.hasNextPage == false
			and all(.labels.nodes[]; (.name | type) == ("" | type))
			and (.blockedBy.totalCount | type) == "number"
			and .blockedBy.totalCount >= (.blockedBy.nodes | length)
			and all(.blockedBy.nodes[]; .state == "OPEN" or .state == $closed)))
		| map(. + {updated_at:.updatedAt, sweep_ready:(.blockedBy.totalCount == (.blockedBy.nodes | length)
			and (.blockedBy.nodes | length) > 0 and all(.blockedBy.nodes[]; .state == $closed)),
			sweep_open:any(.blockedBy.nodes[]; .state == "OPEN")})' 2>/dev/null || return 1
	return 0
}

_der_stale_memo_load() {
	local file="$1" ttl="$2" memo='{}' now=""
	now=$(date +%s) || return 1
	# Invalid/unreadable state fails open. Probe atomic persistence before
	# trusting a memo, so a read-only cache cannot suppress any visit.
	memo=$(jq -ce 'select(type == ({} | type))' "$file" 2>/dev/null) || memo='{}'
	memo=$(printf '%s' "$memo" | jq -c --argjson now "$now" --argjson ttl "$ttl" '
		with_entries(select((.value | type) == ({} | type))
			| select((.value.epoch | type) == "number" and (.value.updated_at | type) == ("" | type))
			| select(.value.epoch <= $now and $now - .value.epoch < $ttl))') || memo='{}'
	_der_stale_cursor_write "$file" "$memo" || return 1
	printf '%s\n' "$memo"
	return 0
}

_der_stale_memo_matches() {
	local memo="$1" candidate="$2" ttl="$3" now=""
	now=$(date +%s) || return 1
	printf '%s' "$memo" | jq -e --argjson candidate "$candidate" --argjson now "$now" --argjson ttl "$ttl" '
		.[$candidate.number | tostring] | .updated_at != null and .updated_at != ""
		and .updated_at == $candidate.updated_at and .epoch <= $now and $now - .epoch < $ttl' >/dev/null || return 1
	return 0
}

_der_stale_memo_record() {
	local repo="$1" candidate="$2" status="$3" file="$4" memo="$5"
	local number="" updated="" labels="status:blocked"
	local body=""
	number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
	updated=$(printf '%s' "$candidate" | jq -r '.updated_at // ""') || return 1
	body=$(printf '%s' "$candidate" | jq -r '.body // ""') || return 1
	if [[ -n "$updated" ]] && [[ "$status" -eq 0 || "$status" -eq "$DER_NOT_READY" ]] &&
		! upstream_release_gate_declared "$body"; then
		# Success also means "held" in _der_try_unblock. Only memoize a
		# confirmed still-blocked issue, not a release or an ambiguous read.
		if [[ "$status" -eq 0 ]]; then
			labels=$(gh issue view "$number" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || labels=""
		fi
		if _der_labels_has "$labels" status:blocked; then
			memo=$(printf '%s' "$memo" | jq -c --arg n "$number" --arg updated "$updated" \
				--argjson epoch "$(date +%s)" '.[$n] = {updated_at:$updated,epoch:$epoch}') || return 1
			_der_stale_cursor_write "$file" "$memo" || return 1
		fi
	fi
	printf '%s\n' "$memo"
	return 0
}

_der_stale_candidates() {
	local pages="$1" repo="$2" cursor="$3" ready_cursor="$4" prefilter="${5:-1}" ready_only="${6:-0}"
	# The ready queue rotates independently of the ordinary cursor. In
	# particular, a high ordinary cursor must not hide a newly-ready low issue.
	# GH#38680: an ordinary candidate with a still-open native blocker is
	# settled without any API call, so the prefilter drops it here instead of
	# inside the deadline-checked loop (which never reached it once the stop
	# deadline had passed). A ready-only pass drops every ordinary candidate.
	printf '%s' "$pages" | jq -c --arg repo "$repo" \
		--argjson cursor "$cursor" --argjson ready_cursor "$ready_cursor" \
		--argjson prefilter "$prefilter" --argjson ready_only "$ready_only" '
		[.[]]
		| ([.[] | select(.sweep_ready)] | sort_by([(.number <= $ready_cursor), .number]))
			+ (if $ready_only == 1 then [] else [.[] | select(.sweep_ready == false and .number > $cursor
				and ($prefilter != 1 or (.sweep_open | not)))] | sort_by(.number) end)
		| .[] | . + {repository:{nameWithOwner:$repo}}' || return 1
	return 0
}

# GH#38680: count the ordinary candidates the prefilter settled (still-open
# native blocker), so the summary and the pulse backlog weight stay truthful.
_der_stale_prefiltered_count() {
	local pages="$1" cursor="$2" prefilter="$3" ready_only="$4"
	if [[ "$prefilter" != 1 || "$ready_only" == 1 ]]; then
		printf '0\n'
		return 0
	fi
	printf '%s' "$pages" | jq --argjson cursor "$cursor" \
		'[.[] | select(.sweep_ready == false and .number > $cursor and .sweep_open)] | length' || return 1
	return 0
}

# Write the budget-priority hint: ready candidates not suppressed by the memo.
_der_stale_write_ready_hint() {
	local hint_file="$1" candidates="$2" memo="$3" ttl="$4" fallback="$5" actionable=""
	actionable=$(printf '%s\n' "$candidates" | jq -s --argjson memo "$memo" --argjson now "$(date +%s)" --argjson ttl "$ttl" '
		[.[] | select(.sweep_ready)
			| select((($memo[.number | tostring] // null) as $m
				| ($m != null and $m.updated_at == .updated_at and $m.epoch <= $now and $now - $m.epoch < $ttl)) | not)]
		| length') || actionable="$fallback"
	mkdir -p "${hint_file%/*}" 2>/dev/null && printf '%s\n' "$actionable" >"$hint_file" || true
	return 0
}

_der_stale_skip_memo() {
	[[ "$memo_enabled" == true ]] && _der_stale_memo_matches "$memo" "$candidate" "$ttl" || return 1
	skipped=$((skipped + 1))
	if [[ "$is_ready" == true ]]; then
		_der_stale_cursor_write "$ready_file" "$issue_number" || cursor_failed=true
	else
		_der_stale_cursor_write "$cursor_file" "$issue_number" || cursor_failed=true
	fi
	return 0
}

# GH#38680: one unreadable issue used to end the whole pass (break), and with
# the ready cursor unmoved the same issue headed the next pass too. Queue it
# for the retry drain instead (which re-reads it and still decides through
# _der_try_unblock), move past it, and stop only after consecutive failures,
# such as an outage or an exhausted REST budget. Uses the caller's loop state,
# like _der_stale_skip_memo. Returns 0 to continue, 1 to stop the pass.
_der_stale_read_failed() {
	failed=$((failed + 1))
	consecutive_failed=$((consecutive_failed + 1))
	complete=false
	if ! _der_retry_append "$repo" issue "$issue_number"; then
		# No hand-off: keep the cursor so the next pass revisits this issue.
		ordinary_complete=false
		return 1
	fi
	retry_queued=$((retry_queued + 1))
	if [[ "$is_ready" == true ]]; then
		_der_stale_cursor_write "$ready_file" "$issue_number" || cursor_failed=true
	else
		_der_stale_cursor_write "$cursor_file" "$issue_number" || cursor_failed=true
	fi
	if [[ "$consecutive_failed" -ge "$max_failures" ]]; then
		ordinary_complete=false
		return 1
	fi
	return 0
}

# Periodically recover status:blocked issues whose close event was missed.
# GraphQL pagination is consumed in full, then bounded before any mutation.
# Candidates are visited in ascending issue order after the persisted cursor;
# the cursor advances after every visit so a killed stage keeps its progress.
# Optional DER_STALE_BLOCKED_DEADLINE_EPOCH (this repo's fair share) stops
# cleanly after at least one visit; optional DER_STALE_BLOCKED_STOP_EPOCH (the
# whole sweep's stop margin) permits one ready visit even when expired. Returns
# DER_SWEEP_PARTIAL when candidates remain for a later pass, or 1 when the
# cursor cannot be persisted; unblock decisions are unchanged (_der_try_unblock).
# GH#38680: DER_STALE_BLOCKED_READY_ONLY=1 visits only ready candidates and
# leaves the ordinary cursor untouched (the Pulse ready lane); an unreadable
# issue is queued for retry (_der_stale_read_failed) instead of ending the pass.
reconcile_stale_blocked_issues() {
	local repo="$1"
	local max_candidates="${DER_STALE_BLOCKED_MAX_CANDIDATES:-500}"
	local share_deadline="${DER_STALE_BLOCKED_DEADLINE_EPOCH:-0}"
	local stop_deadline="${DER_STALE_BLOCKED_STOP_EPOCH:-0}"
	local ready_max="${DER_STALE_BLOCKED_READY_MAX:-10}" ttl="${DER_STALE_BLOCKED_SKIP_TTL_SECONDS:-21600}"
	local pages candidates candidate issue_number cursor_file="" cursor=0 prefiltered=0 body=""
	local ready_cursor=0 ready_file="" ready=0 ready_visited=0 skipped=0 is_ready=false
	local memo_file="" memo='{}' memo_enabled=false try_status=0 ordinary_complete=true examined=0
	local total=0 pending=0 visited=0 reconciled=0 failed=0 complete=true cursor_failed=false
	local retry_status=0 ready_hint="${HOME}/.aidevops/cache/stale-blocked-weight/${repo//\//__}.ready"
	local prefilter="${DER_STALE_BLOCKED_PREFILTER:-1}" ready_only="${DER_STALE_BLOCKED_READY_ONLY:-0}"
	local max_failures="${DER_STALE_BLOCKED_MAX_CONSECUTIVE_FAILURES:-3}" consecutive_failed=0 retry_queued=0
	[[ "$repo" == */* ]] || return 1
	[[ "$max_candidates" =~ ^[1-9][0-9]*$ ]] || max_candidates=500
	[[ "$ready_max" =~ ^[1-9][0-9]*$ ]] || ready_max=10
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=21600
	[[ "$max_failures" =~ ^[1-9][0-9]*$ ]] || max_failures=3
	[[ "$prefilter" == 1 ]] || prefilter=0
	# A ready-only pass never finishes (so never resets) the ordinary traversal.
	if [[ "$ready_only" == 1 ]]; then ordinary_complete=false; else ready_only=0; fi
	cursor_file=$(_der_stale_cursor_file "$repo") || return 1
	cursor=$(_der_stale_cursor_read "$cursor_file")
	ready_file="${cursor_file}.ready"
	ready_cursor=$(_der_stale_cursor_read "$ready_file")
	memo_file="${cursor_file}.skip.json"
	# Drain queued retries first: they do not depend on the listing.
	_der_retry_drain "$repo" "$stop_deadline" || retry_status=$?
	pages=$(_der_stale_listing "$repo") || return 1
	total=$(printf '%s' "$pages" | jq 'length') || return 1
	memo=$(_der_stale_memo_load "$memo_file" "$ttl") && memo_enabled=true
	candidates=$(_der_stale_candidates "$pages" "$repo" "$cursor" "$ready_cursor" "$prefilter" "$ready_only") || return 1
	prefiltered=$(_der_stale_prefiltered_count "$pages" "$cursor" "$prefilter" "$ready_only") || return 1
	pending=$(printf '%s\n' "$candidates" | jq -s length) || return 1
	# pending keeps its meaning (candidates after the cursor, prefiltered included).
	pending=$((pending + prefiltered))
	ready=$(printf '%s\n' "$candidates" | jq -s '[.[] | select(.sweep_ready)] | length') || return 1
	# Hint counts only actionable ready work: exclude unchanged memo-skipped issues.
	_der_stale_write_ready_hint "$ready_hint" "$candidates" "$memo" "$ttl" "$ready"
	[[ "$retry_status" -eq 0 ]] || complete=false
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		issue_number=$(printf '%s' "$candidate" | jq -r '.number' 2>/dev/null) || issue_number=""
		is_ready=$(printf '%s' "$candidate" | jq -r '.sweep_ready') || return 1
		if { _der_stale_epoch_reached "$stop_deadline" && [[ "$is_ready" != true || "$ready_visited" -gt 0 ]]; } ||
			{ [[ "$is_ready" == false && "$examined" -ge "$max_candidates" ]]; }; then
			complete=false ordinary_complete=false
			break
		fi
		if [[ "$is_ready" == true && "$ready_visited" -ge "$ready_max" ]]; then
			complete=false
			continue
		fi
		[[ "$is_ready" == true ]] || examined=$((examined + 1))
		_der_stale_skip_memo && continue
		if [[ "$is_ready" == false && "$visited" -gt 0 ]] && _der_stale_epoch_reached "$share_deadline"; then
			complete=false ordinary_complete=false
			break
		fi
		[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || { failed=$((failed + 1)); continue; }
		if ! body=$(gh api "repos/${repo}/issues/${issue_number}" 2>/dev/null) ||
			! body=$(printf '%s' "$body" | jq -ce --argjson candidate "$candidate" 'select(has("body") and ((.body == null) or (.body | type == ("" | type)))) | $candidate + {body:(.body // "")}'); then
			_der_stale_read_failed && continue
			break
		fi
		consecutive_failed=0
		candidate="$body"
		# GH#35130: make the graph truthful when every native blocker is a closed,
		# superseded original with an open successor. Best effort; never gates unblock.
		dsr_repoint_if_superseded "$repo" "$issue_number" || true
		try_status=0
		_der_try_unblock "$repo" "$issue_number" "$candidate" || try_status=$?
		if [[ "$try_status" -eq 0 || "$try_status" -eq "$DER_NOT_READY" ]]; then
			reconciled=$((reconciled + 1))
		else
			failed=$((failed + 1))
		fi
		visited=$((visited + 1))
		if [[ "$is_ready" == true ]]; then
			ready_visited=$((ready_visited + 1))
			_der_stale_cursor_write "$ready_file" "$issue_number" || cursor_failed=true
		else
			_der_stale_cursor_write "$cursor_file" "$issue_number" || cursor_failed=true
		fi
		if [[ "$memo_enabled" == true ]]; then
			memo=$(_der_stale_memo_record "$repo" "$candidate" "$try_status" "$memo_file" "$memo") || memo_enabled=false
		fi
	done <<<"$candidates"
	# A finished traversal restarts from the lowest issue on the next pass.
	if [[ "$ordinary_complete" == true ]]; then
		_der_stale_cursor_write "$cursor_file" 0 || cursor_failed=true
	fi
	printf '[dependency-reconciler] stale sweep repo=%s candidates=%s resumed_after=%s pending=%s visited=%s checked=%s prefiltered_open_blocker=%s failed=%s batch_limit=%s complete=%s cursor_write_failed=%s ready=%s ready_visited=%s skipped_unchanged=%s retry_queued=%s ready_only=%s\n' "$repo" "$total" "$cursor" "$pending" "$visited" "$reconciled" "$prefiltered" "$failed" "$max_candidates" "$complete" "$cursor_failed" "$ready" "$ready_visited" "$skipped" "$retry_queued" "$ready_only" >&2
	# Without a durable cursor, later passes cannot resume; report a failure
	# (not partial progress) so the operator sees it in the cycle summary.
	[[ "$cursor_failed" == false ]] || return 1
	[[ "$complete" == true ]] || return "$DER_SWEEP_PARTIAL"
	[[ "$failed" -eq 0 ]]
	return $?
}

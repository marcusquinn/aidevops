#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Reconcile issue-first planning only after its exact default-branch snapshot lands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./issue-sync-lib.sh
source "${SCRIPT_DIR}/issue-sync-lib.sh"
# shellcheck source=./issue-sync-ci-context.sh
source "${SCRIPT_DIR}/issue-sync-ci-context.sh"
# shellcheck source=./shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

PUBLICATION_PENDING_LABEL="publication:pending"
PUBLICATION_AVAILABLE_LABEL="status:available"
PUBLICATION_BLOCKED_LABEL="status:blocked"
PUBLICATION_AUTO_LABEL="auto-dispatch"
PUBLICATION_LIMIT="${AIDEVOPS_PUBLICATION_RECONCILE_LIMIT:-100}"
# GH#33321: the reconcile limit budgets mapped reconciliation attempts. The scan
# window is wider so issues that can never map cannot fill the budget and
# starve valid tasks behind them.
PUBLICATION_SCAN_LIMIT="${AIDEVOPS_PUBLICATION_SCAN_LIMIT:-200}"
PUBLICATION_STALE_HOURS="${AIDEVOPS_PUBLICATION_STALE_HOURS:-24}"
PUBLICATION_UNMAPPED_MARKER="<!-- aidevops:publication-unmapped -->"

_publication_usage() {
	printf 'Usage: planning-publication-reconcile.sh {reconcile --repo owner/repo --sha SHA [--task tNNN] | sweep-closed --repo owner/repo}\n'
	return 0
}

# Never clear the last dispatch fence on a task absent from the default branch:
# a later reopen can reset status:done to status:available.
_publication_sweep_closed_one() {
	local repo="$1" issue_num="$2" issue_json=""
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json state,labels) || return 1
	jq -e '.state == "CLOSED" and any(.labels[]?; .name == "publication:pending")' \
		<<<"$issue_json" >/dev/null || return 0
	gh_publication_default_has_ref "$repo" "$issue_num" || return 1
	gh_issue_edit_safe "$issue_num" --repo "$repo" --remove-label "$PUBLICATION_PENDING_LABEL" >/dev/null || return 1
	return 0
}

cmd_sweep_closed() {
	local repo="" issues_json="" issue_num="" failed=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) repo="${2:-}"; shift 2 ;;
		*) _publication_usage >&2; return 2 ;;
		esac
	done
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 2
	[[ "$PUBLICATION_LIMIT" =~ ^[1-9][0-9]*$ ]] || return 2
	issue_sync_prepare_ci_context || return 1
	issues_json=$(gh issue list --repo "$repo" --state closed --label "$PUBLICATION_PENDING_LABEL" \
		--limit "$PUBLICATION_LIMIT" --json number) || return 1
	while IFS= read -r issue_num; do
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
		_publication_sweep_closed_one "$repo" "$issue_num" || failed=$((failed + 1))
	done < <(jq -r '.[].number' <<<"$issues_json")
	[[ "$failed" -eq 0 ]]
}

_publication_exact_default_snapshot() {
	local expected_sha="$1"
	local default_branch="$2"
	local head_sha="" remote_sha=""
	[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	head_sha=$(git rev-parse HEAD 2>/dev/null) || return 1
	[[ "$head_sha" == "$expected_sha" ]] || return 1
	remote_sha=$(git rev-parse "refs/remotes/origin/${default_branch}" 2>/dev/null) || return 1
	[[ "$remote_sha" == "$expected_sha" ]]
}

_publication_task_line() {
	local task_id="$1"
	local task_re="${task_id//./\\.}"
	local matches=""
	matches=$(grep -E "^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]+${task_re}[[:space:]]" TODO.md || true)
	[[ "$(printf '%s\n' "$matches" | grep -c . || true)" -eq 1 ]] || return 1
	printf '%s\n' "$matches"
}

# GH#33321: the canonical mapping is the TODO row's ref:GH#N, not the title.
# Resolve the task id from exactly one task line carrying this issue ref so
# issues without a tNNN title prefix (or with an edited title) still publish.
_publication_task_id_for_ref() {
	local issue_num="$1"
	local matches="" task_id=""
	[[ "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	matches=$(grep -E "^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]+t[0-9]+(\.[0-9]+)*[[:space:]].*(^|[[:space:]])ref:GH#${issue_num}($|[[:space:]])" TODO.md || true)
	[[ "$(printf '%s\n' "$matches" | grep -c . || true)" -eq 1 ]] || return 1
	task_id=$(printf '%s\n' "$matches" | sed -En 's/^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]+(t[0-9]+(\.[0-9]+)*)[[:space:]].*/\1/p')
	[[ -n "$task_id" ]] || return 1
	printf '%s\n' "$task_id"
	return 0
}

# One idempotent, visible diagnostic for a stale pending issue that has no
# task mapping. The label is retained: publication:pending is never removed
# without published-state verification.
_publication_note_unmapped() {
	local repo="$1" issue_num="$2"
	local existing="" body_file=""
	existing=$(gh api "repos/${repo}/issues/${issue_num}/comments" --paginate \
		--jq ".[] | select(.body | contains(\"${PUBLICATION_UNMAPPED_MARKER}\")) | .id" 2>/dev/null) || return 1
	[[ -z "$existing" ]] || return 0
	body_file=$(mktemp) || return 1
	cat >"$body_file" <<EOF
${PUBLICATION_UNMAPPED_MARKER}
**Planning publication cannot map this issue.** It carries \`${PUBLICATION_PENDING_LABEL}\`, but its title has no \`tNNN:\` prefix and no TODO.md task line carries \`ref:GH#${issue_num}\`, so reconciliation can never verify publication and the issue stays dispatch-blocked.

Fix: add a TODO.md task line with \`ref:GH#${issue_num}\` (and its \`todo/tasks/tNNN-brief.md\`) to the default branch; the next reconcile pass then publishes it. If the issue is not meant to be planned work, remove \`${PUBLICATION_PENDING_LABEL}\` deliberately.
EOF
	gh_issue_comment "$issue_num" --repo "$repo" --body-file "$body_file" >/dev/null 2>&1 || {
		rm -f "$body_file"
		return 1
	}
	rm -f "$body_file"
	return 0
}

_publication_desired_labels() {
	local task_line="$1"
	local parsed="" tags="" labels=""
	parsed=$(parse_task_line "$task_line") || return 1
	tags=$(printf '%s\n' "$parsed" | grep '^tags=' | cut -d= -f2-)
	labels=$(map_tags_to_labels "$tags")
	{
		printf '%s\n' "$labels" | tr ',' '\n' |
		grep -v -E "^(${PUBLICATION_PENDING_LABEL}|${PUBLICATION_AVAILABLE_LABEL})$" |
		grep -v '^$' | LC_ALL=C sort -u | paste -sd, -
	} || true
	return 0
}

_publication_task_has_dependency() {
	local task_line="$1"
	local issue_json="${2:-null}"
	local parsed="" blocked_by=""
	parsed=$(parse_task_line "$task_line") || return 1
	blocked_by=$(printf '%s\n' "$parsed" | grep '^blocked_by=' | cut -d= -f2-)
	[[ -n "$blocked_by" ]] && return 0
	# Issue-only refs are deliberately omitted from native relationship sync,
	# but remain dependency evidence for publication of the canonical task.
	[[ "$task_line" =~ (^|[[:space:]])blocked-by:([^[:space:]]+) ]] && return 0
	# Dependency-event reconciliation owns removal of resolved blocker labels.
	# Publication must not override them (or an existing blocked status).
	jq -e 'any(.labels[]?.name;
		. == "status:blocked" or test("^blocked-by:(GH)?#[1-9][0-9]*$"))' \
		<<<"$issue_json" >/dev/null || return 1
	return 0
}

_publication_issue_has_active_status() {
	local issue_json="$1"
	jq -e 'any(.labels[]?.name;
		. == "status:queued" or
		. == "status:claimed" or
		. == "status:in-progress" or
		. == "status:in-review" or
		. == "status:done")' <<<"$issue_json" >/dev/null || return 1
	return 0
}

_publication_issue_has_inactive_status() {
	local issue_json="$1"
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" && return 0
	_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" && return 0
	return 1
}

_publication_remove_inactive_statuses() {
	local repo="$1"
	local issue_num="$2"
	gh_issue_edit_safe "$issue_num" --repo "$repo" \
		--remove-label "${PUBLICATION_AVAILABLE_LABEL},${PUBLICATION_BLOCKED_LABEL}" >/dev/null || return 1
	return 0
}

_publication_status_label() {
	local desired_labels="$1"
	local has_dependency="$2"
	local issue_json="$3"
	local fenced=",${desired_labels},"
	if [[ "$has_dependency" -eq 1 ]]; then
		if ! _publication_issue_has_active_status "$issue_json"; then
			printf '%s\n' "$PUBLICATION_BLOCKED_LABEL"
		fi
		return 0
	fi
	_publication_issue_has_active_status "$issue_json" && return 0
	if [[ ("$fenced" == *",${PUBLICATION_AUTO_LABEL},"* || "$fenced" == *",no-auto-dispatch,") &&
		"$fenced" != *",parent-task,"* && "$fenced" != *",meta,"* &&
		"$fenced" != *",${PUBLICATION_BLOCKED_LABEL},"* && "$fenced" != *",status:queued,"* &&
		"$fenced" != *",status:claimed,"* && "$fenced" != *",status:in-progress,"* &&
		"$fenced" != *",status:in-review,"* && "$fenced" != *",status:done,"* &&
		"$fenced" != *",hold-for-review,"* ]]; then
		printf '%s\n' "$PUBLICATION_AVAILABLE_LABEL"
	fi
	return 0
}

_publication_issue_has_labels() {
	local issue_json="$1"
	local labels_csv="$2"
	local label=""
	while IFS= read -r label; do
		[[ -n "$label" ]] || continue
		jq -e --arg label "$label" 'any(.labels[]?; .name == $label)' \
			<<<"$issue_json" >/dev/null || return 1
	done < <(printf '%s\n' "$labels_csv" | tr ',' '\n')
	return 0
}

_publication_validate_mapping() {
	local task_id="$1" issue_num="$2"
	local task_line="" brief_path="todo/tasks/${task_id}-brief.md"
	task_line=$(_publication_task_line "$task_id") || return 3
	[[ "$task_line" =~ (^|[[:space:]])ref:GH#${issue_num}($|[[:space:]]) ]] || return 1
	[[ -f "$brief_path" && ! -L "$brief_path" ]] || return 1
	printf '%s\n' "$task_line"
}

_publication_brief_ready() {
	local brief_path="$1"
	"${SCRIPT_DIR}/verify-brief-helper.sh" check-readiness "$brief_path" >/dev/null 2>&1 || return 1
	return 0
}

# GH#32904: worker readiness gates dispatch, not publication. Held and untagged
# tasks publish with a lightweight brief; only auto-dispatch projection needs it.
_publication_dispatch_ready() {
	local task_id="$1" desired_labels="$2"
	[[ ",${desired_labels}," == *",${PUBLICATION_AUTO_LABEL},"* ]] || return 0
	_publication_brief_ready "todo/tasks/${task_id}-brief.md" || return 1
	return 0
}

# GH#33821: removing publication:pending is a reconciler's final mutation, so an
# issue listed as pending that has since lost the label was fully published by a
# concurrent reconciler (CI vs. full-loop-helper merge). Count it as reconciled.
_publication_note_concurrent() {
	local task_id="$1" issue_num="$2"
	print_info "${task_id}/#${issue_num}: already reconciled concurrently; ${PUBLICATION_PENDING_LABEL} removed by another reconciler"
	return 0
}

_publication_reconcile_one() {
	local repo="$1" task_id="$2" issue_num="$3"
	# 1 = issue title must start with "<task_id>:" (title-derived mapping);
	# 0 = mapping came from the TODO row's exact ref:GH#N (GH#33321).
	local require_title_prefix="${4:-1}"
	local task_line="" desired_labels="" status_label="" projected_labels="" issue_json="" has_dependency=0 mapping_rc=0
	task_line=$(_publication_validate_mapping "$task_id" "$issue_num") || {
		mapping_rc=$?
		if [[ "$mapping_rc" -eq 3 ]]; then
			print_warning "${task_id}/#${issue_num}: task absent from default-branch snapshot; publication deferred"
			return 3
		fi
		print_warning "${task_id}/#${issue_num}: canonical task, ref, or brief validation failed; retaining ${PUBLICATION_PENDING_LABEL}"
		return 1
	}
	desired_labels=$(_publication_desired_labels "$task_line") || {
		print_warning "${task_id}/#${issue_num}: task line parse failed; retaining ${PUBLICATION_PENDING_LABEL}"
		return 1
	}
	_publication_dispatch_ready "$task_id" "$desired_labels" || {
		print_warning "${task_id}/#${issue_num}: auto-dispatch brief is not worker-ready; retaining ${PUBLICATION_PENDING_LABEL}"
		return 1
	}
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	_publication_task_has_dependency "$task_line" "$issue_json" && has_dependency=1
	jq -e --arg task_prefix "${task_id}:" --arg bound "$require_title_prefix" \
		'.state == "OPEN" and ($bound == "0" or (.title | startswith($task_prefix)))' \
		<<<"$issue_json" >/dev/null || return 1
	if ! _publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL"; then
		_publication_note_concurrent "$task_id" "$issue_num"; return 0
	fi
	status_label=$(_publication_status_label "$desired_labels" "$has_dependency" "$issue_json")
	projected_labels="$desired_labels"
	[[ -n "$status_label" ]] && projected_labels="${projected_labels:+${projected_labels},}${status_label}"

	if [[ -n "$projected_labels" ]]; then
		# Keep audit provenance at the reconciler instead of the generic CLI shim.
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--add-label "$projected_labels" >/dev/null || return 1
	fi
	# Dependency metadata is authoritative even before native relationship repair.
	# Remove stale availability only after blocked/active state is established, so
	# every intermediate failure remains pending or non-dispatchable.
	if [[ "$has_dependency" -eq 1 ]] || _publication_issue_has_active_status "$issue_json"; then
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--remove-label "$PUBLICATION_AVAILABLE_LABEL" >/dev/null || return 1
	fi
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	jq -e --arg task_prefix "${task_id}:" --arg bound "$require_title_prefix" \
		'.state == "OPEN" and ($bound == "0" or (.title | startswith($task_prefix)))' \
		<<<"$issue_json" >/dev/null || return 1
	# Active lifecycle state wins if assignment races with label projection.
	if _publication_issue_has_active_status "$issue_json"; then
		_publication_remove_inactive_statuses "$repo" "$issue_num" || return 1
		issue_json=$(gh issue view "$issue_num" --repo "$repo" --json number,title,state,labels) || return 1
	fi
	_publication_issue_has_labels "$issue_json" "$desired_labels" || return 1
	if ! _publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL"; then
		_publication_note_concurrent "$task_id" "$issue_num"; return 0
	fi
	if [[ "$has_dependency" -eq 1 ]]; then
		! _publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
		_publication_issue_has_active_status "$issue_json" || \
			_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" || return 1
	elif [[ "$status_label" == "$PUBLICATION_AVAILABLE_LABEL" ]] && \
		! _publication_issue_has_active_status "$issue_json"; then
		_publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
	fi

	# The blocker is intentionally the final mutation. Every prior failure leaves
	# the issue undispatchable and safely retryable.
	gh_issue_edit_safe "$issue_num" --repo "$repo" \
		--remove-label "$PUBLICATION_PENDING_LABEL" >/dev/null || return 1
	issue_json=$(gh issue view "$issue_num" --repo "$repo" --json labels) || return 1
	if _publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL"; then
		return 1
	fi
	if _publication_issue_has_active_status "$issue_json" && \
		_publication_issue_has_inactive_status "$issue_json"; then
		# A lifecycle transition raced with the final pending-label removal.
		# Restore the dispatch fence before cleanup; a failed cleanup therefore
		# remains safely retryable instead of leaving a conflicting live status.
		gh_issue_edit_safe "$issue_num" --repo "$repo" \
			--add-label "$PUBLICATION_PENDING_LABEL" >/dev/null || return 1
		_publication_remove_inactive_statuses "$repo" "$issue_num" || return 1
		return 1
	fi
	_publication_issue_has_labels "$issue_json" "$desired_labels" || return 1
	if [[ "$has_dependency" -eq 1 ]]; then
		! _publication_issue_has_labels "$issue_json" "$PUBLICATION_AVAILABLE_LABEL" || return 1
		_publication_issue_has_active_status "$issue_json" || \
			_publication_issue_has_labels "$issue_json" "$PUBLICATION_BLOCKED_LABEL" || return 1
	fi
	print_success "${task_id}/#${issue_num}: planning publication reconciled"
	return 0
}

_publication_issue_age_hours() {
	local created_at="$1" created_epoch="" now_epoch=""
	[[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null) || \
		created_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" +%s 2>/dev/null) || return 1
	now_epoch=$(date -u +%s) || return 1
	[[ "$created_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	((created_epoch <= now_epoch)) || return 1
	printf '%s\n' "$(((now_epoch - created_epoch) / 3600))"
	return 0
}

cmd_reconcile() {
	local repo="" expected_sha="" task_filter="" default_branch=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) repo="${2:-}"; shift 2 ;;
		--sha) expected_sha="${2:-}"; shift 2 ;;
		--task) task_filter="${2:-}"; shift 2 ;;
		*) _publication_usage >&2; return 2 ;;
		esac
	done
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 2
	[[ -f TODO.md && ! -L TODO.md ]] || return 2
	[[ "$PUBLICATION_LIMIT" =~ ^[1-9][0-9]*$ && "$PUBLICATION_STALE_HOURS" =~ ^[1-9][0-9]*$ ]] || return 2
	[[ "$PUBLICATION_SCAN_LIMIT" =~ ^[1-9][0-9]*$ ]] || return 2
	local scan_limit="$PUBLICATION_SCAN_LIMIT"
	[[ "$scan_limit" -ge "$PUBLICATION_LIMIT" ]] || scan_limit="$PUBLICATION_LIMIT"
	# Each GitHub Actions run step has a fresh process. Establish the narrowly
	# scoped runner context before wrappers resolve privacy/write-policy inventory.
	issue_sync_prepare_ci_context || return 1
	default_branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name') || return 2
	_publication_exact_default_snapshot "$expected_sha" "$default_branch" || {
		print_error "Refusing reconciliation: HEAD is not exact origin/${default_branch} SHA ${expected_sha}"
		return 1
	}

	local issues_json="" issue_num="" title="" task_id="" created_at="" age_hours="" rc=0 title_bound=1
	local reconciled=0 deferred=0 stale=0 failed=0 unmapped=0 attempts=0 diagnostics=0
	issues_json=$(gh issue list --repo "$repo" --state open --label "$PUBLICATION_PENDING_LABEL" \
		--limit "$scan_limit" --json number,title,createdAt) || return 1
	while IFS=$'\t' read -r issue_num title created_at; do
		[[ -n "$issue_num" ]] || continue
		title_bound=1
		task_id=$(printf '%s\n' "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || true)
		if [[ -z "$task_id" ]]; then
			task_id=$(_publication_task_id_for_ref "$issue_num") || task_id=""
			title_bound=0
		fi
		if [[ -z "$task_id" ]]; then
			# GH#33321: unmapped is its own class. It never consumes the
			# reconcile budget and never fails the run; once stale it gets
			# one idempotent diagnostic naming the cause and the fix.
			[[ -z "$task_filter" ]] || continue
			unmapped=$((unmapped + 1))
			age_hours=$(_publication_issue_age_hours "$created_at") || age_hours=""
			if [[ -z "$age_hours" || "$age_hours" -ge "$PUBLICATION_STALE_HOURS" ]] &&
				[[ "$diagnostics" -lt "$PUBLICATION_LIMIT" ]]; then
				diagnostics=$((diagnostics + 1))
				if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
					printf '::warning::#%s: %s issue has no tNNN title or TODO ref:GH#%s mapping\n' "$issue_num" "$PUBLICATION_PENDING_LABEL" "$issue_num"
				else
					print_warning "#${issue_num}: ${PUBLICATION_PENDING_LABEL} issue has no tNNN title or TODO ref:GH#${issue_num} mapping; retaining label"
				fi
				_publication_note_unmapped "$repo" "$issue_num" ||
					print_warning "#${issue_num}: could not post unmapped publication diagnostic"
			fi
			continue
		fi
		[[ -z "$task_filter" || "$task_id" == "$task_filter" ]] || continue
		[[ "$attempts" -lt "$PUBLICATION_LIMIT" ]] || break
		attempts=$((attempts + 1))
		rc=0
		_publication_reconcile_one "$repo" "$task_id" "$issue_num" "$title_bound" || rc=$?
		case "$rc" in
		0) reconciled=$((reconciled + 1)) ;;
		3)
			age_hours=$(_publication_issue_age_hours "$created_at") || age_hours=""
			if [[ -n "$age_hours" && "$age_hours" -lt "$PUBLICATION_STALE_HOURS" ]]; then
				deferred=$((deferred + 1))
			else
				stale=$((stale + 1))
				if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
					printf '::warning::%s/#%s: absent task is stale or createdAt is invalid; retaining %s\n' "$task_id" "$issue_num" "$PUBLICATION_PENDING_LABEL"
				else
					print_warning "${task_id}/#${issue_num}: absent task is stale or createdAt is invalid; retaining ${PUBLICATION_PENDING_LABEL}"
				fi
			fi
			;;
		*) failed=$((failed + 1)) ;;
		esac
	done < <(jq -r '.[] | [.number, .title, (.createdAt // "")] | @tsv' <<<"$issues_json")
	printf 'PUBLICATION_RECONCILE_SUMMARY reconciled=%s deferred=%s stale=%s failed=%s unmapped=%s\n' "$reconciled" "$deferred" "$stale" "$failed" "$unmapped"
	[[ $((stale + failed)) -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
	reconcile) shift; cmd_reconcile "$@" ;;
	sweep-closed) shift; cmd_sweep_closed "$@" ;;
	*) _publication_usage >&2; exit 2 ;;
	esac
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# docker-resource-helper.sh — ownership labels and cleanup for disposable
# Docker resources (test sites, plugin-check stacks, review stacks) that
# aidevops sessions and scripts start (GH#34285).
#
# Usage:
#   docker-resource-helper.sh labels [--repo OWNER/REPO] [--ref GH#N|PR#N]
#       [--worktree PATH] [--ttl-hours N]      # one --label=k=v per line
#   docker-resource-helper.sh compose-labels [same options] [--indent N]
#   docker-resource-helper.sh inventory         # labelled resources as TSV
#   docker-resource-helper.sh teardown --worktree PATH [--dry-run] [--force]
#   docker-resource-helper.sh reap [--apply] [--max-seconds N] [--verbose]
#   docker-resource-helper.sh report [--max-seconds N]
#
# Safety rules (see tools/containers/disposable-resources.md):
#   - Only resources labelled sh.aidevops.owner=1 are ever removed.
#     Unlabelled resources are only counted by `report`.
#   - `reap` is report-only unless --apply is given. It removes a labelled
#     resource older than 30 minutes only when (a) its worktree path no
#     longer exists AND its issue/PR is closed, or (b) its TTL expired and no
#     running container uses it. A failed issue/PR lookup means "keep".
#   - Removal order: containers, then networks, then volumes. A network or
#     volume still attached to a container that is not being removed is kept.
#   - Docker missing or the daemon not answering within a short timeout:
#     every entry point logs one line and exits 0.
#
# Environment:
#   AIDEVOPS_DOCKER_TTL_HOURS            default TTL label value (72)
#   AIDEVOPS_DOCKER_TIMEOUT_SECONDS      daemon probe timeout (5)
#   AIDEVOPS_DOCKER_CMD_TIMEOUT_SECONDS  per docker command timeout (30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly DRH_PREFIX="sh.aidevops"
readonly DRH_TAG="[docker-resource]"
readonly DRH_US=$'\x1f'
# Never reap anything younger than this: another session may be starting it.
readonly DRH_GRACE_SECONDS=1800
readonly DRH_LABEL_KEYS="owner repo ref worktree created ttl-hours"
readonly DRH_MODE_APPLY="apply"
readonly DRH_MODE_DRY_RUN="dry-run"
readonly DRH_KIND_CONTAINER="container"
readonly DRH_DECISION_REMOVE="remove"
readonly DRH_STATE_UNKNOWN="unknown"

DRH_DEFAULT_TTL="${AIDEVOPS_DOCKER_TTL_HOURS:-72}"
[[ "$DRH_DEFAULT_TTL" =~ ^[0-9]+$ ]] || DRH_DEFAULT_TTL=72
DRH_PROBE_TIMEOUT="${AIDEVOPS_DOCKER_TIMEOUT_SECONDS:-5}"
[[ "$DRH_PROBE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || DRH_PROBE_TIMEOUT=5
DRH_CMD_TIMEOUT="${AIDEVOPS_DOCKER_CMD_TIMEOUT_SECONDS:-30}"
[[ "$DRH_CMD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || DRH_CMD_TIMEOUT=30

DRH_TMP=""
DRH_NOW=0
DRH_START=0
DRH_MAX_SECONDS=0
DRH_BUDGET_EXHAUSTED=0
DRH_FORCE=0
DRH_VERBOSE=0
DRH_REF_CACHE=""
DRH_REF_STATE=""
DRH_GH_LOOKUPS=0
DRH_DECISION=""
DRH_REASON=""
DRH_REMOVED_IDS=" "
DRH_CANDIDATE_IDS=" "
DRH_COUNT_REMOVED=0
DRH_COUNT_FAILED=0
DRH_COUNT_KEPT=0
DRH_COUNT_CANDIDATES=0
# Label option values (set by _drh_parse_label_opts).
DRH_L_REPO=""
DRH_L_REF=""
DRH_L_WORKTREE=""
DRH_L_TTL=""
DRH_L_INDENT=0

_drh_log() {
	printf '%s %s\n' "$DRH_TAG" "$*"
	return 0
}

_drh_cleanup_tmp() {
	if [[ -n "$DRH_TMP" && -d "$DRH_TMP" ]]; then
		rm -rf "$DRH_TMP"
	fi
	return 0
}

_drh_init_tmp() {
	[[ -z "$DRH_TMP" ]] || return 0
	DRH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/docker-resource.XXXXXX") || return 1
	trap _drh_cleanup_tmp EXIT
	return 0
}

_drh_docker() {
	timeout_sec "$DRH_CMD_TIMEOUT" docker "$@"
	return $?
}

# Return 0 when docker is installed and the daemon answers quickly.
_drh_docker_ready() {
	if ! command -v docker >/dev/null 2>&1; then
		_drh_log "docker not installed; skipping"
		return 1
	fi
	if ! timeout_sec "$DRH_PROBE_TIMEOUT" docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
		_drh_log "docker daemon not reachable within ${DRH_PROBE_TIMEOUT}s; skipping"
		return 1
	fi
	return 0
}

_drh_budget_left() {
	if [[ "$DRH_MAX_SECONDS" -gt 0 && $((SECONDS - DRH_START)) -ge "$DRH_MAX_SECONDS" ]]; then
		DRH_BUDGET_EXHAUSTED=1
		return 1
	fi
	return 0
}

_drh_set_max_seconds() {
	local value="$1"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		printf 'Invalid value for --max-seconds: %s\n' "$value" >&2
		return 1
	fi
	DRH_MAX_SECONDS="$value"
	return 0
}

_drh_short() {
	local id="$1"
	printf '%s' "${id:0:12}"
	return 0
}

# --- labels ------------------------------------------------------------------

_drh_default_repo() {
	local url rest name owner
	url=$(git remote get-url origin 2>/dev/null) || return 0
	url="${url%.git}"
	url="${url%/}"
	name="${url##*/}"
	rest="${url%/*}"
	owner="${rest##*[:/]}"
	if [[ "${owner}/${name}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		printf '%s/%s' "$owner" "$name"
	fi
	return 0
}

_drh_default_ref() {
	local branch=""
	if [[ "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		printf 'GH#%s' "$WORKER_ISSUE_NUMBER"
		return 0
	fi
	branch=$(git branch --show-current 2>/dev/null) || return 0
	if [[ "$branch" =~ [Gg][Hh]-?([0-9]+) ]]; then
		printf 'GH#%s' "${BASH_REMATCH[1]}"
	fi
	return 0
}

_drh_default_worktree() {
	git rev-parse --show-toplevel 2>/dev/null || pwd -P
	return 0
}

_drh_parse_label_opts() {
	DRH_L_REPO=""
	DRH_L_REF=""
	DRH_L_WORKTREE=""
	DRH_L_TTL="$DRH_DEFAULT_TTL"
	DRH_L_INDENT=0
	local have_repo=0 have_ref=0 opt val
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--repo | --ref | --worktree | --ttl-hours | --indent)
			[[ $# -ge 2 ]] || {
				printf 'Missing value for %s\n' "$opt" >&2
				return 1
			}
			case "$opt" in
			--repo)
				DRH_L_REPO="$val"
				have_repo=1
				;;
			--ref)
				DRH_L_REF="$val"
				have_ref=1
				;;
			--worktree) DRH_L_WORKTREE="$val" ;;
			--ttl-hours) DRH_L_TTL="$val" ;;
			--indent) DRH_L_INDENT="$val" ;;
			esac
			shift
			;;
		*)
			printf 'Unknown option: %s\n' "$opt" >&2
			return 1
			;;
		esac
		shift
	done
	[[ "$have_repo" -eq 1 ]] || DRH_L_REPO=$(_drh_default_repo)
	[[ "$have_ref" -eq 1 ]] || DRH_L_REF=$(_drh_default_ref)
	[[ -n "$DRH_L_WORKTREE" ]] || DRH_L_WORKTREE=$(_drh_default_worktree)
	while [[ "$DRH_L_WORKTREE" == */ && "$DRH_L_WORKTREE" != "/" ]]; do DRH_L_WORKTREE="${DRH_L_WORKTREE%/}"; done
	[[ -z "$DRH_L_REPO" || "$DRH_L_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
		{
			printf 'Invalid --repo (expected owner/repo): %s\n' "$DRH_L_REPO" >&2
			return 1
		}
	[[ -z "$DRH_L_REF" || "$DRH_L_REF" =~ ^(GH|PR)#[0-9]+$ ]] ||
		{
			printf 'Invalid --ref (expected GH#N or PR#N): %s\n' "$DRH_L_REF" >&2
			return 1
		}
	[[ "$DRH_L_TTL" =~ ^[0-9]+$ ]] || {
		printf 'Invalid --ttl-hours: %s\n' "$DRH_L_TTL" >&2
		return 1
	}
	[[ "$DRH_L_INDENT" =~ ^[0-9]+$ ]] || {
		printf 'Invalid --indent: %s\n' "$DRH_L_INDENT" >&2
		return 1
	}
	case "$DRH_L_WORKTREE" in
	/*) ;;
	*)
		printf 'Invalid --worktree (absolute path required): %s\n' "$DRH_L_WORKTREE" >&2
		return 1
		;;
	esac
	case "$DRH_L_WORKTREE" in
	*$'\n'* | *$'\t'* | *"$DRH_US"*)
		printf 'Invalid --worktree (control characters)\n' >&2
		return 1
		;;
	esac
	return 0
}

# Print "key<TAB>value" for the six owner labels.
_drh_label_pairs() {
	local created=""
	created=$(date +%s)
	printf '%s.owner\t1\n' "$DRH_PREFIX"
	printf '%s.repo\t%s\n' "$DRH_PREFIX" "$DRH_L_REPO"
	printf '%s.ref\t%s\n' "$DRH_PREFIX" "$DRH_L_REF"
	printf '%s.worktree\t%s\n' "$DRH_PREFIX" "$DRH_L_WORKTREE"
	printf '%s.created\t%s\n' "$DRH_PREFIX" "$created"
	printf '%s.ttl-hours\t%s\n' "$DRH_PREFIX" "$DRH_L_TTL"
	return 0
}

cmd_labels() {
	local key value
	_drh_parse_label_opts "$@" || return 1
	while IFS=$'\t' read -r key value; do
		printf -- '--label=%s=%s\n' "$key" "$value"
	done < <(_drh_label_pairs)
	return 0
}

cmd_compose_labels() {
	local key value pad
	_drh_parse_label_opts "$@" || return 1
	pad=$(printf '%*s' "$DRH_L_INDENT" '')
	printf '%slabels:\n' "$pad"
	while IFS=$'\t' read -r key value; do
		value="${value//\\/\\\\}"
		value="${value//\"/\\\"}"
		printf '%s  %s: "%s"\n' "$pad" "$key" "$value"
	done < <(_drh_label_pairs)
	return 0
}

# --- inventory ---------------------------------------------------------------

_drh_label_format() {
	local key fmt
	fmt=""
	for key in $DRH_LABEL_KEYS; do
		fmt="${fmt}${DRH_US}{{.Label \"${DRH_PREFIX}.${key}\"}}"
	done
	printf '%s' "$fmt"
	return 0
}

# Append "kind US <docker line> [US state]" rows to $1.
_drh_collect_kind() {
	local kind="$1" out="$2"
	local filter="label=${DRH_PREFIX}.owner=1"
	local labels output line suffix
	suffix=""
	labels=$(_drh_label_format)
	case "$kind" in
	container)
		output=$(_drh_docker ps -a --no-trunc --filter "$filter" \
			--format "{{.ID}}${DRH_US}{{.Names}}${labels}${DRH_US}{{.State}}") || return 1
		;;
	network)
		output=$(_drh_docker network ls --no-trunc --filter "$filter" \
			--format "{{.ID}}${DRH_US}{{.Name}}${labels}") || return 1
		suffix="${DRH_US}-"
		;;
	volume)
		output=$(_drh_docker volume ls --filter "$filter" \
			--format "{{.Name}}${DRH_US}{{.Name}}${labels}") || return 1
		suffix="${DRH_US}-"
		;;
	*) return 1 ;;
	esac
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		printf '%s%s%s%s\n' "$kind" "$DRH_US" "$line" "$suffix" >>"$out"
	done <<<"$output"
	return 0
}

# Write labelled resources to $1 (fields: kind id name owner repo ref
# worktree created ttl state, separated by \x1f).
_drh_collect() {
	local out="$1" kind
	: >"$out"
	for kind in $DRH_KIND_CONTAINER network volume; do
		_drh_collect_kind "$kind" "$out" || return 1
	done
	return 0
}

cmd_inventory() {
	local records kind id name owner repo ref worktree created ttl state
	[[ $# -eq 0 ]] || {
		printf 'Usage: %s inventory\n' "${0##*/}" >&2
		return 1
	}
	_drh_docker_ready || return 0
	_drh_init_tmp || return 1
	records="${DRH_TMP}/records"
	_drh_collect "$records" || {
		_drh_log "inventory: docker listing failed; skipping"
		return 0
	}
	printf 'kind\tid\tname\trepo\tref\tworktree\tcreated\tttl\tstate\n'
	while IFS="$DRH_US" read -r kind id name owner repo ref worktree created ttl state; do
		[[ "$owner" == "1" ]] || continue
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$(_drh_short "$id")" "$name" \
			"${repo:--}" "${ref:--}" "${worktree:--}" "${created:--}" "${ttl:--}" "${state:--}"
	done <"$records"
	return 0
}

# --- ownership rule ----------------------------------------------------------

# Return 0 only when the label names an absolute path that no longer exists.
_drh_worktree_gone() {
	local path="$1"
	case "$path" in
	/?*) [[ ! -e "$path" ]] && return 0 ;;
	esac
	return 1
}

# Set DRH_REF_STATE to closed|open|unknown for repo+ref. One gh call per
# distinct ref per run; any failure means unknown (never treated as closed).
_drh_ref_state() {
	local repo="$1" ref="$2"
	local key cached number state
	state=""
	DRH_REF_STATE="$DRH_STATE_UNKNOWN"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$ref" =~ ^(GH|PR)#([0-9]+)$ ]] || return 0
	number="${BASH_REMATCH[2]}"
	key="${repo}#${number}"
	cached=$(printf '%s' "$DRH_REF_CACHE" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')
	if [[ -n "$cached" ]]; then
		DRH_REF_STATE="$cached"
		return 0
	fi
	if command -v gh >/dev/null 2>&1; then
		DRH_GH_LOOKUPS=$((DRH_GH_LOOKUPS + 1))
		state=$(timeout_sec 15 gh api "repos/${repo}/issues/${number}" --jq '.state' 2>/dev/null) || state=""
	fi
	case "$state" in
	closed | CLOSED) DRH_REF_STATE="closed" ;;
	open | OPEN) DRH_REF_STATE="open" ;;
	*) DRH_REF_STATE="$DRH_STATE_UNKNOWN" ;;
	esac
	DRH_REF_CACHE="${DRH_REF_CACHE}${key}"$'\t'"${DRH_REF_STATE}"$'\n'
	return 0
}

# Return 0 when the resource is (or is used by) a running container. Any
# docker failure counts as running so the TTL rule keeps the resource.
_drh_in_use_running() {
	local kind="$1" id="$2"
	local running
	case "$kind" in
	container)
		running=$(_drh_docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null) || return 0
		case "$running" in
		exited | created | dead) return 1 ;;
		esac
		return 0
		;;
	network | volume)
		running=$(_drh_docker ps -q --no-trunc --filter "${kind}=${id}") || return 0
		[[ -n "$running" ]] && return 0
		return 1
		;;
	esac
	return 0
}

# Set DRH_DECISION (remove|keep) and DRH_REASON for one reap record.
_drh_decide() {
	local kind="$1" id="$2" owner="$3" repo="$4" ref="$5" worktree="$6" created="$7" ttl="$8" state="$9"
	local age=0
	DRH_DECISION="keep"
	if [[ "$owner" != "1" ]]; then
		DRH_REASON="unlabelled"
		return 0
	fi
	if [[ ! "$created" =~ ^[0-9]+$ ]]; then
		DRH_REASON="invalid-created-label"
		return 0
	fi
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$DRH_DEFAULT_TTL"
	age=$((DRH_NOW - created))
	if [[ "$age" -lt "$DRH_GRACE_SECONDS" ]]; then
		DRH_REASON="created-within-30m"
		return 0
	fi
	DRH_REASON="worktree-present"
	if _drh_worktree_gone "$worktree"; then
		_drh_ref_state "$repo" "$ref"
		if [[ "$DRH_REF_STATE" == "closed" ]]; then
			DRH_DECISION="$DRH_DECISION_REMOVE"
			DRH_REASON="worktree-gone-ref-closed"
			return 0
		fi
		DRH_REASON="ref-${DRH_REF_STATE}"
	fi
	[[ "$age" -gt $((ttl * 3600)) ]] || return 0
	# The TTL rule never removes anything running or used by a running container.
	if [[ "$kind" == "$DRH_KIND_CONTAINER" ]]; then
		case "$state" in
		exited | created | dead) ;;
		*)
			DRH_REASON="ttl-expired-but-running"
			return 0
			;;
		esac
	elif _drh_in_use_running "$kind" "$id"; then
		DRH_REASON="ttl-expired-but-running"
		return 0
	fi
	DRH_DECISION="$DRH_DECISION_REMOVE"
	DRH_REASON="ttl-expired"
	return 0
}

# --- removal -----------------------------------------------------------------

# Count containers attached to a network/volume that are not in $3 (a
# space-delimited id set). Prints the count; returns 1 on docker failure.
_drh_blocking_attachments() {
	local kind="$1" id="$2" exclude="$3"
	local attached cid blockers=0
	attached=$(_drh_docker ps -a -q --no-trunc --filter "${kind}=${id}") || return 1
	for cid in $attached; do
		[[ "$exclude" == *" ${cid} "* ]] || blockers=$((blockers + 1))
	done
	printf '%s' "$blockers"
	return 0
}

# Remove one resource; "no such ..."/"not found" counts as already removed.
_drh_remove() {
	local kind="$1" id="$2"
	local err lower
	case "$kind" in
	container) err=$(_drh_docker rm -f "$id" 2>&1 >/dev/null) && return 0 ;;
	network) err=$(_drh_docker network rm "$id" 2>&1 >/dev/null) && return 0 ;;
	volume) err=$(_drh_docker volume rm "$id" 2>&1 >/dev/null) && return 0 ;;
	*) return 1 ;;
	esac
	lower=$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')
	case "$lower" in
	*"no such"* | *"not found"*) return 0 ;;
	esac
	_drh_log "remove failed: ${kind} ${id:0:12}: ${err}"
	return 1
}

# Re-check the removal condition immediately before acting (another session
# may have restarted the stack or recreated the worktree since planning).
_drh_still_eligible() {
	local kind="$1" id="$2" reason="$3" worktree="$4"
	case "$reason" in
	ttl-expired)
		_drh_in_use_running "$kind" "$id" && return 1
		;;
	worktree-gone-ref-closed)
		_drh_worktree_gone "$worktree" || return 1
		;;
	worktree-teardown)
		[[ "$DRH_FORCE" -eq 1 ]] || _drh_worktree_gone "$worktree" || return 1
		;;
	esac
	return 0
}

# Execute one planned row. $1=mode (apply|dry-run).
_drh_execute_row() {
	local mode="$1" kind="$2" id="$3" name="$4" reason="$5" repo="$6" ref="$7" worktree="$8"
	local detail blockers exclude
	detail="${kind} ${name} ($(_drh_short "$id")) reason=${reason} repo=${repo:--} ref=${ref:--} worktree=${worktree:--}"
	if [[ "$kind" != "$DRH_KIND_CONTAINER" ]]; then
		exclude="$DRH_REMOVED_IDS"
		[[ "$mode" == "$DRH_MODE_APPLY" ]] || exclude="$DRH_CANDIDATE_IDS"
		blockers=$(_drh_blocking_attachments "$kind" "$id" "$exclude") || blockers="$DRH_STATE_UNKNOWN"
		if [[ "$blockers" != "0" ]]; then
			DRH_COUNT_KEPT=$((DRH_COUNT_KEPT + 1))
			_drh_log "kept ${detail} attached_containers=${blockers}"
			return 0
		fi
	fi
	if [[ "$mode" != "$DRH_MODE_APPLY" ]]; then
		_drh_log "would-remove ${detail}"
		return 0
	fi
	if ! _drh_still_eligible "$kind" "$id" "$reason" "$worktree"; then
		DRH_COUNT_KEPT=$((DRH_COUNT_KEPT + 1))
		_drh_log "kept ${detail} recheck=changed"
		return 0
	fi
	if _drh_remove "$kind" "$id"; then
		DRH_COUNT_REMOVED=$((DRH_COUNT_REMOVED + 1))
		DRH_REMOVED_IDS="${DRH_REMOVED_IDS}${id} "
		_drh_log "removed ${detail}"
	else
		DRH_COUNT_FAILED=$((DRH_COUNT_FAILED + 1))
	fi
	return 0
}

# Execute a plan file (kind id name reason repo ref worktree) in safe order.
_drh_execute_plan() {
	local mode="$1" plan="$2"
	local order kind id name reason repo ref worktree
	for order in $DRH_KIND_CONTAINER network volume; do
		while IFS="$DRH_US" read -r kind id name reason repo ref worktree; do
			[[ "$kind" == "$order" ]] || continue
			if ! _drh_budget_left; then
				_drh_log "budget exhausted; remaining candidates retried next run"
				return 0
			fi
			_drh_execute_row "$mode" "$kind" "$id" "$name" "$reason" "$repo" "$ref" "$worktree"
		done <"$plan"
	done
	return 0
}

_drh_add_candidate() {
	local plan="$1" kind="$2" id="$3" name="$4" reason="$5" repo="$6" ref="$7" worktree="$8"
	printf '%s\n' "${kind}${DRH_US}${id}${DRH_US}${name}${DRH_US}${reason}${DRH_US}${repo}${DRH_US}${ref}${DRH_US}${worktree}" >>"$plan"
	DRH_COUNT_CANDIDATES=$((DRH_COUNT_CANDIDATES + 1))
	[[ "$kind" != "$DRH_KIND_CONTAINER" ]] || DRH_CANDIDATE_IDS="${DRH_CANDIDATE_IDS}${id} "
	return 0
}

# --- teardown ----------------------------------------------------------------

cmd_teardown() {
	local mode="$DRH_MODE_APPLY" matched=0 target=""
	local records plan opt val kind id name owner repo ref worktree created ttl state
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--worktree)
			[[ $# -ge 2 ]] || {
				printf 'Missing value for --worktree\n' >&2
				return 1
			}
			target="$val"
			shift
			;;
		--dry-run) mode="$DRH_MODE_DRY_RUN" ;;
		--force) DRH_FORCE=1 ;;
		*)
			printf 'Unknown option: %s\n' "$opt" >&2
			return 1
			;;
		esac
		shift
	done
	while [[ "$target" == */ && "$target" != "/" ]]; do target="${target%/}"; done
	case "$target" in
	/?*) ;;
	*)
		printf 'teardown requires --worktree <absolute path>\n' >&2
		return 1
		;;
	esac
	if [[ -e "$target" && "$DRH_FORCE" -ne 1 ]]; then
		_drh_log "teardown: worktree still exists (${target}); pass --force to remove its resources anyway"
		return 1
	fi
	_drh_docker_ready || return 0
	_drh_init_tmp || return 1
	records="${DRH_TMP}/records"
	plan="${DRH_TMP}/plan"
	: >"$plan"
	_drh_collect "$records" || {
		_drh_log "teardown: docker listing failed; skipping"
		return 0
	}
	while IFS="$DRH_US" read -r kind id name owner repo ref worktree created ttl state; do
		[[ "$owner" == "1" ]] || continue
		while [[ "$worktree" == */ && "$worktree" != "/" ]]; do worktree="${worktree%/}"; done
		[[ "$worktree" == "$target" ]] || continue
		matched=$((matched + 1))
		_drh_add_candidate "$plan" "$kind" "$id" "$name" "worktree-teardown" "$repo" "$ref" "$worktree"
	done <"$records"
	[[ "$matched" -gt 0 ]] || return 0
	DRH_START=$SECONDS
	_drh_execute_plan "$mode" "$plan"
	_drh_log "teardown mode=${mode} worktree=${target} matched=${matched} removed=${DRH_COUNT_REMOVED} kept=${DRH_COUNT_KEPT} failed=${DRH_COUNT_FAILED}"
	return 0
}

# --- reap --------------------------------------------------------------------

cmd_reap() {
	local mode="$DRH_MODE_DRY_RUN" labelled=0
	local records plan opt val kind id name owner repo ref worktree created ttl state
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--apply) mode="$DRH_MODE_APPLY" ;;
		--dry-run) mode="$DRH_MODE_DRY_RUN" ;;
		--verbose) DRH_VERBOSE=1 ;;
		--max-seconds)
			_drh_set_max_seconds "$val" || return 1
			shift
			;;
		*)
			printf 'Unknown option: %s\n' "$opt" >&2
			return 1
			;;
		esac
		shift
	done
	DRH_START=$SECONDS
	_drh_docker_ready || return 0
	_drh_init_tmp || return 1
	records="${DRH_TMP}/records"
	plan="${DRH_TMP}/plan"
	: >"$plan"
	_drh_collect "$records" || {
		_drh_log "reap: docker listing failed; skipping"
		return 0
	}
	DRH_NOW=$(date +%s)
	while IFS="$DRH_US" read -r kind id name owner repo ref worktree created ttl state; do
		[[ "$owner" == "1" ]] || continue
		labelled=$((labelled + 1))
		_drh_budget_left || break
		_drh_decide "$kind" "$id" "$owner" "$repo" "$ref" "$worktree" "$created" "$ttl" "$state"
		if [[ "$DRH_DECISION" == "$DRH_DECISION_REMOVE" ]]; then
			_drh_add_candidate "$plan" "$kind" "$id" "$name" "$DRH_REASON" "$repo" "$ref" "$worktree"
		else
			DRH_COUNT_KEPT=$((DRH_COUNT_KEPT + 1))
			[[ "$DRH_VERBOSE" -ne 1 ]] || _drh_log "kept ${kind} ${name} ($(_drh_short "$id")) reason=${DRH_REASON}"
		fi
	done <"$records"
	_drh_execute_plan "$mode" "$plan"
	_drh_log "reap mode=${mode} labelled=${labelled} candidates=${DRH_COUNT_CANDIDATES} removed=${DRH_COUNT_REMOVED} kept=${DRH_COUNT_KEPT} failed=${DRH_COUNT_FAILED} gh_lookups=${DRH_GH_LOOKUPS} elapsed_s=$((SECONDS - DRH_START)) budget_s=${DRH_MAX_SECONDS} budget_exhausted=${DRH_BUDGET_EXHAUSTED}"
	return 0
}

# --- report ------------------------------------------------------------------

# Convert Docker's RFC 3339 UTC timestamp to epoch seconds (GNU or BSD date).
_drh_iso_to_epoch() {
	local iso="$1"
	local base
	base="${iso%%.*}"
	base="${base%Z}"
	[[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
	[[ "$base" != 0001-* ]] || return 1
	date -u -d "${base}" +%s 2>/dev/null && return 0
	date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null && return 0
	return 1
}

_drh_count_lines() {
	local text="$1"
	if [[ -z "$text" ]]; then
		printf '0'
		return 0
	fi
	printf '%s\n' "$text" | awk 'NF { n++ } END { print n + 0 }'
	return 0
}

_drh_report_ownership() {
	local label="label=${DRH_PREFIX}.owner=1" n_all=0 n_owned=0
	local all owned
	printf '\nOwnership (only labelled resources are ever removed by aidevops):\n'
	all=$(_drh_docker ps -a -q --no-trunc) || all=""
	owned=$(_drh_docker ps -a -q --no-trunc --filter "$label") || owned=""
	n_all=$(_drh_count_lines "$all")
	n_owned=$(_drh_count_lines "$owned")
	printf '  containers: labelled=%s unlabelled=%s\n' "$n_owned" "$((n_all - n_owned))"
	all=$(_drh_docker network ls -q --no-trunc --filter type=custom) || all=""
	owned=$(_drh_docker network ls -q --no-trunc --filter type=custom --filter "$label") || owned=""
	n_all=$(_drh_count_lines "$all")
	n_owned=$(_drh_count_lines "$owned")
	printf '  networks (custom): labelled=%s unlabelled=%s\n' "$n_owned" "$((n_all - n_owned))"
	all=$(_drh_docker volume ls -q) || all=""
	owned=$(_drh_docker volume ls -q --filter "$label") || owned=""
	n_all=$(_drh_count_lines "$all")
	n_owned=$(_drh_count_lines "$owned")
	printf '  volumes: labelled=%s unlabelled=%s\n' "$n_owned" "$((n_all - n_owned))"
	return 0
}

_drh_report_networks() {
	local empty=0 shown=0 checked=0
	local networks line id name used
	networks=$(_drh_docker network ls --no-trunc --filter type=custom --format "{{.ID}}${DRH_US}{{.Name}}") || networks=""
	printf '\nCustom networks with no containers (each holds an address-pool subnet):\n'
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		_drh_budget_left || break
		id="${line%%"$DRH_US"*}"
		name="${line#*"$DRH_US"}"
		checked=$((checked + 1))
		used=$(_drh_docker ps -a -q --no-trunc --filter "network=${id}") || continue
		[[ -z "$used" ]] || continue
		empty=$((empty + 1))
		if [[ "$shown" -lt 20 ]]; then
			printf '  %s\n' "$name"
			shown=$((shown + 1))
		fi
	done <<<"$networks"
	[[ "$empty" -le "$shown" ]] || printf '  ... and %s more\n' "$((empty - shown))"
	printf '  total=%s (checked %s)\n' "$empty" "$checked"
	printf '  reclaim: docker network prune   # removes only networks with no containers\n'
	return 0
}

_drh_report_stopped() {
	local epoch=0 age=0 owned=0 other=0 shown=0
	local ttl_seconds=$((DRH_DEFAULT_TTL * 3600))
	local ids inspected cid name finished owner now
	inspected=""
	now=$(date +%s)
	printf '\nContainers stopped longer than %sh:\n' "$DRH_DEFAULT_TTL"
	ids=$(_drh_docker ps -a -q --no-trunc --filter status=exited) || ids=""
	if [[ -n "$ids" ]]; then
		# shellcheck disable=SC2086 # ids are docker container IDs (no spaces)
		inspected=$(_drh_docker inspect --format \
			"{{.Id}}${DRH_US}{{.Name}}${DRH_US}{{.State.FinishedAt}}${DRH_US}{{index .Config.Labels \"${DRH_PREFIX}.owner\"}}" \
			$ids) || inspected=""
	fi
	while IFS="$DRH_US" read -r cid name finished owner; do
		[[ -n "$cid" ]] || continue
		epoch=$(_drh_iso_to_epoch "$finished") || continue
		age=$((now - epoch))
		[[ "$age" -gt "$ttl_seconds" ]] || continue
		if [[ "$owner" == "1" ]]; then owned=$((owned + 1)); else other=$((other + 1)); fi
		if [[ "$shown" -lt 20 ]]; then
			printf '  %s stopped_days=%s labelled=%s\n' "${name#/}" "$((age / 86400))" "$([[ "$owner" == "1" ]] && printf yes || printf no)"
			shown=$((shown + 1))
		fi
	done <<<"$inspected"
	printf '  total=%s labelled=%s unlabelled=%s\n' "$((owned + other))" "$owned" "$other"
	printf '  reclaim labelled: docker-resource-helper.sh reap --apply\n'
	printf '  reclaim unlabelled (after confirming none are needed): docker container prune --filter "until=%sh"\n' "$DRH_DEFAULT_TTL"
	return 0
}

cmd_report() {
	local df dangling opt val
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--max-seconds)
			_drh_set_max_seconds "$val" || return 1
			shift
			;;
		*)
			printf 'Unknown option: %s\n' "$opt" >&2
			return 1
			;;
		esac
		shift
	done
	DRH_START=$SECONDS
	_drh_docker_ready || return 0
	printf '%s report (read-only; nothing is deleted)\n' "$DRH_TAG"
	printf '\nDisk usage (docker system df):\n'
	if df=$(_drh_docker system df --format "{{.Type}}${DRH_US}{{.TotalCount}}${DRH_US}{{.Active}}${DRH_US}{{.Size}}${DRH_US}{{.Reclaimable}}"); then
		printf '%s\n' "$df" | awk -F"$DRH_US" 'NF >= 5 { printf "  %-14s total=%s active=%s size=%s reclaimable=%s\n", $1, $2, $3, $4, $5 }'
	else
		printf '  unavailable (docker system df failed or exceeded %ss; set AIDEVOPS_DOCKER_CMD_TIMEOUT_SECONDS higher)\n' "$DRH_CMD_TIMEOUT"
	fi
	printf '  reclaim images: docker image prune   (add -a for all unused images)\n'
	printf '  reclaim build cache: docker builder prune --filter "until=%sh"\n' "$DRH_DEFAULT_TTL"
	dangling=$(_drh_docker volume ls -q --filter dangling=true) || dangling=""
	printf '\nUnused volumes (no container references them): %s\n' "$(_drh_count_lines "$dangling")"
	printf '  inspect first: docker volume ls --filter dangling=true\n'
	printf '  reclaim: docker volume prune   (anonymous only; -a includes named volumes and deletes their data)\n'
	_drh_report_ownership
	_drh_report_stopped
	_drh_report_networks
	[[ "$DRH_BUDGET_EXHAUSTED" -eq 0 ]] || printf '\n(report budget of %ss exhausted; results are partial)\n' "$DRH_MAX_SECONDS"
	printf '\nAddress-pool exhaustion and cleanup guide: tools/containers/disposable-resources.md\n'
	return 0
}

usage() {
	sed -n '8,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -eq 0 ]] || shift
	case "$command" in
	labels) cmd_labels "$@" ;;
	compose-labels) cmd_compose_labels "$@" ;;
	inventory) cmd_inventory "$@" ;;
	teardown) cmd_teardown "$@" ;;
	reap) cmd_reap "$@" ;;
	report) cmd_report "$@" ;;
	help | --help | -h) usage ;;
	*)
		printf 'Unknown command: %s\n' "$command" >&2
		usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"

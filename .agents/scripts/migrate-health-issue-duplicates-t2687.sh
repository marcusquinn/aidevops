#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# migrate-health-issue-duplicates-t2687.sh
#
# One-shot migration that closes duplicate [Supervisor:*]/[Contributor:*]
# health-dashboard issues created during the 2026-04-21 GraphQL rate-limit
# window (GH#20301). Also backfills the `origin:worker` label on any
# `source:health-dashboard` issue missing it (surfaced on #20298).
#
# Strategy:
#   - Iterate ~/.config/aidevops/repos.json `initialized_repos[]` entries
#     where `pulse: true` and not `local_only`.
#   - For each repo, list open issues with label `source:health-dashboard`.
#   - Group by (runner_user, role_label). Runner_user is extracted from
#     the issue title via the `[Supervisor:user]` / `[Contributor:user]`
#     prefix. Role is derived from the `supervisor` or `contributor` label.
#   - Keep the newest issue per group (by createdAt).
#   - Close the older ones with an explanatory comment linking to GH#20301.
#   - Backfill `origin:worker` on every surviving health-dashboard issue
#     that is missing it. Remove `origin:interactive` / `origin:worker-takeover`
#     on the same call (origin labels are mutually exclusive).
#   - Write marker file on success so repeated runs are no-ops.
#
# Usage:
#   migrate-health-issue-duplicates-t2687.sh [--dry-run] [--force] \
#     [--slug <owner/repo>]
#
# Exits 0 on success, 1 on any critical failure, 2 on invalid args.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck disable=SC2034  # referenced via setup log prefix below
MARKER_FILE="${HOME}/.aidevops/logs/.migrated-health-issue-duplicates-t2687"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"
LOG_PREFIX="[migrate-t2687]"

# ------------------------------------------------------------------
# CLI parsing
# ------------------------------------------------------------------
DRY_RUN=0
FORCE=0
TARGET_SLUG=""

usage() {
	cat <<EOF
migrate-health-issue-duplicates-t2687.sh

One-shot migration for health-dashboard duplicates (GH#20301).

Usage:
  $(basename "$0") [--dry-run] [--force] [--slug owner/repo]

Flags:
  --dry-run      Report actions without making changes.
  --force        Run even if the marker file exists.
  --slug SLUG    Only process the given owner/repo (default: all pulse repos).
  -h, --help     Show this help.

Reads:  ${REPOS_JSON}
Marker: ${MARKER_FILE}
EOF
}

parse_args() {
	# Wrapped in a function so positional refs use `local var="$N"` pattern
	# per aidevops Quality Rules ("never use $1 directly in function bodies").
	while (($# > 0)); do
		local arg="$1"
		case "$arg" in
			--dry-run) DRY_RUN=1; shift ;;
			--force) FORCE=1; shift ;;
			--slug)
				local next_val="${2:-}"
				if [[ $# -lt 2 || -z "$next_val" ]]; then
					echo "${LOG_PREFIX} --slug requires an argument" >&2
					exit 2
				fi
				TARGET_SLUG="$next_val"
				shift 2
				;;
			-h|--help) usage; exit 0 ;;
			*)
				echo "${LOG_PREFIX} unknown arg: $arg" >&2
				usage >&2
				exit 2
				;;
		esac
	done
	return 0
}
parse_args "$@"

# ------------------------------------------------------------------
# Guards
# ------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
	echo "${LOG_PREFIX} gh CLI not found" >&2
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "${LOG_PREFIX} jq not found" >&2
	exit 1
fi

if [[ ! -f "$REPOS_JSON" ]]; then
	echo "${LOG_PREFIX} repos.json not found at $REPOS_JSON" >&2
	exit 1
fi

if [[ -f "$MARKER_FILE" && $FORCE -eq 0 ]]; then
	echo "${LOG_PREFIX} marker file exists (${MARKER_FILE}) — use --force to re-run"
	exit 0
fi

mkdir -p "$(dirname "$MARKER_FILE")" 2>/dev/null || true

# ------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------
log_info() { printf '%s INFO  %s\n' "$LOG_PREFIX" "$*"; return 0; }
log_warn() { printf '%s WARN  %s\n' "$LOG_PREFIX" "$*" >&2; return 0; }
log_do()   { printf '%s DO    %s\n' "$LOG_PREFIX" "$*"; return 0; }
log_dry()  { printf '%s DRY   %s\n' "$LOG_PREFIX" "$*"; return 0; }

run_gh() {
	# Wrapper that logs & respects --dry-run. Silences gh's own output
	# internally so call sites do NOT need `>/dev/null 2>&1` — which
	# would also mask our audit log line. Returns gh's exit code on
	# real-run, 0 on dry-run.
	if ((DRY_RUN)); then
		log_dry "gh $*"
		return 0
	fi
	log_do "gh $*"
	local rc=0
	gh "$@" >/dev/null 2>&1 || rc=$?
	return "$rc"
}

# ------------------------------------------------------------------
# Build list of target repos
# ------------------------------------------------------------------
resolve_target_slugs() {
	if [[ -n "$TARGET_SLUG" ]]; then
		printf '%s\n' "$TARGET_SLUG"
		return 0
	fi
	jq -r '.initialized_repos[]? | select(.pulse == true) | select(.local_only // false | not) | .slug // empty' \
		"$REPOS_JSON" 2>/dev/null |
		grep -E '^[^/]+/[^/]+$' || true
	return 0
}

# ------------------------------------------------------------------
# Process one repo
# ------------------------------------------------------------------
# Note: runner_user and role are extracted inline via the jq enrichment
# step in process_repo() — no separate shell helpers needed. Keeping
# the extraction logic in one place prevents drift between the grouping
# key (jq) and any shell-side re-derivation.

has_label() {
	local labels_json="$1" name="$2"
	printf '%s' "$labels_json" | jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null 2>&1
	return $?
}

_backfill_origin_worker_labels() {
	# Backfill origin:worker on every health-dashboard issue missing it
	# (independent from dedup — even the kept issue might be missing it).
	local enriched="$1"
	local repo="$2"
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local num labels
		num=$(printf '%s' "$line" | jq -r '.number')
		labels=$(printf '%s' "$line" | jq -c '.labels')
		if ! has_label "$labels" "origin:worker"; then
			local flags=(--add-label "origin:worker")
			# Mutual exclusion (.agents/AGENTS.md "Origin label mutual exclusion").
			if has_label "$labels" "origin:interactive"; then
				flags+=(--remove-label "origin:interactive")
			fi
			if has_label "$labels" "origin:worker-takeover"; then
				flags+=(--remove-label "origin:worker-takeover")
			fi
			log_info "  backfill origin:worker on #${num} (${repo})"
			run_gh issue edit "$num" --repo "$repo" "${flags[@]}" \
				|| log_warn "    origin:worker backfill failed for #${num}"
		fi
	done < <(printf '%s' "$enriched")
	return 0
}

_unpin_duplicate_issue() {
	local close_num="$1"
	local repo="$2"
	if ((DRY_RUN)); then
		log_dry "gh api graphql unpinIssue issueId=<node_id_for_#${close_num}>"
		return 0
	fi
	local node_id
	node_id=$(gh issue view "$close_num" --repo "$repo" --json id --jq '.id' 2>/dev/null || echo "")
	[[ -z "$node_id" ]] && return 0
	gh api graphql -f query="
		mutation {
			unpinIssue(input: {issueId: \"${node_id}\"}) {
				issue { number }
			}
		}" >/dev/null 2>&1 || true
	return 0
}

_close_duplicate_groups() {
	local groups_summary="$1"
	local repo="$2"
	local grp
	while IFS= read -r grp; do
		[[ -z "$grp" ]] && continue
		local role user keep close_list
		role=$(printf '%s' "$grp" | jq -r '.role')
		user=$(printf '%s' "$grp" | jq -r '.user')
		keep=$(printf '%s' "$grp" | jq -r '.issues[0].number')
		close_list=$(printf '%s' "$grp" | jq -r '.issues[1:] | .[].number')
		log_info "  dedup group role=${role} user=${user}: keep #${keep}, close $(echo "$close_list" | wc -w | tr -d ' ')"

		local close_num
		while IFS= read -r close_num; do
			[[ -z "$close_num" ]] && continue
			local comment="Closing duplicate ${role} health issue — superseded by #${keep}. Root cause: GraphQL rate-limit window on 2026-04-21 (t2574 REST fallback covered CREATE but not READ paths). See GH#20301 for the systemic fix."
			_unpin_duplicate_issue "$close_num" "$repo"
			# Strip 'persistent' before closing so issue-sync.yml 'Reopen Persistent Issues'
			# job does not reopen the duplicate (GH#20326). That job blocks USER-initiated
			# closes, not programmatic dedup. Idempotent: no-op if label not present.
			run_gh issue edit "$close_num" --repo "$repo" --remove-label persistent 2>/dev/null || true
			run_gh issue close "$close_num" --repo "$repo" --comment "$comment" \
				|| log_warn "    close failed for #${close_num}"
		done <<<"$close_list"
	done <<<"$groups_summary"
	return 0
}

process_repo() {
	local slug="$1"
	log_info "Scanning ${slug}"

	local issues_json
	if ! issues_json=$(gh issue list --repo "$slug" \
		--label source:health-dashboard --state open \
		--json number,title,labels,createdAt --limit 100 2>/dev/null); then
		log_warn "Failed to list issues for ${slug} — skipping"
		return 0
	fi

	local total
	total=$(printf '%s' "$issues_json" | jq 'length')
	if [[ "${total:-0}" -eq 0 ]]; then
		log_info "  no health-dashboard issues in ${slug}"
		return 0
	fi
	log_info "  found ${total} health-dashboard issue(s) in ${slug}"

	# Enrich every issue with a grouping key "<role>:<runner_user>" so we
	# can group via jq. Issues missing role or runner_user get "UNGROUPED"
	# and are skipped (but still reported).
	local enriched
	enriched=$(printf '%s' "$issues_json" | jq -c '.[] | {
		number: .number,
		title: .title,
		labels: .labels,
		createdAt: .createdAt,
		role: (
			if (.labels | map(.name) | index("supervisor")) then "supervisor"
			elif (.labels | map(.name) | index("contributor")) then "contributor"
			else "" end
		),
		user: (
			(.title | capture("^\\[(?<role>Supervisor|Contributor):(?<user>[^]]+)\\]").user) // ""
		)
	}')

	_backfill_origin_worker_labels "$enriched" "$slug"

	# Group by (role, user). For each group with >1 members, keep the
	# newest by createdAt and close the rest.
	local groups_summary
	groups_summary=$(printf '%s' "$enriched" |
		jq -sc 'group_by(.role + "\u0001" + .user) | .[] | {
			role: .[0].role,
			user: .[0].user,
			issues: (sort_by(.createdAt) | reverse)
		} | select(.role != "" and .user != "") | select(.issues | length > 1)')

	if [[ -z "$groups_summary" ]]; then
		log_info "  no duplicates in ${slug}"
		return 0
	fi

	_close_duplicate_groups "$groups_summary" "$slug"
	return 0
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
	log_info "script=$(basename "$0") dry_run=${DRY_RUN} force=${FORCE} target=${TARGET_SLUG:-all}"

	local -a target_slugs=()
	while IFS= read -r s; do
		[[ -z "$s" ]] && continue
		target_slugs+=("$s")
	done < <(resolve_target_slugs)

	if [[ "${#target_slugs[@]}" -eq 0 ]]; then
		log_warn "no pulse-enabled repos found in ${REPOS_JSON}"
		exit 0
	fi

	log_info "target_repos=${#target_slugs[@]}"

	local slug
	for slug in "${target_slugs[@]}"; do
		process_repo "$slug" || log_warn "process_repo failed for ${slug} (continuing)"
	done

	if ((DRY_RUN == 0)); then
		touch "$MARKER_FILE"
		log_info "migration complete — marker written: ${MARKER_FILE}"
	else
		log_info "dry-run complete — no changes made, no marker written"
	fi

	return 0
}

main "$@"

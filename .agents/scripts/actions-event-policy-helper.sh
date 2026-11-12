#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Plan, apply and verify the repository Actions event policy that allows
# `pull_request_target` for the workflow files that declare it.
#
# GitHub blocks `pull_request_target` by default in public repositories from
# 2026-12-02 (brownouts 2026-11-09 and 2026-11-16, 16:00-18:00 UTC) unless an
# applicable Actions policy explicitly allows it.
# https://github.blog/changelog/2026-11-02-pull_request_target-blocked-by-default-december-2
#
# Usage:
#   actions-event-policy-helper.sh status --repo OWNER/REPO
#   actions-event-policy-helper.sh plan   --repo OWNER/REPO
#   actions-event-policy-helper.sh apply  --repo OWNER/REPO
#   actions-event-policy-helper.sh status|plan --all-managed
#
# status exits 0 when covered or not applicable, 1 when uncovered, 2 on error.
# plan and status are read-only. apply is explicit and per repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly POLICY_NAME="aidevops-pull-request-target-gates"
readonly POLICY_EVENT="pull_request_target"
readonly POLICY_API_VERSION="2026-03-10"
readonly POLICY_RULE_TYPE="restrict_action_events"
_T="true"
readonly WORKFLOW_DIR=".github/workflows"
readonly REPOS_JSON_DEFAULT="${HOME}/.config/aidevops/repos.json"

# Populated by _policy_scan: JSON {default_branch, public, workflows:[{path,events,parsed}]}
_POLICY_SCAN_JSON=""

_policy_error() {
	local message="$1"
	printf 'actions-event-policy: %s\n' "$message" >&2
	return 1
}

_policy_usage() {
	cat <<'USAGE'
Usage:
  actions-event-policy-helper.sh status --repo OWNER/REPO
  actions-event-policy-helper.sh plan   --repo OWNER/REPO
  actions-event-policy-helper.sh apply  --repo OWNER/REPO
  actions-event-policy-helper.sh status|plan --all-managed

status: exit 0 when covered or not applicable (private/internal repo or no
        pull_request_target workflow), exit 1 when uncovered, exit 2 on error.
plan:   print the exact policy JSON body (read-only).
apply:  create or update the policy named aidevops-pull-request-target-gates.
        Refuses when a targeted workflow's events cannot be parsed.
USAGE
	return 0
}

_policy_require_dependencies() {
	local dependency=""
	for dependency in gh jq yq base64; do
		if ! command -v "$dependency" >/dev/null 2>&1; then
			_policy_error "missing dependency: ${dependency}"
			return 1
		fi
	done
	return 0
}

_policy_validate_repo() {
	local repo_slug="$1"
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_policy_error "repository must be OWNER/REPO"
		return 1
	fi
	return 0
}

_policy_api_read() {
	local endpoint="$1"
	gh api --method GET -H "X-GitHub-Api-Version: ${POLICY_API_VERSION}" "$endpoint"
	return $?
}

# Print the sorted, de-duplicated events declared in a workflow's `on:` key,
# one JSON array. Uses a real YAML parser (yq): PyYAML-style loaders read the
# key `on` as boolean true. Exit 1 when the events cannot be parsed.
_policy_parse_events() {
	local content="$1"
	local on_json=""
	on_json=$(printf '%s\n' "$content" | yq -o=json '.on' 2>/dev/null) || return 1
	jq -ce '
		if type == "string" then [.]
		elif type == "array" and all(.[]; type == "string") then .
		elif type == "object" then keys
		else error("unsupported on:") end
		| unique | select(length > 0)' <<<"$on_json" 2>/dev/null || return 1
	return 0
}

# Print "true" when the workflow calls a local reusable workflow.
_policy_calls_local_reusable() {
	local content="$1"
	local result=""
	result=$(printf '%s\n' "$content" |
		yq -o=json '[.jobs[]? | .uses // "" | select(type == "!!str" and test("^\\./"))] | length > 0' 2>/dev/null) || result="false"
	printf '%s\n' "$result"
	return 0
}

_policy_fetch_file() {
	local slug="$1"
	local path="$2"
	local ref="$3"
	gh api --method GET -H "Accept: application/vnd.github.raw" \
		"repos/${slug}/contents/${path}?ref=${ref}"
	return $?
}

# List the workflow directory. Sets _POLICY_LISTING. A confirmed 404 (directory
# absent) is an empty list; any other failure (403, rate limit, 5xx, network) is
# an error so status never reports success on an unchecked repository.
_policy_list_workflows() {
	local slug="$1"
	local branch="$2"
	local err_file="" err_text=""
	err_file=$(mktemp) || {
		_policy_error "cannot create temp file"
		return 1
	}
	if _POLICY_LISTING=$(_policy_api_read "repos/${slug}/contents/${WORKFLOW_DIR}?ref=${branch}" 2>"$err_file"); then
		rm -f "$err_file"
		return 0
	fi
	err_text=$(cat "$err_file")
	rm -f "$err_file"
	# gh api prints the status as the trailing "(HTTP NNN)" of its error line.
	if grep -Eq '^gh: .*\(HTTP 404\)[[:space:]]*$' <<<"$err_text"; then
		_POLICY_LISTING="[]"
		return 0
	fi
	_policy_error "cannot list ${WORKFLOW_DIR} in ${slug}"
	return 1
}

# Scan the default branch. Sets _POLICY_SCAN_JSON.
_policy_scan() {
	local slug="$1"
	local repo_json="" default_branch="" visibility="" listing="" path="" content=""
	local events="" parsed="" reusable="" entries="[]"
	repo_json=$(_policy_api_read "repos/${slug}") || {
		_policy_error "cannot read repository ${slug}"
		return 1
	}
	default_branch=$(jq -r '.default_branch // empty' <<<"$repo_json")
	visibility=$(jq -r '.visibility // (if .private then "private" else "public" end)' <<<"$repo_json")
	if [[ -z "$default_branch" ]]; then
		_policy_error "cannot determine default branch for ${slug}"
		return 1
	fi
	_policy_list_workflows "$slug" "$default_branch" || return 1
	listing="$_POLICY_LISTING"
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		case "$path" in
		"${WORKFLOW_DIR}"/*.yml | "${WORKFLOW_DIR}"/*.yaml) ;;
		*) continue ;;
		esac
		content=$(_policy_fetch_file "$slug" "$path" "$default_branch") || {
			_policy_error "cannot read ${path} in ${slug}"
			return 1
		}
		# Only files that mention the event matter; others are never targeted.
		if ! grep -q "$POLICY_EVENT" <<<"$content"; then
			continue
		fi
		if events=$(_policy_parse_events "$content"); then
			parsed="$_T"
			if [[ "$(_policy_calls_local_reusable "$content")" == "$_T" ]]; then
				events=$(jq -c '. + ["workflow_call"] | unique' <<<"$events")
			fi
		else
			parsed="false"
			events="[]"
		fi
		# A mention in a comment or string is not a declaration.
		if [[ "$parsed" == "$_T" ]] && ! jq -e --arg e "$POLICY_EVENT" 'index($e) != null' <<<"$events" >/dev/null; then
			continue
		fi
		entries=$(jq -c --arg p "$path" --argjson e "$events" --argjson ok "$parsed" \
			'. + [{path:$p, events:$e, parsed:$ok}]' <<<"$entries")
	done < <(jq -r '.[]? | select(.type == "file") | .path' <<<"$listing" | LC_ALL=C sort)
	_POLICY_SCAN_JSON=$(jq -cn --arg b "$default_branch" --arg v "$visibility" --argjson w "$entries" \
		'{default_branch:$b, visibility:$v, public:($v == "public"), workflows:$w}')
	return 0
}

# Print the policy body for the scan in _POLICY_SCAN_JSON.
_policy_build_body() {
	jq -ce --arg name "$POLICY_NAME" --arg rule "$POLICY_RULE_TYPE" '
		{
			name: $name,
			enforcement: "active",
			conditions: {workflow_path: {include: [.workflows[].path], exclude: []}},
			rules: [{type: $rule, parameters: {allowed_events: ([.workflows[].events[]] | unique)}}]
		}' <<<"$_POLICY_SCAN_JSON"
	return $?
}

# Print uncovered workflow paths, one per line, given the policies JSON.
_policy_uncovered_paths() {
	local policies_json="$1"
	jq -r --arg ev "$POLICY_EVENT" --arg rule "$POLICY_RULE_TYPE" --argjson pol "$policies_json" '
		def globre: gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)")
			| gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\u0001"; ".*")
			| "^" + . + "$";
		def matches($p): . as $pat | $pat == "~ALL" or $pat == $p or ($p | test($pat | globre));
		def covers($p; $evs):
			any($pol.policies[]?;
				.enforcement == "active"
				and any(.rules[]?; .type == $rule
					and ((.parameters.allowed_events // []) as $a
						| ([$ev] + $evs) | all(.[]; . as $e | $a | index($e) != null)))
				and ((.conditions.workflow_path.include // []) as $inc
					| ($inc == [] or any($inc[]; matches($p))))
				and (((.conditions.workflow_path.exclude // []) | any(matches($p))) | not));
		.workflows[] | .path as $p | .events as $evs | select(covers($p; $evs) | not) | $p' <<<"$_POLICY_SCAN_JSON"
	return $?
}

_policy_read_policies() {
	local slug="$1"
	local listing="" links="" link="" detail="" details='[]'
	listing=$(_policy_api_read "repos/${slug}/actions/policies?has_parents=true") || return 1
	links=$(jq -r '
		.policies | if type != "array" then error("invalid policies") else . end
		| .[] | ._links.self.href
		| if startswith("https://api.github.com/") then . else error("invalid policy link") end' <<<"$listing") || return 1
	while IFS= read -r link; do
		[[ -n "$link" ]] || continue
		detail=$(_policy_api_read "${link#https://api.github.com/}") || return 1
		details=$(jq -ce --argjson detail "$detail" '. + [$detail]' <<<"$details") || return 1
	done <<<"$links"
	jq -c '{total_count: length, policies: .}' <<<"$details"
	return $?
}

_policy_cmd_status() {
	local slug="$1"
	local policies="" uncovered="" count=""
	_policy_scan "$slug" || return 2
	if [[ "$(jq -r '.public' <<<"$_POLICY_SCAN_JSON")" != "$_T" ]]; then
		printf 'OK %s: not applicable (non-public repository)\n' "$slug"
		return 0
	fi
	count=$(jq -r '.workflows | length' <<<"$_POLICY_SCAN_JSON")
	if [[ "$count" -eq 0 ]]; then
		printf 'OK %s: not applicable (no %s workflows)\n' "$slug" "$POLICY_EVENT"
		return 0
	fi
	policies=$(_policy_read_policies "$slug") || {
		_policy_error "cannot read Actions policies for ${slug}" || true
		return 2
	}
	uncovered=$(_policy_uncovered_paths "$policies") || return 2
	if [[ -z "$uncovered" ]]; then
		printf 'OK %s: %s workflow(s) covered by an Actions event policy\n' "$slug" "$count"
		return 0
	fi
	printf 'UNCOVERED %s: %s not explicitly allowed by an Actions policy (blocked by default from 2026-12-02)\n' \
		"$slug" "$POLICY_EVENT"
	while IFS= read -r path; do
		printf '  %s\n' "$path"
	done <<<"$uncovered"
	printf 'Fix: %s apply --repo %s\n' "$(basename "$0")" "$slug"
	return 1
}

_policy_require_plannable() {
	local count="" bad=""
	count=$(jq -r '.workflows | length' <<<"$_POLICY_SCAN_JSON")
	if [[ "$count" -eq 0 ]]; then
		_policy_error "no ${POLICY_EVENT} workflows found; nothing to plan"
		return 1
	fi
	bad=$(jq -r '.workflows[] | select(.parsed | not) | .path' <<<"$_POLICY_SCAN_JSON")
	if [[ -n "$bad" ]]; then
		_policy_error "cannot parse on: events in: $(tr '\n' ' ' <<<"$bad")"
		return 1
	fi
	return 0
}

_policy_cmd_plan() {
	local slug="$1"
	_policy_scan "$slug" || return 2
	_policy_require_plannable || return 1
	_policy_build_body
	return $?
}

_policy_cmd_apply() {
	local slug="$1"
	local body="" policies="" policy_id="" method="POST" endpoint=""
	_policy_scan "$slug" || return 2
	_policy_require_plannable || return 1
	body=$(_policy_build_body) || return 2
	policies=$(_policy_read_policies "$slug") || {
		_policy_error "cannot read Actions policies for ${slug}" || true
		return 2
	}
	policy_id=$(jq -r --arg n "$POLICY_NAME" 'first(.policies[]? | select(.name == $n) | .id) // empty' <<<"$policies")
	endpoint="repos/${slug}/actions/policies"
	if [[ -n "$policy_id" ]]; then
		method="PUT"
		endpoint="${endpoint}/${policy_id}"
	fi
	printf '%s\n' "$body" | gh api --method "$method" -H "X-GitHub-Api-Version: ${POLICY_API_VERSION}" \
		--input - "$endpoint" >/dev/null || {
		_policy_error "${method} ${endpoint} failed"
		return 2
	}
	"${SCRIPT_DIR}/audit-log-helper.sh" log config.change \
		"actions event policy ${POLICY_NAME} ${method} on ${slug}" \
		--detail "repository=${slug}" >/dev/null 2>&1 || true
	printf 'APPLIED %s: %s (%s)\n' "$slug" "$POLICY_NAME" "$method"
	return 0
}

# Print public managed repo slugs from repos.json.
_policy_managed_public_slugs() {
	local repos_json="${AIDEVOPS_REPOS_JSON:-$REPOS_JSON_DEFAULT}"
	if [[ ! -f "$repos_json" ]]; then
		_policy_error "repos.json not found: ${repos_json}"
		return 1
	fi
	jq -r '(.initialized_repos // .repos // [])[]
		| select((.slug // "") != "" and (.local_only // false) != true and (.private // false) != true)
		| .slug' "$repos_json"
	return $?
}

_policy_cmd_all() {
	local command="$1"
	local slug="" rc=0 overall=0 total=0 uncovered=0
	local slugs=""
	slugs=$(_policy_managed_public_slugs) || return 2
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_policy_validate_repo "$slug" || continue
		total=$((total + 1))
		rc=0
		"_policy_cmd_${command}" "$slug" || rc=$?
		if [[ "$rc" -eq 1 ]]; then
			uncovered=$((uncovered + 1))
			[[ "$overall" -eq 0 ]] && overall=1
		elif [[ "$rc" -ne 0 ]]; then
			overall=2
		fi
	done <<<"$slugs"
	printf 'Summary: %s repositories checked, %s uncovered/unplannable\n' "$total" "$uncovered" >&2
	return "$overall"
}

main() {
	local command="${1:-}"
	local slug="" all=0 arg=""
	if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
		_policy_usage
		return 0
	fi
	shift
	case "$command" in
	status | plan | apply) ;;
	*)
		_policy_usage >&2
		return 2
		;;
	esac
	while [[ $# -gt 0 ]]; do
		arg="${1}"
		case "$arg" in
		--repo)
			[[ $# -ge 2 ]] || {
				_policy_error "--repo requires a value"
				return 2
			}
			slug="${2}"
			shift 2
			;;
		--all-managed)
			all=1
			shift
			;;
		*)
			_policy_error "unknown argument: ${arg}"
			return 2
			;;
		esac
	done
	_policy_require_dependencies || return 2
	if [[ "$all" -eq 1 ]]; then
		if [[ "$command" == "apply" ]]; then
			_policy_error "apply is per repository and explicit; use --repo"
			return 2
		fi
		_policy_cmd_all "$command"
		return $?
	fi
	if [[ -z "$slug" ]]; then
		_policy_error "--repo OWNER/REPO required"
		return 2
	fi
	_policy_validate_repo "$slug" || return 2
	"_policy_cmd_${command}" "$slug"
	return $?
}

main "$@"

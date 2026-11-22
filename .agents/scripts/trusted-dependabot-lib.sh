#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# trusted-dependabot-lib.sh — shared narrow trust gate for dependency updates
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_TRUSTED_DEPENDABOT_LIB_LOADED:-}" ]] && return 0
_TRUSTED_DEPENDABOT_LIB_LOADED=1

_TRUSTED_DEPENDABOT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_TRUSTED_DEPENDABOT_DIR" == "${BASH_SOURCE[0]}" ]] && _TRUSTED_DEPENDABOT_DIR="."
_TRUSTED_DEPENDABOT_LAST_PR_JSON=""
_TRUSTED_DEPENDABOT_LAST_REPO=""
_TRUSTED_DEPENDABOT_LAST_PR=""
_TRUSTED_DEPENDABOT_LAST_HEAD=""
_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON=""

_td_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_trusted_dependabot_log() {
	local message="$1"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '%s\n' "$message" >>"$LOGFILE" || true
	fi
	return 0
}

_trusted_dependabot_updates_conf() {
	local default_conf="${_TRUSTED_DEPENDABOT_DIR}/../configs/trusted-dependabot-updates.conf"
	printf '%s' "${AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF:-$default_conf}"
	return 0
}

_trusted_dependabot_dependency_allowed() {
	local package_manager="$1"
	local dependency_name="$2"
	local conf_path=""
	local entries=""

	conf_path=$(_trusted_dependabot_updates_conf)
	[[ -n "$dependency_name" && -f "$conf_path" ]] || return 1
	entries=$(sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$conf_path" 2>/dev/null | sed '/^$/d') || entries=""
	[[ -n "$entries" ]] || return 1
	if printf '%s\n' "$entries" | grep -Fxq '*'; then
		return 0
	fi
	if [[ -n "$package_manager" ]] \
		&& printf '%s\n' "$entries" | grep -Fxq "${package_manager}:${dependency_name}"; then
		return 0
	fi
	printf '%s\n' "$entries" | grep -Fxq "$dependency_name"
	return $?
}

_trusted_dependabot_dependencies_from_body() {
	local body="$1"
	local dependency_lines=""
	local dependencies=""
	local first_line=""

	dependency_lines=$(printf '%s\n' "$body" \
		| sed -nE '/^[[:space:]]*-[[:space:]]*dependency-name:/p')
	if [[ -n "$dependency_lines" ]]; then
		dependencies=$(printf '%s\n' "$dependency_lines" | awk '
			BEGIN { sq = sprintf("%c", 39) }
			{
				value = $0
				sub(/^[[:space:]]*-[[:space:]]*dependency-name:[[:space:]]*/, "", value)
				sub(/[[:space:]]*$/, "", value)
				first = substr(value, 1, 1)
				last = substr(value, length(value), 1)
				if (first == "\"" || first == sq || last == "\"" || last == sq) {
					if (length(value) < 2 || first != last || (first != "\"" && first != sq)) {
						invalid = 1
						next
					}
					value = substr(value, 2, length(value) - 2)
				}
				if (value == "" || value ~ /[[:space:]"]/ || index(value, sq) > 0) {
					invalid = 1
					next
				}
				print value
				parsed++
			}
			END { if (invalid || parsed == 0) exit 1 }
		') || return 1
		printf '%s\n' "$dependencies" | LC_ALL=C sort -u
		return 0
	fi

	first_line=$(printf '%s\n' "$body" | sed -n '1p')
	[[ "$first_line" == Bumps\ * ]] || return 1
	dependencies=$(printf '%s\n' "$first_line" \
		| grep -oE '\[[^][]+\]\(' \
		| sed -E 's/^\[//; s/\]\($//' \
		| LC_ALL=C sort -u) || dependencies=""
	[[ -n "$dependencies" ]] || return 1
	printf '%s\n' "$dependencies"
	return 0
}

_trusted_dependabot_project_pr_json() {
	local response="$1"
	printf '%s' "$response" | jq -c '
		def string_type: "string";
		def array_type: "array";
		(if ((.errors // []) | length) > 0
		 then error("GraphQL returned errors")
		 else .data.repository.pullRequest end) as $pr
		| if $pr == null then error("pull request unavailable")
		  elif (($pr.author.__typename | type) != string_type or ($pr.author.__typename | length) == 0
			or ($pr.author.login | type) != string_type or ($pr.author.login | length) == 0
			or ($pr.body | type) != string_type or ($pr.body | length) == 0
			or ($pr.headRefOid | type) != string_type or ($pr.headRefOid | length) == 0
			or ($pr.headRepository.nameWithOwner | type) != string_type or ($pr.headRepository.nameWithOwner | length) == 0
			or ($pr.headRepositoryOwner.login | type) != string_type or ($pr.headRepositoryOwner.login | length) == 0
			or ($pr.commits.nodes | type) != array_type or ($pr.commits.nodes | length) == 0
			or ($pr.files.nodes | type) != array_type or ($pr.files.nodes | length) == 0
			or ($pr.statusCheckRollup.contexts.nodes | type) != array_type or ($pr.statusCheckRollup.contexts.nodes | length) == 0
			or ([$pr.commits.nodes[] | select((.commit.authors.nodes | type) != array_type or (.commit.authors.nodes | length) == 0)] | length) > 0
			or ([$pr.files.nodes[] | select((.path | type) != string_type or (.path | length) == 0)] | length) > 0)
		  then error("trusted Dependabot snapshot is incomplete")
		  elif (($pr.commits.pageInfo.hasNextPage // false)
			or ($pr.files.pageInfo.hasNextPage // false)
			or ($pr.statusCheckRollup.contexts.pageInfo.hasNextPage // false)
			or ([$pr.commits.nodes[]?.commit.authors.pageInfo.hasNextPage // false] | any))
		  then error("trusted Dependabot snapshot is paginated")
		  else {
			author: $pr.author,
			body: $pr.body,
			headRefOid: $pr.headRefOid,
			headRepository: $pr.headRepository,
			headRepositoryOwner: $pr.headRepositoryOwner,
			commits: [$pr.commits.nodes[] | {
				authors: [.commit.authors.nodes[] | {login: (.user.login // "")}]
			}],
			files: [$pr.files.nodes[] | {path}],
			statusCheckRollup: [$pr.statusCheckRollup.contexts.nodes[]
				| if .__typename == "CheckRun" then {
					name,
					conclusion,
					status,
					workflowName: .checkSuite.workflowRun.workflow.name
				  }
				  elif .__typename == "StatusContext" then {context, state}
				  else empty end]
		  } end
	' 2>/dev/null
	return $?
}

_trusted_dependabot_project_auth_json() {
	local response="$1"

	printf '%s' "$response" | jq -ce '
		def string_type: "string";
		def array_type: "array";
		(if ((.errors // []) | length) > 0
		 then error("GraphQL returned errors")
		 else .data.repository.pullRequest end) as $pr
		| if $pr == null then error("pull request unavailable")
		  elif (($pr.author.__typename | type) != string_type or ($pr.author.__typename | length) == 0
			or ($pr.author.login | type) != string_type or ($pr.author.login | length) == 0
			or ($pr.headRefOid | type) != string_type or ($pr.headRefOid | length) == 0
			or ($pr.headRepository.nameWithOwner | type) != string_type or ($pr.headRepository.nameWithOwner | length) == 0
			or ($pr.headRepositoryOwner.login | type) != string_type or ($pr.headRepositoryOwner.login | length) == 0
			or ($pr.commits.nodes | type) != array_type or ($pr.commits.nodes | length) == 0
			or ([$pr.commits.nodes[] | select((.commit.authors.nodes | type) != array_type or (.commit.authors.nodes | length) == 0)] | length) > 0)
		  then error("Dependabot authentication snapshot is incomplete")
		  elif (($pr.commits.pageInfo.hasNextPage // false)
			or ([$pr.commits.nodes[]?.commit.authors.pageInfo.hasNextPage // false] | any))
		  then error("Dependabot authentication snapshot is paginated")
		  else {
			author: $pr.author,
			headRefOid: $pr.headRefOid,
			headRepository: $pr.headRepository,
			headRepositoryOwner: $pr.headRepositoryOwner,
			commits: [$pr.commits.nodes[] | {
				authors: [.commit.authors.nodes[] | {login: (.user.login // "")}]
			}]
		  } end
	' 2>/dev/null
	return $?
}

_trusted_dependabot_pr_json_graphql() {
	local pr_number="$1"
	local repo_slug="$2"
	local snapshot_mode="${3:-full}"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"
	local response=""
	local reported_cost=""
	local pr_json=""
	local route_decision="trusted-dependabot-exact-cost"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$owner" && -n "$name" ]] || return 1
	case "$snapshot_mode" in
	full) ;;
	auth)
		route_decision="trusted-dependabot-auth-exact-cost"
		;;
	*) return 1 ;;
	esac
	#aidevops:trust-boundary — both modes bind bot identity, exact head, repository
	# ownership, and commit authors; full mode additionally binds files and checks.
	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="$route_decision" \
		_td_gh_read gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					author { __typename login }
					body
					headRefOid
					headRepository { nameWithOwner }
					headRepositoryOwner { login }
					commits(first: 100) {
						pageInfo { hasNextPage }
						nodes {
							commit {
								authors(first: 100) {
									pageInfo { hasNextPage }
									nodes { user { login } }
								}
							}
						}
					}
					files(first: 100) { pageInfo { hasNextPage } nodes { path } }
					statusCheckRollup {
						contexts(first: 100) {
							pageInfo { hasNextPage }
							nodes {
								__typename
								... on CheckRun {
									name
									conclusion
									status
									checkSuite { workflowRun { workflow { name } } }
								}
								... on StatusContext { context state }
							}
						}
					}
				}
			}
			rateLimit { cost }
		}' 2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	if [[ "$snapshot_mode" == "auth" ]]; then
		pr_json=$(_trusted_dependabot_project_auth_json "$response") || return 1
	else
		pr_json=$(_trusted_dependabot_project_pr_json "$response") || return 1
	fi
	[[ -n "$pr_json" ]] || return 1
	printf '%s\n' "$pr_json"
	return 0
}

# Maintainer-local repos.json is the only trust root for non-Dependabot
# dependency bots (GH#39280). Repository content, including a PR, never is.
_trusted_dependency_bot_repos_json() {
	printf '%s' "${AIDEVOPS_REPOS_JSON:-${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	return 0
}

# Normalize `app/<slug>`, `<slug>[bot]`, or a bare configured slug to the
# lowercase GitHub App slug. Anything outside the App slug charset fails.
_trusted_dependency_bot_slug() {
	local value="$1"
	value="${value#app/}"
	value="${value%\[bot\]}"
	value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	[[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || return 1
	printf '%s\n' "$value"
	return 0
}

# Print the configured dependency-bot slug for a PR author, or return 1.
# Only GitHub App author forms qualify (human logins cannot contain `/` or
# `[`), and the slug must be listed in the repo's `trusted_dependency_bots`.
# Dependabot keeps its built-in lane and never resolves here. Identity is
# re-proven against the exact-head GraphQL snapshot before any routing.
_trusted_dependency_bot_for_author() {
	local pr_author="$1"
	local repo_slug="$2"
	local author_slug=""
	local repos_json=""
	local configured=""
	local entry=""

	case "$pr_author" in
	app/* | *\[bot\]) ;;
	*) return 1 ;;
	esac
	author_slug=$(_trusted_dependency_bot_slug "$pr_author") || return 1
	[[ "$author_slug" != "dependabot" && -n "$repo_slug" ]] || return 1
	repos_json=$(_trusted_dependency_bot_repos_json)
	[[ -f "$repos_json" ]] || return 1
	configured=$(jq -r --arg slug "$repo_slug" '
		.initialized_repos[]?
		| select(((.slug // "") | ascii_downcase) == ($slug | ascii_downcase))
		| .trusted_dependency_bots // []
		| arrays | .[] | strings' "$repos_json" 2>/dev/null) || return 1
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		entry=$(_trusted_dependency_bot_slug "$entry") || continue
		if [[ "$entry" == "$author_slug" ]]; then
			printf '%s\n' "$author_slug"
			return 0
		fi
	done <<<"$configured"
	return 1
}

_trusted_dependabot_snapshot_is_authentic() {
	local pr_json="$1"
	local repo_slug="$2"
	local pr_author="${3:-}"
	local expected_head_sha="${4:-}"
	local bot_slug="${5:-dependabot}"
	local repo_owner="${repo_slug%%/*}"
	local author_norm=""
	local api_author=""
	local api_author_type=""
	local head_owner=""
	local head_repo=""
	local snapshot_head=""
	local bad_commits=""

	_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="invalid-input"
	[[ -n "$pr_json" && "$pr_json" != "null" && -n "$repo_slug" && -n "$expected_head_sha" ]] || return 1
	[[ "$bot_slug" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || return 1
	author_norm=$(printf '%s' "$pr_author" | tr '[:upper:]' '[:lower:]')
	if [[ "$bot_slug" == "dependabot" ]]; then
		case "$author_norm" in
		dependabot\[bot\] | app/dependabot | "") ;;
		*)
			_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="unsupported-pr-author"
			return 1
			;;
		esac
	elif [[ "$author_norm" != "app/${bot_slug}" && "$author_norm" != "${bot_slug}[bot]" ]]; then
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="unsupported-pr-author"
		return 1
	fi

	api_author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""' 2>/dev/null) || return 1
	api_author_type=$(printf '%s' "$pr_json" | jq -r '.author.__typename // ""' 2>/dev/null) || return 1
	head_owner=$(printf '%s' "$pr_json" | jq -r '.headRepositoryOwner.login // .headRepositoryOwner.name // ""' 2>/dev/null) || return 1
	head_repo=$(printf '%s' "$pr_json" | jq -r '.headRepository.nameWithOwner // ""' 2>/dev/null) || return 1
	snapshot_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null) || return 1
	#aidevops:trust-boundary — worker intake and merge trust share this exact-head
	# GitHub Bot, repository ownership, and commit-authorship verification.
	# GH#39280: configured bots use the same proof; authenticity never grants
	# merge authority (only _is_trusted_dependabot_update_pr feeds that).
	if [[ "$api_author_type" != "Bot" || "$api_author" != "$bot_slug" ]]; then
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="bot-identity-mismatch"
		return 1
	fi
	if [[ "$head_owner" != "$repo_owner" || "$head_repo" != "$repo_slug" ]]; then
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="repository-ownership-mismatch"
		return 1
	fi
	if [[ "$snapshot_head" != "$expected_head_sha" ]]; then
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="head-mismatch"
		return 1
	fi
	bad_commits=$(printf '%s' "$pr_json" | jq --arg commit_login "${bot_slug}[bot]" '[.commits[]? | select([.authors[]?.login] | index($commit_login) | not)] | length' 2>/dev/null) || return 1
	if [[ "$bad_commits" != "0" ]]; then
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="commit-author-mismatch"
		return 1
	fi
	_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON=""
	return 0
}

_is_authentic_dependabot_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-}"
	local expected_head_sha="${4:-}"

	_is_authentic_dependency_bot_pr "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha" dependabot
	return $?
}

# Exact-head authenticity for Dependabot or a configured dependency bot.
# Authenticity only: callers must never treat success as merge authority.
_is_authentic_dependency_bot_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-}"
	local expected_head_sha="${4:-}"
	local bot_slug="${5:-dependabot}"
	local pr_json=""

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	if [[ "$_TRUSTED_DEPENDABOT_LAST_REPO" == "$repo_slug" \
		&& "$_TRUSTED_DEPENDABOT_LAST_PR" == "$pr_number" \
		&& "$_TRUSTED_DEPENDABOT_LAST_HEAD" == "$expected_head_sha" \
		&& -n "$_TRUSTED_DEPENDABOT_LAST_PR_JSON" ]]; then
		pr_json="$_TRUSTED_DEPENDABOT_LAST_PR_JSON"
	else
		_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON="snapshot-unavailable"
		pr_json=$(_trusted_dependabot_pr_json_graphql "$pr_number" "$repo_slug" auth) || return 1
		_TRUSTED_DEPENDABOT_LAST_PR_JSON="$pr_json"
		_TRUSTED_DEPENDABOT_LAST_REPO="$repo_slug"
		_TRUSTED_DEPENDABOT_LAST_PR="$pr_number"
		_TRUSTED_DEPENDABOT_LAST_HEAD="$expected_head_sha"
	fi
	_trusted_dependabot_snapshot_is_authentic "$pr_json" "$repo_slug" "$pr_author" "$expected_head_sha" "$bot_slug"
	return $?
}

_is_trusted_dependabot_update_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-}"
	local expected_head_sha="${4:-}"
	local pr_json=""
	local bad_files=""
	local security_failures=""
	local body=""
	local package_manager=""
	local dependencies=""
	local dependency_name=""
	local allowed_count=0

	[[ "${AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES:-1}" != "0" ]] || return 1
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" && -n "$expected_head_sha" ]] || return 1
	case "$pr_author" in
	dependabot\[bot\] | app/dependabot | "") ;;
	*) return 1 ;;
	esac

	pr_json=$(_trusted_dependabot_pr_json_graphql "$pr_number" "$repo_slug") || return 1
	_TRUSTED_DEPENDABOT_LAST_PR_JSON="$pr_json"
	_TRUSTED_DEPENDABOT_LAST_REPO="$repo_slug"
	_TRUSTED_DEPENDABOT_LAST_PR="$pr_number"
	_TRUSTED_DEPENDABOT_LAST_HEAD="$expected_head_sha"
	_trusted_dependabot_snapshot_is_authentic "$pr_json" "$repo_slug" "$pr_author" "$expected_head_sha" || return 1

	body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	package_manager=$(printf '%s' "$body" | sed -nE 's/^Bumps the ([A-Za-z0-9_.-]+) group.*$/\1/p' | sed -n '1p')
	# GitHub Actions updates are dependency-only only when Dependabot's declared
	# actions group changes a top-level workflow file. All other ecosystems retain
	# the manifest-and-lockfile boundary below.
	bad_files=$(printf '%s' "$pr_json" | jq -r --arg package_manager "$package_manager" '[.files[]?.path | select((test("(^|/)(requirements(-lock)?\\.txt|requirements.*\\.txt|pyproject\\.toml|poetry\\.lock|uv\\.lock|Pipfile\\.lock|package(-lock)?\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb?|composer\\.(json|lock)|Gemfile\\.lock|go\\.(mod|sum)|Cargo\\.(toml|lock))$|^\\.github/dependabot\\.yml$"; "i") or ($package_manager == "actions" and test("^\\.github/workflows/[^/]+\\.ya?ml$"; "i"))) | not)] | length' 2>/dev/null) || return 1
	[[ "$bad_files" == "0" ]] || return 1
	security_failures=$(printf '%s' "$pr_json" | jq 'def up(v): (v // "" | ascii_upcase); [.statusCheckRollup[]? | select(((.name // .context // "") | test("security|socket|codeql|dependabot"; "i")) and (up(.conclusion) == "FAILURE" or up(.conclusion) == "ERROR" or up(.state) == "FAILURE" or up(.state) == "ERROR"))] | length' 2>/dev/null) || return 1
	[[ "$security_failures" == "0" ]] || return 1
	dependencies=$(_trusted_dependabot_dependencies_from_body "$body") || return 1
	while IFS= read -r dependency_name; do
		[[ -n "$dependency_name" ]] || continue
		if ! _trusted_dependabot_dependency_allowed "$package_manager" "$dependency_name"; then
			_trusted_dependabot_log "[trusted-dependabot] PR #${pr_number} in ${repo_slug}: ${package_manager:+${package_manager}:}${dependency_name} is not allowlisted"
			return 1
		fi
		allowed_count=$((allowed_count + 1))
	done <<<"$dependencies"
	[[ "$allowed_count" -gt 0 ]] || return 1

	_trusted_dependabot_log "[trusted-dependabot] PR #${pr_number} in ${repo_slug} passed exact-head bot identity, repository, commit, file, allowlist, and security checks"
	return 0
}

_trusted_dependabot_non_review_checks_green() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_json="${3:-}"
	local result=""
	local non_review_count="0"
	local blocker_count="0"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1
	if [[ -z "$pr_json" ]]; then
		pr_json=$(_trusted_dependabot_pr_json_graphql "$pr_number" "$repo_slug") || return 1
	fi
	[[ -n "$pr_json" && "$pr_json" != "null" ]] || return 1
	result=$(printf '%s' "$pr_json" | jq -r '
		def up(v): (v // "" | ascii_upcase);
		def check_label: (.name // .context // "");
		def is_review_gate: ((check_label | test("(^|/ )review-bot-gate$|^review-bot-gate$"; "i")) or ((.workflowName // "") == "Review Bot Gate"));
		def passish: (up(.conclusion) == "SUCCESS" or up(.conclusion) == "NEUTRAL" or up(.conclusion) == "SKIPPED" or up(.state) == "SUCCESS");
		def pendingish: (up(.status) == "QUEUED" or up(.status) == "IN_PROGRESS" or up(.state) == "PENDING" or up(.state) == "EXPECTED" or ((up(.conclusion) == "") and (up(.state) != "SUCCESS") and (up(.status) != "COMPLETED")));
		. as $rollup
		| def superseded_cancel: (
			up(.conclusion) == "CANCELLED"
			and (. as $check | any($rollup.statusCheckRollup[]?; check_label == ($check | check_label) and passish))
		);
		[([$rollup.statusCheckRollup[]? | select(is_review_gate | not)] | length),
		 ([$rollup.statusCheckRollup[]? | select((is_review_gate | not) and (pendingish or ((passish or superseded_cancel) | not)))] | length)] | @tsv
	' 2>/dev/null) || return 1
	read -r non_review_count blocker_count <<<"$result"
	[[ "$non_review_count" =~ ^[0-9]+$ && "$blocker_count" =~ ^[0-9]+$ ]] || return 1
	if [[ "$non_review_count" -gt 0 && "$blocker_count" -eq 0 ]]; then
		_trusted_dependabot_log "[trusted-dependabot] PR #${pr_number} in ${repo_slug}: all non-review checks are green"
		return 0
	fi
	_trusted_dependabot_log "[trusted-dependabot] PR #${pr_number} in ${repo_slug}: checks blocked (non_review=${non_review_count}, blockers=${blocker_count})"
	return 1
}

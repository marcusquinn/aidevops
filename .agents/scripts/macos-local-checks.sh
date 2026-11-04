#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Local macOS coverage and explicit maintainer handoff; no hosted runner gate.

macos_checks_sensitive() {
	local base="$1" path="" paths=""
	paths=$(git diff --no-renames --name-only "$base" HEAD) || return 2
	while IFS= read -r path; do
		case "$path" in
		.agents/scripts/model-replay-* | .agents/scripts/*sandbox* | .agents/scripts/platform-detect.sh | \
			.agents/scripts/macos-local-checks.sh | .agents/scripts/tests/test-model-replay-* | \
			.agents/scripts/runtime-env.sh | .agents/scripts/trusted* | .agents/scripts/git | \
			.agents/scripts/native_git.py | .agents/scripts/canonical*git*.py | \
			.agents/scripts/canonical_write_policy_paths.py | .agents/scripts/command_policy_git_query.py | \
			.agents/hooks/git_safety_guard.py | .agents/scripts/tests/test-*git*.sh | .agents/scripts/setup/* | \
			.agents/plugins/opencode-aidevops/runtime-path.mjs | .agents/plugins/opencode-aidevops/source-access-* | \
			.github/workflows/path-portability.yml)
			return 0 ;;
		esac
	done <<<"$paths"
	return 1
}

macos_checks_host() {
	# An override can force handoff, never fake native macOS evidence on Linux.
	local host=""
	host=$(uname -s) || return 1
	if [[ "${AIDEVOPS_MACOS_CHECKS_HOST:-$host}" != Darwin ]]; then
		host=Other
	fi
	printf '%s\n' "$host"
	return 0
}

macos_checks_run() {
	local root="" test_script=""
	root=$(git rev-parse --show-toplevel) || return 1
	# Run from the repository root, just like the former macOS Actions leg.
	(
		cd "$root" || exit 1
		bash -c 'source .agents/scripts/platform-detect.sh; [[ "$AIDEVOPS_PLATFORM" == macos && "$AIDEVOPS_SCHEDULER" == launchd ]]' || exit 1
		node .agents/scripts/tests/test-model-replay-benchmark.mjs || exit 1
		for test_script in \
			test-runtime-env.sh test-launchd-sanitized-path.sh test-pulse-path-precedence.sh \
			test-canonical-git-command-guard.sh test-command-policy-helper.sh \
			test-tool-install-opencode.sh test-setup-source-access-broker.sh test-portable-shebangs.sh; do
			env -u GITHUB_ACTIONS bash ".agents/scripts/tests/$test_script" || exit 1
		done
		for test_script in test-source-access-helper.py test_opencode_service.py test-release-lane-owner.py; do
			python3 ".agents/scripts/tests/$test_script" || exit 1
		done
		node --test \
			.agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs \
			.agents/plugins/opencode-aidevops/tests/test-shell-env-origin.mjs \
			.agents/plugins/opencode-aidevops/tests/test-source-access-guidance.mjs \
			.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs
	) >&2 || return 1
	return 0
}

macos_checks_evidence() {
	local base="$1" sensitive_rc=0
	macos_checks_sensitive "$base" || sensitive_rc=$?
	case "$sensitive_rc" in
	1) return 0 ;;
	2) return 1 ;;
	esac
	if [[ "$(macos_checks_host)" != Darwin ]]; then
		printf '%s\n' 'macOS: not run on this host; needs-macos-verification, routed to the registered macOS maintainer.'
		return 0
	fi
	macos_checks_run || return 1
	printf 'macOS: native platform detection, model replay sandbox and PATH portability checks passed at %s.\n' "$(git rev-parse HEAD)"
	return 0
}

macos_checks_route() {
	local base="$1" pr="$2" repo="$3" maintainer="" config="${AIDEVOPS_REPOS_CONFIG:-$HOME/.config/aidevops/repos.json}" sensitive_rc=0
	macos_checks_sensitive "$base" || sensitive_rc=$?
	case "$sensitive_rc" in
	1) return 0 ;;
	2) return 1 ;;
	esac
	[[ "$(macos_checks_host)" != Darwin ]] || return 0
	maintainer=$(jq -er --arg slug "$repo" '
		[.initialized_repos[] | select(.slug == $slug)] | if length == 1 then
		(.[0].macos_maintainer // .[0].maintainer) else empty end
		| select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))' "$config") || {
		printf 'No unique registered macOS maintainer for %s; configure macos_maintainer or maintainer\n' "$repo" >&2
		return 1
	}
	gh label create needs-macos-verification --repo "$repo" --color D4C5F9 \
		--description 'Native macOS checks requested from the registered maintainer' 2>/dev/null ||
		gh api "repos/$repo/labels/needs-macos-verification" >/dev/null || return 1
	gh pr edit "$pr" --repo "$repo" --add-label needs-macos-verification || return 1
	# GitHub refuses self-review; assignment also handles maintainers who cannot review.
	# Some CLI versions return success for a self-review no-op, so verify readback.
	gh pr edit "$pr" --repo "$repo" --add-reviewer "$maintainer" 2>/dev/null || true
	if ! gh pr view "$pr" --repo "$repo" --json reviewRequests --jq '.reviewRequests[].login' | grep -Fxq "$maintainer"; then
		gh pr edit "$pr" --repo "$repo" --add-assignee "$maintainer" || return 1
	fi
	return 0
}

macos_checks_verify_pr() {
	local pr="$1" repo="$2" metadata="" head="" current_head="" base="" evidence="" body_file="" helper_dir=""
	[[ "$(macos_checks_host)" == Darwin ]] || return 1
	metadata=$(gh pr view "$pr" --repo "$repo" --json headRefOid,baseRefOid,body) || return 1
	head=$(jq -r .headRefOid <<<"$metadata")
	[[ "$(git rev-parse HEAD)" == "$head" && -z "$(git status --porcelain)" ]] || return 1
	base=$(jq -r .baseRefOid <<<"$metadata")
	base=$(git merge-base "$base" HEAD) || return 1
	evidence=$(macos_checks_evidence "$base") || return 1
	[[ -n "$evidence" ]] || return 0
	metadata=$(gh pr view "$pr" --repo "$repo" --json headRefOid,body) || return 1
	[[ "$(jq -r .headRefOid <<<"$metadata")" == "$head" && -z "$(git status --porcelain)" ]] || return 1
	body_file=$(mktemp) || return 1
	jq -r --arg evidence "$evidence" '.body | if contains("## Runtime Testing") then sub("## Runtime Testing"; "## Runtime Testing\n\n- " + $evidence) else . + "\n\n## Runtime Testing\n\n- " + $evidence end' <<<"$metadata" >"$body_file"
	helper_dir=$(dirname "${BASH_SOURCE[0]}")
	bash "$helper_dir/gh-write-helper.sh" pr edit "$pr" --repo "$repo" --body-file "$body_file" || { rm -f "$body_file"; return 1; }
	rm -f "$body_file"
	# A push during the body edit invalidates the evidence; retain the label.
	metadata=$(gh pr view "$pr" --repo "$repo" --json headRefOid) || return 1
	current_head=$(jq -r .headRefOid <<<"$metadata") || return 1
	if [[ "$current_head" != "$head" ]]; then
		printf 'macOS verification failed: PR head changed from %s to %s; keeping needs-macos-verification.\n' "$head" "$current_head" >&2
		printf '%s\n' 'Check out the new PR head in a clean worktree on a Mac and rerun verify-pr.' >&2
		return 1
	fi
	gh pr edit "$pr" --repo "$repo" --remove-label needs-macos-verification || return 1
	# A push between the check above and label removal would leave the new head
	# without a handoff (the refresh workflow's addLabels no-ops while labelled).
	metadata=$(gh pr view "$pr" --repo "$repo" --json headRefOid) || return 1
	current_head=$(jq -r .headRefOid <<<"$metadata") || return 1
	if [[ "$current_head" != "$head" ]]; then
		gh pr edit "$pr" --repo "$repo" --add-label needs-macos-verification || true
		printf 'macOS verification failed: PR head changed from %s to %s during label removal; restored needs-macos-verification.\n' "$head" "$current_head" >&2
		return 1
	fi
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
	check) macos_checks_evidence "${2:?comparison base required}" ;;
	route) macos_checks_route "${2:?comparison base required}" "${3:?PR required}" "${4:?repo required}" ;;
	verify-pr) macos_checks_verify_pr "${2:?PR required}" "${3:?repo required}" ;;
	*) printf 'Usage: bash macos-local-checks.sh check BASE | route BASE PR OWNER/REPO | verify-pr PR OWNER/REPO\n' >&2; exit 1 ;;
	esac
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for pr-supersession-helper.sh.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="${TEST_DIR}/../pr-supersession-helper.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup_repo() {
	local repo="$1"
	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo" || exit 1
		git init -q -b main
		git config user.email test@example.com
		git config user.name tester
		git config commit.gpgsign false
		printf 'base\n' >README.md
		git add -A && git commit -qm base
		git update-ref refs/remotes/origin/main main
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	)
	return 0
}

mkpr_json() {
	local number="$1"
	local title="$2"
	local body="$3"
	local head="$4"
	local file="$5"
	jq -n \
		--argjson number "$number" \
		--arg title "$title" \
		--arg body "$body" \
		--arg head "$head" \
		--arg file "$file" \
		'{number:$number,title:$title,body:$body,baseRefName:"main",headRefName:$head,files:[{path:$file}],author:{login:"tester"},url:"https://example.invalid/pr"}'
	return 0
}

classify_fixture() {
	local pr_json="$1"
	local repo="$2"
	classify_fixture_json "$pr_json" "$repo" | jq -r '.classification'
	return 0
}

classify_fixture_json() {
	local pr_json="$1"
	local repo="$2"
	bash -c 'source "$1"; _psh_classify_json "$2" "$3" 1' _ "$HELPER" "$pr_json" "$repo"
	return 0
}

repo_full="${ROOT}/full"
setup_repo "$repo_full"
(
	cd "$repo_full" || exit 1
	printf 'mention_alert_preference enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'base has deliverable'
	git update-ref refs/remotes/origin/main main
	git checkout -qb feature/full
	git update-ref refs/remotes/origin/feature/full feature/full
)
pr_full=$(mkpr_json 1 'Add mention_alert_preference' 'Core deliverable: mention_alert_preference.' 'feature/full' 'feature.txt')
got=$(classify_fixture "$pr_full" "$repo_full")
[[ "$got" == "fully_superseded" ]] \
	&& print_result "fully superseded: no branch diff + base has deliverable" 0 \
	|| print_result "fully superseded: no branch diff + base has deliverable" 1 "got=$got"

repo_partial="${ROOT}/partial"
setup_repo "$repo_partial"
(
	cd "$repo_partial" || exit 1
	printf 'mention_alert_preference enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'base has one term'
	git update-ref refs/remotes/origin/main main
	git checkout -qb feature/partial
	printf 'new_delivery_channel\n' >channel.txt
	git add channel.txt && git commit -qm 'branch has remaining work'
	git update-ref refs/remotes/origin/feature/partial feature/partial
)
pr_partial=$(mkpr_json 2 'Add mention_alert_preference new_delivery_channel' 'Core deliverables: mention_alert_preference and new_delivery_channel.' 'feature/partial' 'channel.txt' | jq '.files += [{path:"feature.txt"}]')
got=$(classify_fixture "$pr_partial" "$repo_partial")
[[ "$got" == "partially_superseded" ]] \
	&& print_result "partially superseded: exact diff retains only some original files" 0 \
	|| print_result "partially superseded: exact diff retains only some original files" 1 "got=$got"

repo_needed="${ROOT}/needed"
setup_repo "$repo_needed"
(
	cd "$repo_needed" || exit 1
	git checkout -qb feature/needed
	printf 'mention_alert_preference enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'branch has deliverable'
	git update-ref refs/remotes/origin/feature/needed feature/needed
)
pr_needed=$(mkpr_json 3 'Add mention_alert_preference' 'Core deliverable: mention_alert_preference.' 'feature/needed' 'feature.txt')
got=$(classify_fixture "$pr_needed" "$repo_needed")
[[ "$got" == "still_needed" ]] \
	&& print_result "still needed: deliverable only exists on branch" 0 \
	|| print_result "still needed: deliverable only exists on branch" 1 "got=$got"

repo_term_noise="${ROOT}/term-noise"
setup_repo "$repo_term_noise"
(
	cd "$repo_term_noise" || exit 1
	printf 'advisory_anchor enabled\n' >advisory.txt
	git add advisory.txt && git commit -qm 'base has advisory title term'
	git update-ref refs/remotes/origin/main main
	git checkout -qb feature/term-noise
	printf 'actual_delivery_anchor enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'branch has actual delivery'
	git update-ref refs/remotes/origin/feature/term-noise feature/term-noise
)
pr_term_noise=$(mkpr_json 6 'Add advisory_anchor actual_delivery_anchor' 'Deliverables: advisory_anchor and actual_delivery_anchor.' 'feature/term-noise' 'feature.txt')
got=$(classify_fixture "$pr_term_noise" "$repo_term_noise")
[[ "$got" == "still_needed" ]] \
	&& print_result "advisory title-term hits never override exact overlapping diff evidence" 0 \
	|| print_result "advisory title-term hits never override exact overlapping diff evidence" 1 "got=$got"

repo_baseline="${ROOT}/baseline"
setup_repo "$repo_baseline"
(
	cd "$repo_baseline" || exit 1
	printf 'mention_alert_preference enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'base has deliverable'
	git update-ref refs/remotes/origin/main main
	git checkout -qb feature/baseline
	printf 'stale baseline noise\n' >noise.txt
	git add noise.txt && git commit -qm 'branch has stale baseline noise'
	git update-ref refs/remotes/origin/feature/baseline feature/baseline
)
pr_baseline=$(mkpr_json 4 'Add mention_alert_preference' 'Core deliverable: mention_alert_preference.' 'feature/baseline' 'feature.txt')
got=$(classify_fixture "$pr_baseline" "$repo_baseline")
[[ "$got" == "stale_baseline_only" ]] \
	&& print_result "stale baseline only: base has deliverable, diff no longer overlaps PR files" 0 \
	|| print_result "stale baseline only: base has deliverable, diff no longer overlaps PR files" 1 "got=$got"

repo_linked_source="${ROOT}/linked-source"
repo_linked_worktree="${ROOT}/linked-worktree"
setup_repo "$repo_linked_source"
(
	cd "$repo_linked_source" || exit 1
	git checkout -qb feature/linked
	printf 'linked_worktree_delivery enabled\n' >feature.txt
	git add feature.txt && git commit -qm 'branch has linked-worktree deliverable'
	git update-ref refs/remotes/origin/feature/linked feature/linked
	git checkout -q main
	git worktree add -q "$repo_linked_worktree" feature/linked
)
pr_linked=$(mkpr_json 5 'Add linked_worktree_delivery' 'Core deliverable: linked_worktree_delivery.' 'feature/linked' 'feature.txt')
linked_json=$(classify_fixture_json "$pr_linked" "$repo_linked_worktree")
linked_class=$(printf '%s' "$linked_json" | jq -r '.classification')
linked_diff=$(printf '%s' "$linked_json" | jq -r '.current_diff_files | join(",")')
[[ "$linked_class" == "still_needed" && "$linked_diff" == "feature.txt" ]] \
	&& print_result "linked worktree: real PR diff remains available" 0 \
	|| print_result "linked worktree: real PR diff remains available" 1 "class=$linked_class diff=$linked_diff"

got=$(classify_fixture "$pr_needed" "${ROOT}/missing-repository")
[[ "$got" == "unknown" ]] \
	&& print_result "unavailable git comparison is unknown, never an empty diff" 0 \
	|| print_result "unavailable git comparison is unknown, never an empty diff" 1 "got=$got"

cleanup_contract=$(bash -c 'source "$1"; declare -f _psh_diff_files_json' _ "$HELPER")
if [[ "$cleanup_contract" == *"_save_cleanup_scope"* \
	&& "$cleanup_contract" == *"trap '_run_cleanups' RETURN"* \
	&& "$cleanup_contract" == *"push_cleanup _psh_cleanup_temp_refs"* \
	&& "$cleanup_contract" == *"_psh_delete_temp_refs \"\$repo_path\" \"\$ref_prefix\""* ]]; then
	print_result "temporary PR refs have return-trap and fast-path cleanup" 0
else
	print_result "temporary PR refs have return-trap and fast-path cleanup" 1 "cleanup contract missing"
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\nAll %s pr-supersession tests passed.\n' "$TESTS_RUN"
	exit 0
fi

exit 1

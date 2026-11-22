#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36766: consolidated withheld metas release predecessor labels, not prose refs.
set -euo pipefail
TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${TEST_SCRIPTS_DIR}/circuit-breaker-meta-filer.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
CALLS="${TEST_ROOT}/unblocks"
MODE=normal
gh() {
	local command="$1" endpoint="$2" query="${4:-}" number="" body=""
	local state=closed association=MEMBER label=circuit-breaker-meta
	[[ "$command" == api && "${3:-}" == --jq ]] || return 1
	number="${endpoint##*/}"
	case "$number" in
	300) body='_Supersedes #200 — this issue is the consolidated spec._'; state=open ;;
	200) body='_Supersedes #100 — this issue is the consolidated spec._' ;;
	100) body='<!-- circuit-breaker-meta-original:withheld -->' ;;
	*) return 1 ;;
	esac
	case "$MODE:$number" in
	cycle:100) body='_Supersedes #300 — cycle._' ;;
	outsider:200) association=NONE ;;
	unlabelled:200) label=bug ;;
	open:200) state=open ;;
	failed:200) return 1 ;;
	prose:300) body='A prose reference says Supersedes #200, not a lineage header.' ;;
	ambiguous:300) body=$'_Supersedes #200 — first._\n_Supersedes #100 — second._' ;;
	esac
	jq -nr --arg body "$body" --arg state "$state" --arg association "$association" --arg label "$label" \
		'{body:$body,state:$state,author_association:$association,labels:[{name:$label}]} '"| $query"
	return 0
}
_cb_meta_find_withheld_originals() {
	local meta_number="$1"
	# Only the predecessor label links the withheld original to this chain.
	[[ "$meta_number" != 100 ]] || printf 'owner/repo#7\n'
	return 0
}
_cb_meta_unblock_original() {
	local original_repo="$1" original_issue="$2" meta_repo="$3" meta_number="$4"
	printf '%s#%s %s#%s\n' "$original_repo" "$original_issue" "$meta_repo" "$meta_number" >>"$CALLS"
	return 0
}

lineage=$(_cb_meta_unblock_lineage 300 framework/repo)
[[ "$lineage" == $'300\n200\n100' ]]
cmd_unblock_on_merge --meta 300 --repo framework/repo
[[ "$(<"$CALLS")" == 'owner/repo#7 framework/repo#100' ]]
printf 'PASS consolidated withheld meta releases predecessor label\n'
for MODE in cycle outsider unlabelled open failed ambiguous; do
	: >"$CALLS"
	rc=0
	cmd_unblock_on_merge --meta 300 --repo framework/repo || rc=$?
	[[ "$rc" -eq 2 && ! -s "$CALLS" ]]
	printf 'PASS invalid lineage (%s) fails before mutations\n' "$MODE"
done
MODE=prose
[[ "$(_cb_meta_unblock_lineage 300 framework/repo)" == 300 ]]
printf 'PASS arbitrary prose does not authorize predecessor cleanup\n'

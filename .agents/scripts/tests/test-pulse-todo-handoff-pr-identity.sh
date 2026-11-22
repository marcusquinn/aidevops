#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#37222: execute the production handoff publisher with bounded fixtures and
# assert the PR body it composes carries exactly one explicit issue identity.
# The origin:worker guard reads the body, so a title-only reference made every
# handoff PR creation fail and deferred publication indefinitely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"

CAPTURED_BODY="${TEST_ROOT}/captured-body.md"
CAPTURED_TITLE="${TEST_ROOT}/captured-title.txt"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/gh-closing-reference-lib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-todo-publication.sh"

LINKAGE_REF="20307"

# Bounded fixtures: the publisher's collaborators are replaced, the body
# composition and identity extraction under test are the production ones.
_planning_publish_snapshot_readonly() {
	local snapshot="$3"
	printf 'TODO.md\n' >"$snapshot"
	return 0
}

_pulse_todo_sync_exact_default_snapshot() {
	return 0
}

planning_publish() {
	PLANNING_PUBLISHED_COMMIT="1a5795f5e9533f610df158dca93ca12529488db7"
	return 0
}

git() {
	local arg=""
	for arg in "$@"; do
		case "$arg" in
		hash-object)
			cat >/dev/null
			printf '%s\n' "b3097bfa5c0a942a1c2d3e4f5a6b7c8d9e0f1a2b"
			return 0
			;;
		diff)
			printf '+- [ ] t19258 Add copy-bound offline guidance ref:GH#%s\n' "$LINKAGE_REF"
			return 0
			;;
		ls-remote)
			return 0
			;;
		esac
	done
	return 0
}

gh() {
	local command="$1"
	shift
	case "$command" in
	pr) printf '[]\n' ;;
	repo) printf 'ADMIN\n' ;;
	*) return 1 ;;
	esac
	return 0
}

gh_create_pr() {
	local index=0
	local -a args=("$@")
	while [[ "$index" -lt "${#args[@]}" ]]; do
		case "${args[$index]}" in
		--title)
			index=$((index + 1))
			printf '%s\n' "${args[$index]}" >"$CAPTURED_TITLE"
			;;
		--body-file)
			index=$((index + 1))
			cp "${args[$index]}" "$CAPTURED_BODY"
			;;
		*) ;;
		esac
		index=$((index + 1))
	done
	printf 'https://github.com/marcusquinn/aidevops/pull/37225\n'
	return 0
}

failures=0

report() {
	local outcome="$1" label="$2" detail="${3:-}"
	if [[ "$outcome" == pass ]]; then
		printf 'PASS  %s\n' "$label"
		return 0
	fi
	printf 'FAIL  %s%s\n' "$label" "${detail:+ — ${detail}}"
	failures=$((failures + 1))
	return 0
}

rc=0
pulse_todo_publication_handoff \
	"${TEST_ROOT}/workspace" "marcusquinn/aidevops" "main" \
	"265f36f4e" "TODO.md" "publish" || rc=$?

# The publisher reports 4 after creating a reviewable handoff.
if [[ "$rc" -eq 4 ]]; then
	report pass "handoff reports created (rc=4)"
else
	report fail "handoff reports created (rc=4)" "rc=${rc}"
fi

if [[ -s "$CAPTURED_BODY" ]]; then
	report pass "body reached PR creation"
else
	report fail "body reached PR creation" "no body captured"
	printf '\n%s test(s) failed\n' "$failures"
	exit 1
fi

# The regression: the guard inspects the body, so the identity must be there
# and must be unambiguous.
explicit=$(_gh_pr_body_explicit_issues "$(cat "$CAPTURED_BODY")" || true)
explicit_count=$(printf '%s' "$explicit" | grep -c '[0-9]' || true)
if [[ "$explicit" == "$LINKAGE_REF" ]]; then
	report pass "body yields exactly one explicit issue (#${LINKAGE_REF})"
else
	report fail "body yields exactly one explicit issue (#${LINKAGE_REF})" \
		"got [${explicit//$'\n'/,}] count=${explicit_count}"
fi

# A planning handoff closes nothing, so the declaration must be non-closing.
if grep -qE '^For #'"${LINKAGE_REF}"'$' "$CAPTURED_BODY"; then
	report pass "standalone non-closing For #N line present"
else
	report fail "standalone non-closing For #N line present"
fi
if grep -qiE '^(close[sd]?|fixe?[sd]?|resolve[sd]?) #' "$CAPTURED_BODY"; then
	report fail "handoff body must not close an issue"
else
	report pass "handoff body must not close an issue"
fi

# Linkage stays secondary: the guard skips it, so it must not be the identity.
if grep -qE '^## Related issues$' "$CAPTURED_BODY"; then
	report pass "linkage retained under Related issues heading"
else
	report fail "linkage retained under Related issues heading"
fi

if [[ -s "$CAPTURED_TITLE" ]] && grep -qFx "GH#${LINKAGE_REF}: sync verified TODO refs" "$CAPTURED_TITLE"; then
	report pass "title identity matches body identity"
else
	report fail "title identity matches body identity" "got [$(cat "$CAPTURED_TITLE" 2>/dev/null || true)]"
fi

# Defence in depth: the extraction pipeline ends in sed, which succeeds on
# empty input, so a linkage without any numeric reference must fail the handoff
# instead of composing a "GH#:" title and a bare "For #" body.
_pulse_todo_handoff_linkage() {
	printf -- '- Ref #none\n'
	return 0
}
: >"$CAPTURED_BODY"
rc=0
pulse_todo_publication_handoff \
	"${TEST_ROOT}/workspace" "marcusquinn/aidevops" "main" \
	"265f36f4e" "TODO.md" "publish" || rc=$?
if [[ "$rc" -eq 1 ]] && [[ ! -s "$CAPTURED_BODY" ]]; then
	report pass "non-numeric linkage fails the handoff before PR creation"
else
	report fail "non-numeric linkage fails the handoff before PR creation" \
		"rc=${rc} body_bytes=$(wc -c <"$CAPTURED_BODY" | tr -d ' ')"
fi

if [[ "$failures" -eq 0 ]]; then
	printf '\nAll handoff PR identity checks passed\n'
	exit 0
fi
printf '\n%s check(s) failed\n' "$failures"
exit 1

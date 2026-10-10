#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for unified /review discovery and
# parent-session /review-issue-pr routing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COMMAND_LIB="${SCRIPT_DIR}/../generate-runtime-config-commands.sh"
REVIEW_COMMAND_SOURCE="${SCRIPT_DIR}/../commands/review.md"
FULL_LOOP_SOURCE="${SCRIPT_DIR}/../../workflows/full-loop.md"
REVIEW_CORE_SOURCE="${SCRIPT_DIR}/../../reference/review-core.md"
MAINTAINER_WORKFLOW_SOURCE="${SCRIPT_DIR}/../../workflows/review-issue-pr.md"
TMP_DIR=$(mktemp -d -t aidevops-review-command.XXXXXX) || exit 1
COMMAND_DIR="${TMP_DIR}/commands"

cleanup() {
	local tmp_dir="$TMP_DIR"
	local tmp_base="${tmp_dir##*/}"
	[[ "$tmp_base" == aidevops-review-command.* ]] || return 1
	rm -rf "$tmp_dir"
	return 0
}
trap cleanup EXIT

mkdir -p "$COMMAND_DIR" || exit 1

grep -Fq 'agent: Build+' "$REVIEW_COMMAND_SOURCE" || {
	printf 'FAIL unified review command does not target Build+\n' >&2
	exit 1
}
grep -Fq 'workflows/review.md' "$REVIEW_COMMAND_SOURCE" || {
	printf 'FAIL unified review command does not load the canonical workflow\n' >&2
	exit 1
}
grep -Fq 'reference/review-core.md' "$FULL_LOOP_SOURCE" || {
	printf 'FAIL full-loop does not load the shared review policy\n' >&2
	exit 1
}
grep -Fq "judges a report's technical merit independently from" "$REVIEW_CORE_SOURCE" || {
	printf 'FAIL shared review policy does not separate approval from execution readiness\n' >&2
	exit 1
}
grep -Fq 'Never require reporters to supply aidevops brief-schema' "$MAINTAINER_WORKFLOW_SOURCE" || {
	printf 'FAIL maintainer workflow makes internal schema a reporter prerequisite\n' >&2
	exit 1
}
grep -Fq 'project/maintainer responsible for adding files, implementation pattern, verification, tier, and dispatch metadata' "$MAINTAINER_WORKFLOW_SOURCE" || {
	printf 'FAIL maintainer workflow does not assign enrichment ownership\n' >&2
	exit 1
}
grep -Fq 'readiness failure alone must not rewrite an otherwise valid issue verdict' "$MAINTAINER_WORKFLOW_SOURCE" || {
	printf 'FAIL maintainer workflow does not preserve verdicts across dispatch validation\n' >&2
	exit 1
}

REVIEW_WORKFLOW_SOURCE="${SCRIPT_DIR}/../../workflows/review.md"
grep -Fq 'blind build' "$REVIEW_WORKFLOW_SOURCE" || {
	printf 'FAIL review workflow does not document blind packet activation\n' >&2
	exit 1
}
grep -Fq 'Final requirements check' "$FULL_LOOP_SOURCE" || {
	printf 'FAIL full-loop lacks the final requirements check\n' >&2
	exit 1
}
grep -Fq 'Default closeout output is P0 only' "$REVIEW_CORE_SOURCE" || {
	printf 'FAIL review core lost the P0-only closeout default\n' >&2
	exit 1
}

# shellcheck source=../generate-runtime-config-commands.sh
source "$COMMAND_LIB"

# A previous generator left this command permanently routed to a child session.
printf '%s\n' '---' 'agent: Build+' 'subtask: true' '---' 'stale body' >"${COMMAND_DIR}/review-issue-pr.md"

_generate_hardcoded_quality_commands "opencode" "$COMMAND_DIR"
[[ "$_GENERATED_HARDCODED_COMMAND_COUNT" -eq 4 ]] || {
	printf 'FAIL expected four generated quality commands, got %s\n' "$_GENERATED_HARDCODED_COMMAND_COUNT" >&2
	exit 1
}
grep -Fq 'agent: Build+' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not target Build+\n' >&2
	exit 1
}
if grep -Fq 'subtask: true' "${COMMAND_DIR}/review-issue-pr.md"; then
	printf 'FAIL review command still forces a child session\n' >&2
	exit 1
fi
grep -Fq 'workflows/review-issue-pr.md' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL stale review command body was not refreshed\n' >&2
	exit 1
}
grep -Fq 'workflows/review.md' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not load the shared review policy\n' >&2
	exit 1
}
grep -Fq 'End every completed review with the exact ready-to-run approval command' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not require approval command output\n' >&2
	exit 1
}
grep -Fq 'subtask: true' "${COMMAND_DIR}/agent-review.md" || {
	printf 'FAIL agent-review lost its explicit child-session routing\n' >&2
	exit 1
}
if grep -Fq 'subtask: true' "${COMMAND_DIR}/postflight.md"; then
	printf 'FAIL postflight must stay in the primary session\n' >&2
	exit 1
fi

# A stale release file with a forced child session must be replaced.
printf '%s\n' '---' 'agent: Build+' 'subtask: true' '---' 'stale body' >"${COMMAND_DIR}/release.md"

_generate_hardcoded_commands "opencode" "$COMMAND_DIR" || {
	printf 'FAIL successful hardcoded generation returned nonzero\n' >&2
	exit 1
}
[[ "$_GENERATED_HARDCODED_COMMAND_COUNT" -eq 7 ]] || {
	printf 'FAIL expected seven total hardcoded commands, got %s\n' "$_GENERATED_HARDCODED_COMMAND_COUNT" >&2
	exit 1
}

for _cmd in release onboarding setup-aidevops postflight; do
	grep -Fq 'agent: Build+' "${COMMAND_DIR}/${_cmd}.md" || {
		printf 'FAIL %s does not target Build+\n' "$_cmd" >&2
		exit 1
	}
	if grep -Fq 'subtask:' "${COMMAND_DIR}/${_cmd}.md"; then
		printf 'FAIL %s writes a subtask line\n' "$_cmd" >&2
		exit 1
	fi
done
grep -Fq 'aidevops release [patch|minor|major]' "${COMMAND_DIR}/release.md" || {
	printf 'FAIL release body lacks the canonical entry point\n' >&2
	exit 1
}

printf 'PASS review-issue-pr command routing stays in the parent session\n'
exit 0

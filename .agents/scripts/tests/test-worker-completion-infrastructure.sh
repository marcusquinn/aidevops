#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
scripts_dir="$(cd "${test_dir}/.." && pwd)" || exit 1
failures=0

# shellcheck source=../worker-lifecycle-common.sh
source "${scripts_dir}/worker-lifecycle-common.sh"

# Load the self-contained evidence mapper without running the helper entrypoint.
eval "$(sed -n '/^_derive_worker_failure_evidence() {/,/^}/p' "${scripts_dir}/headless-runtime-helper.sh")"

for reason in github_api_timeout command_policy_timeout prepared_commit_push_blocked completed_locally_remote_completion_blocked; do
	if ! _worker_failure_reason_is_completion_infrastructure "$reason"; then
		printf 'FAIL: %s was not classified as completion infrastructure\n' "$reason"
		failures=$((failures + 1))
		continue
	fi

	evidence=$(_derive_worker_failure_evidence blocked 1 1 natural "$reason")
	cause="${evidence%%$'\t'*}"
	next_action="${evidence#*$'\t'}"
	if [[ "$cause" != "$reason" || "$next_action" != "resume_session_with_completion_contract" ]]; then
		printf 'FAIL: %s mapped to cause=%s action=%s\n' "$reason" "$cause" "$next_action"
		failures=$((failures + 1))
	else
		printf 'PASS: %s resumes the completion contract\n' "$reason"
	fi
done

if _worker_failure_reason_is_completion_infrastructure worker_noop_zero_output; then
	printf 'FAIL: implementation no-work was misclassified as infrastructure\n'
	failures=$((failures + 1))
else
	printf 'PASS: implementation no-work remains outside infrastructure classification\n'
fi

exit "$failures"

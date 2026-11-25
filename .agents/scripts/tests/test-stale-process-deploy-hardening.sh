#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for bounded relationship sync and Bash 3.2-safe deploys.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
DEPLOY_FILE="${SCRIPTS_DIR}/setup/modules/agent-deploy.sh"
REL_FILE="${SCRIPTS_DIR}/issue-sync-relationships.sh"
REF_FILE="${SCRIPTS_DIR}/issue-sync-lib-ref.sh"
REL_FILES=("$REL_FILE" "$REF_FILE" "${SCRIPTS_DIR}/issue-sync-relationships-gh.sh" "${SCRIPTS_DIR}/issue-sync-relationships-backfill.sh")

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

if ! grep -q 'if \[\[ ${#_deploy_agent_plugin_namespaces\[@\]} -gt 0 \]\]' \
	< <(grep -A8 '_collect_deploy_agent_plugin_namespaces "$plugins_file"' "$DEPLOY_FILE"); then
	fail "empty plugin namespace arrays are not guarded before expansion"
fi

if rg -n '^\s*(result|payload|current_labels|has|meta|list_json|body|rest_nid|repository_id|issue_json|node_id)=\$\(gh |^\s*(if ! )?gh issue (edit|view)' \
	"${REL_FILES[@]}" >/dev/null; then
	fail "relationship sync contains an unbounded GitHub CLI call"
fi

read_wrapped=$(rg -c '_gh_with_timeout read gh ' "${REL_FILES[@]}" | awk -F: '{ total += $2 } END { print total + 0 }')
write_wrapped=$(rg -c '_gh_with_timeout write gh ' "${REL_FILES[@]}" | awk -F: '{ total += $2 } END { print total + 0 }')
[[ "$read_wrapped" -ge 10 ]] || fail "expected at least 10 bounded relationship reads, got $read_wrapped"
[[ "$write_wrapped" -ge 5 ]] || fail "expected at least 5 bounded relationship writes, got $write_wrapped"

printf 'PASS: stale process and deploy hardening invariants\n'
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEP_GRAPH="${REPO_ROOT}/.agents/scripts/pulse-dep-graph.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/dep.log"
export LOGFILE
DEP_GRAPH_CACHE_FILE="${TEST_ROOT}/missing-cache.json"
export DEP_GRAPH_CACHE_FILE
DEP_GRAPH_CACHE_TTL=60
export DEP_GRAPH_CACHE_TTL

gh_issue_list() {
	printf '[{"number":25542,"title":"t18005: closed blocker","state":"CLOSED"}]\n'
	return 0
}

# shellcheck source=/dev/null
source "$DEP_GRAPH"

repo_path="${TEST_ROOT}/repo"
mkdir -p "$repo_path"
cat >"${repo_path}/TODO.md" <<'EOF'
- [ ] t18005 vault: messaging ref:GH#25542
EOF

issue_body="**Blocked by:** \`t18005\`"
if PULSE_DEP_GRAPH_REPO_PATH="$repo_path" is_blocked_by_unresolved "$issue_body" 'owner/repo' '25543'; then
	if grep -q 'blocked-by-todo-drift t18005' "$LOGFILE"; then
		printf 'PASS todo drift blocks dispatch\n'
		exit 0
	fi
	printf 'FAIL dispatch blocked but drift log missing\n' >&2
	exit 1
fi

printf 'FAIL closed GitHub blocker with incomplete TODO did not block dispatch\n' >&2
exit 1

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGFILE="$TMP_DIR/pulse.log"
REPOS_JSON="$TMP_DIR/repos.json"
export LOGFILE REPOS_JSON

gh_issue_list() {
	printf '%s\n' '[
		{"number": 101, "labels": [{"name":"status:available"},{"name":"function-complexity-debt"}]},
		{"number": 102, "labels": [{"name":"status:available"},{"name":"function-complexity-debt"},{"name":"tier:thinking"}]},
		{"number": 103, "labels": [{"name":"status:available"},{"name":"function-complexity-debt"},{"name":"auto-dispatch"}]},
		{"number": 104, "labels": [{"name":"status:available"},{"name":"function-complexity-debt"},{"name":"needs-maintainer-review"}]},
		{"number": 105, "labels": [{"name":"status:available"},{"name":"function-complexity-debt"},{"name":"no-auto-dispatch"}]}
	]'
	return 0
}

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
		printf '%s\t%s\n' "$3" "${7:-}" >>"$TMP_DIR/edits.tsv"
		return 0
	fi
	return 1
}

# shellcheck source=../pulse-triage-evaluation.sh
source "$SCRIPT_DIR/pulse-triage-evaluation.sh"

updated="$(_backfill_simplification_auto_dispatch_labels "marcusquinn/aidevops")"
[[ "$updated" == "2" ]]

grep -q $'^101\tauto-dispatch,tier:standard$' "$TMP_DIR/edits.tsv"
grep -q $'^102\tauto-dispatch$' "$TMP_DIR/edits.tsv"
if grep -q '^103' "$TMP_DIR/edits.tsv"; then
	exit 1
fi
if grep -q '^104' "$TMP_DIR/edits.tsv"; then
	exit 1
fi
if grep -q '^105' "$TMP_DIR/edits.tsv"; then
	exit 1
fi

printf 'PASS simplification auto-dispatch backfill\n'

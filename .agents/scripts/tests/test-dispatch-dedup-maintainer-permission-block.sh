#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata='{"state":"OPEN","labels":[{"name":"needs-maintainer-permissions"}],"assignees":[],"createdAt":"2026-07-14T00:00:00Z"}'
output=""
rc=0
output=$(ISSUE_META_JSON="$metadata" "${SCRIPT_DIR}/dispatch-dedup-helper.sh" is-assigned 123 owner/repo runner 2>&1) || rc=$?

if [[ "$rc" -ne 0 || "$output" != *"MAINTAINER_PERMISSIONS_BLOCKED"* ]]; then
	printf 'dedup helper did not enforce the maintainer-permission block: rc=%s output=%s\n' "$rc" "$output" >&2
	exit 1
fi

printf 'dispatch dedup maintainer-permission tests passed\n'

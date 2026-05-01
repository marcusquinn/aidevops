#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

pattern='^[[:space:]]*export PATH="[^"]*/home/linuxbrew/.linuxbrew/bin'
matches="$(rg -n "$pattern" "${REPO_ROOT}/.agents/scripts" --glob '*.sh' 2>/dev/null || true)"

if [[ -n "$matches" ]]; then
	printf 'FAIL: unconditional Linuxbrew PATH exports remain:
%s
' "$matches" >&2
	exit 1
fi

printf 'PASS: no unconditional Linuxbrew PATH exports found
'

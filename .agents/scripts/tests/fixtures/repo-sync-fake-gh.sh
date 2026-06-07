#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit "${FAKE_GH_AUTH_STATUS:-0}"
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "git-credential" ]]; then
	exit 0
fi

exit 1

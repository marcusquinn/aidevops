#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Prune scratch through the shared owner-aware task lifecycle policy.
# Manual invocation defaults to dry-run; pulse/storage cleanup pass --force.
# Supports --max-seconds N (0 = unbounded), --batch-size N (default 200).
set -euo pipefail

main() {
	local script_dir=""
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	bash "$script_dir/task-temp-helper.sh" cleanup "$@" || return 1
	return 0
}

main "$@"

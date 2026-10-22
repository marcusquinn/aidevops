#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Select an existing interpreter only; callers decide whether to bootstrap.
tabby_python() {
	local python_env="${1:-${AIDEVOPS_TABBY_PYTHON_ENV:-${HOME}/.aidevops/.agent-workspace/python-env/tabby}}"
	local isolated_python="${python_env}/bin/python3"
	if [[ -x "$isolated_python" ]] && "$isolated_python" -c 'import yaml' >/dev/null 2>&1; then
		printf '%s\n' "$isolated_python"
	elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
		printf '%s\n' python3
	else
		return 1
	fi
	return 0
}

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
	printf '%s\n' \
		'[ERROR] Refusing to execute the user-managed source-access helper as root.' \
		'Use the installed root-owned broker under /etc/aidevops/source-access.' >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-env.sh
source "${SCRIPT_DIR}/runtime-env.sh"

# Interpreter and sudo come from PATH, but only files the caller cannot modify
# are accepted (#aidevops:trust-boundary): no fixed FHS locations.
_source_access_trusted() {
	local tool="$1"
	aidevops_resolve_trusted_tool "$tool" && return 0
	printf '[ERROR] No trusted %s found on PATH for source access.\n' "$tool" >&2
	return 1
}
python_bin=$(_source_access_trusted python3) || exit 1

# Only an explicitly named human ceremony may cross the privilege boundary.
# Metadata preparation and ordinary update/status operations never invoke sudo.
case "${1:-}" in
approve-bundle | cancel-proposal)
	if [[ ! -t 0 || ! -t 1 ]]; then
		printf '%s\n' '[ERROR] Bundle approval/cancellation requires an attached human terminal; cached sudo is not used.' >&2
		exit 1
	fi
	sudo_bin=$(_source_access_trusted sudo) || exit 1
	# #aidevops:trust-boundary -- execute only the installed immutable broker,
	# never the user-managed Python/helper closure under elevated privileges.
	exec "$sudo_bin" -k "$python_bin" -I -B /etc/aidevops/source-access/source-access-helper.py "$@"
	;;
esac

exec "$python_bin" -I -B "${SCRIPT_DIR}/source-access-helper.py" "$@"

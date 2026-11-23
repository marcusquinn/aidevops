#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Test-only registry CLI launcher. No production opt-in or host census is used.
setup_lifecycle_process_fixture() {
	local root="$1"
	local scripts="$2"
	local library="${BASH_SOURCE[0]%/*}"
	[[ -d "$root" && -d "$scripts" ]] || return 1
	export LIFECYCLE_FIXTURE_ROOT="$root"
	export LIFECYCLE_FIXTURE_ENTRY="${scripts}/../worker-lifecycle/worker-registry.py"
	export LIFECYCLE_FIXTURE_RUNNER="${library}/lifecycle_process_fixture.py"
	LIFECYCLE_FIXTURE_PYTHON=$(type -P python3) || return 1
	export LIFECYCLE_FIXTURE_PYTHON
	mkdir -p "$root/process-bin" || return 1
	cat >"$root/process-bin/python3" <<'SH'
#!/usr/bin/env bash
# Intercept only the exact registry entry point, including its isolated flags.
args=("$@")
while [[ "${1:-}" == "-E" || "${1:-}" == "-s" || "${1:-}" == "-B" ]]; do shift; done
if [[ "${1:-}" == "$LIFECYCLE_FIXTURE_ENTRY" ]]; then
	shift
	exec "$LIFECYCLE_FIXTURE_PYTHON" -E -s -B "$LIFECYCLE_FIXTURE_RUNNER" "$@"
fi
exec "$LIFECYCLE_FIXTURE_PYTHON" "${args[@]}"
SH
	chmod +x "$root/process-bin/python3" || return 1
	"$LIFECYCLE_FIXTURE_PYTHON" -E -s -B "$LIFECYCLE_FIXTURE_RUNNER" --self-test || return 1
	export PATH="$root/process-bin:$PATH"
	return 0
}

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for setup_serve_sim in setup/modules/tool-install.sh.
# The tests exercise supported-host install prompting without performing any
# network or global package installation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_INSTALL="$REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh"

SANDBOX="$(mktemp -d -t tool-install-serve-sim-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

assert_eq() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$desc"
		PASS=$((PASS + 1))
		return 0
	fi
	printf '  FAIL: %s -- expected %s, got %s\n' "$desc" "$expected" "$actual" >&2
	FAIL=$((FAIL + 1))
	return 1
}

extract_functions() {
	awk '
		/^_setup_serve_sim_node_version_ok\(\)/, /^}$/ { print; next }
		/^_setup_serve_sim_cli_version\(\)/, /^}$/ { print; next }
		/^setup_serve_sim\(\)/, /^}$/ { print; next }
	' "$TOOL_INSTALL" >"$SANDBOX/extract.sh"
	if ! grep -q '^setup_serve_sim()' "$SANDBOX/extract.sh"; then
		printf 'FAIL: extraction did not capture setup_serve_sim\n' >&2
		exit 1
	fi
	return 0
}

write_shim() {
	local path="$1"
	local body="$2"
	printf '%s\n' '#!/usr/bin/env bash' >"$path"
	printf '%s\n' "$body" >>"$path"
	chmod +x "$path"
	return 0
}

source_extracted() {
	print_info() { printf 'INFO: %s\n' "$*"; return 0; }
	print_success() { printf 'OK: %s\n' "$*"; return 0; }
	print_warning() { printf 'WARN: %s\n' "$*"; return 0; }
	setup_prompt() {
		local var_name="$1"
		local prompt_text="$2"
		local default_value="$3"
		: "$prompt_text"
		if [[ "${SETUP_PROMPT_MODE:-default}" == "leave-unset" ]]; then
			return 0
		fi
		printf -v "$var_name" '%s' "$default_value"
		return 0
	}
	run_with_spinner() {
		local label="$1"
		shift
		: "$label"
		"$@"
		return $?
	}
	npm_global_install() {
		local package_name="$1"
		printf '%s\n' "$package_name" >>"$SANDBOX/install.log"
		return 0
	}
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	return 0
}

source_extracted_with_prompt_failure() {
	print_info() { printf 'INFO: %s\n' "$*"; return 0; }
	print_success() { printf 'OK: %s\n' "$*"; return 0; }
	print_warning() { printf 'WARN: %s\n' "$*"; return 0; }
	setup_prompt() {
		return 1
	}
	run_with_spinner() {
		local label="$1"
		shift
		: "$label"
		"$@"
		return $?
	}
	npm_global_install() {
		local package_name="$1"
		printf '%s\n' "$package_name" >>"$SANDBOX/install.log"
		return 0
	}
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	return 0
}

run_setup_with_env() {
	local arch="$1"
	local node_version="$2"
	local include_serve_sim="$3"
	local prompt_mode="${4:-default}"
	local bin_dir="$SANDBOX/bin-$arch-$node_version-$include_serve_sim"
	mkdir -p "$bin_dir"
	: >"$SANDBOX/install.log"

	write_shim "$bin_dir/uname" "case \"\${1:-}\" in -s) printf '%s\\n' Darwin ;; -m) printf '%s\\n' '$arch' ;; *) printf '%s\\n' Darwin ;; esac"
	write_shim "$bin_dir/xcrun" "[[ \"\${1:-}\" == simctl && \"\${2:-}\" == list && \"\${3:-}\" == devices ]] && exit 0; exit 0"
	write_shim "$bin_dir/node" "[[ \"\${1:-}\" == --version ]] && { printf '%s\\n' '$node_version'; exit 0; }; exit 0"
	write_shim "$bin_dir/npm" "exit 0"
	if [[ "$include_serve_sim" == "yes" ]]; then
		write_shim "$bin_dir/serve-sim" "[[ \"\${1:-}\" == --version ]] && { printf '%s\\n' '0.1.43'; exit 0; }; exit 0"
	fi

	(
		PATH="$bin_dir:/usr/bin:/bin" SETUP_PROMPT_MODE="$prompt_mode" source_extracted
		PATH="$bin_dir:/usr/bin:/bin" SETUP_PROMPT_MODE="$prompt_mode" setup_serve_sim
	) >"$SANDBOX/out.log" 2>&1
	printf '%s\n' "$(wc -l <"$SANDBOX/install.log" | tr -d ' ')"
	return 0
}

run_setup_with_prompt_failure() {
	local bin_dir="$SANDBOX/bin-prompt-failure"
	mkdir -p "$bin_dir"
	: >"$SANDBOX/install.log"

	write_shim "$bin_dir/uname" "case \"\${1:-}\" in -s) printf '%s\\n' Darwin ;; -m) printf '%s\\n' arm64 ;; *) printf '%s\\n' Darwin ;; esac"
	write_shim "$bin_dir/xcrun" "[[ \"\${1:-}\" == simctl && \"\${2:-}\" == list && \"\${3:-}\" == devices ]] && exit 0; exit 0"
	write_shim "$bin_dir/node" "[[ \"\${1:-}\" == --version ]] && { printf '%s\\n' 'v20.0.0'; exit 0; }; exit 0"
	write_shim "$bin_dir/npm" "exit 0"

	(
		PATH="$bin_dir:/usr/bin:/bin" source_extracted_with_prompt_failure
		PATH="$bin_dir:/usr/bin:/bin" setup_serve_sim
	) >"$SANDBOX/out.log" 2>&1
	printf '%s\n' "$(wc -l <"$SANDBOX/install.log" | tr -d ' ')"
	return 0
}

extract_functions

(
	source_extracted
	_setup_serve_sim_node_version_ok "v20.0.0"
) >/dev/null 2>&1
assert_eq "Node 20 satisfies serve-sim engine" "0" "$?"

rc=0
(
	source_extracted
	_setup_serve_sim_node_version_ok "v18.19.0"
) >/dev/null 2>&1 || rc=$?
assert_eq "Node 18 fails serve-sim engine" "1" "$rc"

assert_eq "Supported arm64 host prompts/install path" "1" "$(run_setup_with_env arm64 v20.0.0 no)"
assert_eq "Unset prompt response uses safe default expansion" "1" "$(run_setup_with_env arm64 v20.0.0 no leave-unset)"
assert_eq "Existing serve-sim suppresses install" "0" "$(run_setup_with_env arm64 v20.0.0 yes)"
assert_eq "Intel Mac skips install" "0" "$(run_setup_with_env x86_64 v20.0.0 no)"
assert_eq "Old Node skips install" "0" "$(run_setup_with_env arm64 v16.20.0 no)"
assert_eq "Prompt failure skips serve-sim install without set -u error" "0" "$(run_setup_with_prompt_failure)"

if [[ "$FAIL" -gt 0 ]]; then
	printf 'FAIL: %s serve-sim setup checks failed\n' "$FAIL" >&2
	exit 1
fi

printf 'PASS: %s serve-sim setup checks passed\n' "$PASS"
exit 0

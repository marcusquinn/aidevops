#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../stagehand-v4-helper.sh"
SOURCE="${SCRIPT_DIR}/../../tools/browser/stagehand-v4-example.mjs.txt"
PROBE_SOURCE="${SCRIPT_DIR}/../../tools/browser/stagehand-v4-nanogpt-probe.mjs.txt"
TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_BASE"
TEST_HOME="$(mktemp -d "${TEMP_BASE}/stagehand-v4-route.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

if HOME="$TEST_HOME" bash "$HELPER" status >/dev/null 2>&1; then
	printf 'Uninstalled Stagehand v4 must not report success\n' >&2
	exit 1
fi

INSTALL_DIR="${TEST_HOME}/.aidevops/stagehand-v4"
mkdir -p "${INSTALL_DIR}/node_modules/@browserbasehq/stagehand" "${INSTALL_DIR}/node_modules/zod"
printf '{"version":"4.1.0"}\n' >"${INSTALL_DIR}/node_modules/@browserbasehq/stagehand/package.json"
printf '{"version":"4.4.3"}\n' >"${INSTALL_DIR}/node_modules/zod/package.json"
HOME="$TEST_HOME" bash "$HELPER" status >/dev/null

[[ -f "$PROBE_SOURCE" ]] || exit 1
if HOME="$TEST_HOME" bash "$HELPER" probe live >/dev/null 2>&1; then
	printf 'Uninstalled Stagehand v4 must refuse live probe\n' >&2
	exit 1
fi

assert_probe() {
	local fixture="$1" cap="$2" expected="$3" output
	output="$(HOME="$TEST_HOME" STAGEHAND_PROBE_MAX_USD="$cap" bash "$HELPER" probe offline "$fixture" 2>/dev/null)" && {
		[[ "$expected" == "ok" ]] || { printf 'Fixture %s unexpectedly passed\n' "$fixture" >&2; return 1; }
		PROBE_RECEIPT="$output" node -e '
			const r = JSON.parse(process.env.PROBE_RECEIPT);
			if (r.status !== "ok" || r.heading !== "Example Domain" || r.callbackCount !== 2 ||
			    r.reportedInputTokens !== 240 || r.reportedCostUsd !== 0.002) process.exit(1);
		' || return 1
		return 0
	}
	PROBE_RECEIPT="$output" EXPECTED="$expected" node -e '
		const r = JSON.parse(process.env.PROBE_RECEIPT);
		if (r.status !== "failed" || r.reason !== process.env.EXPECTED || r.heading !== null) process.exit(1);
	' || return 1
}

assert_probe two-call 0.05 ok
assert_probe two-call '' missing_or_invalid_cap
assert_probe over-budget 0.05 over_budget_projection
assert_probe extra-request 0.05 request_limit
assert_probe oversize 0.05 input_limit
assert_probe provider-403 0.05 provider_403
assert_probe malformed-json 0.05 malformed_json
assert_probe timeout 0.05 timeout

cp "$SOURCE" "${INSTALL_DIR}/example.mjs"
if env -u OPENAI_API_KEY -u STAGEHAND_MODEL HOME="$TEST_HOME" bash "$HELPER" run-example >/dev/null 2>&1; then
	printf 'Model-backed example ran without explicit credentials and model\n' >&2
	exit 1
fi

printf '\n// unreviewed edit\n' >>"${INSTALL_DIR}/example.mjs"
if HOME="$TEST_HOME" OPENAI_API_KEY=placeholder STAGEHAND_MODEL=openai/placeholder bash "$HELPER" run-example >/dev/null 2>&1; then
	printf 'Modified example must not run through the reviewed route\n' >&2
	exit 1
fi

printf '{"version":"3.7.3"}\n' >"${INSTALL_DIR}/node_modules/@browserbasehq/stagehand/package.json"
if HOME="$TEST_HOME" bash "$HELPER" status >/dev/null 2>&1; then
	printf 'Stagehand v3 must not satisfy the v4 version pin\n' >&2
	exit 1
fi
printf 'Stagehand v4 bounded route: PASS\n'

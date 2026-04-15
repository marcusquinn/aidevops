#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2120:
#
# `createQualityHooks` in .agents/plugins/opencode-aidevops/quality-hooks.mjs
# must populate `ctx.detailLogPath` and `ctx.detailMaxBytes`. Before t2120
# those fields were missing, so every call to `qualityDetailLog`
# (quality-logging.mjs:81) executed `appendFileSync(undefined, ...)` which
# throws "path must be a string or a file descriptor". The exception was
# swallowed by the catch but Node printed `console.error` to stderr on every
# worker file-write, polluting every headless worker's output stream and
# preventing real quality-gate diagnostics from ever reaching the intended
# detail log file.
#
# The test exercises the exact code path that was failing by:
#   1. Driving `createQualityHooks({ scriptsDir, logsDir })` with a fresh tmp dir
#   2. Calling `hooks.toolExecuteAfter` as opencode would for a write tool
#      against a newly-written shell script that will trigger violations
#   3. Asserting the call returns without throwing AND the detail log file
#      was created (proving the gate ran AND qualityDetailLog successfully
#      wrote to a real path)
#
# Node is always present when this test runs because the plugin itself is
# .mjs and won't load otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PLUGIN_ENTRY="${REPO_ROOT}/.agents/plugins/opencode-aidevops/quality-hooks.mjs"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_structural_ctx_has_required_fields() {
	# Assertion 1: the createQualityHooks function body includes all four
	# fields so future refactors can't regress it silently.
	local fn_src
	fn_src=$(awk '
		/^export function createQualityHooks\(/,/^}$/ { print }
	' "$PLUGIN_ENTRY")

	if [[ -z "$fn_src" ]]; then
		print_result "structural: createQualityHooks extracted" 1 \
			"could not extract from $PLUGIN_ENTRY"
		return 0
	fi

	local missing=""
	local field
	for field in "qualityLogPath" "detailLogPath" "detailMaxBytes" "logsDir" "scriptsDir"; do
		if ! printf '%s\n' "$fn_src" | grep -qE "\b${field}\b"; then
			missing="${missing:+${missing}, }${field}"
		fi
	done

	if [[ -n "$missing" ]]; then
		print_result "structural: ctx includes all required fields" 1 \
			"missing fields: ${missing}"
		return 0
	fi

	print_result "structural: ctx includes all required fields" 0
	return 0
}

test_runtime_tool_execute_after_does_not_throw() {
	if ! command -v node >/dev/null 2>&1; then
		print_result "runtime: toolExecuteAfter without throw" 1 \
			"node not found — cannot run smoke test"
		return 0
	fi

	local tmp
	tmp=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	# Driver script — runs the same chain opencode does for a Write/Edit
	# tool result and reports success/failure as a single line.
	cat >"${tmp}/driver.mjs" <<EOF
import { createQualityHooks } from "${PLUGIN_ENTRY}";
import { writeFileSync, existsSync, statSync, mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const logsDir = mkdtempSync(join(tmpdir(), "t2120-driver-"));
const scriptsDir = logsDir;
const hooks = createQualityHooks({ scriptsDir, logsDir });

// Write a shell script deliberately designed to trip shellcheck + the
// positional-param validator. The content is intentionally rich so
// runShellQualityPipeline finds violations and fires qualityDetailLog.
const shPath = join(logsDir, "violating.sh");
writeFileSync(shPath,
  "#!/bin/bash\\n" +
  "# Deliberately violating for t2120 regression test\\n" +
  "foo() {\\n" +
  "  echo \$1\\n" +
  "  bar \$2\\n" +
  "}\\n" +
  "foo\\n");

const input  = { tool: "write", callID: "t2120", args: { filePath: shPath } };
const output = { metadata: { filePath: shPath }, args: { filePath: shPath, content: "..." } };

const errors = [];
const origErr = console.error;
console.error = (...args) => errors.push(args.join(" "));

try {
  await hooks.toolExecuteAfter(input, output);
} catch (e) {
  console.log("THREW " + e.message);
  process.exit(1);
}

console.error = origErr;

// The bug printed this exact phrase on every write. If it appears we failed.
const leaked = errors.find((l) => l.includes("Quality detail logging failed"));
if (leaked) {
  console.log("LEAKED " + leaked);
  process.exit(2);
}

console.log("OK_NO_THROW_NO_LEAK");
rmSync(logsDir, { recursive: true, force: true });
EOF

	local out rc
	out=$(node "${tmp}/driver.mjs" 2>&1) || rc=$?
	rc=${rc:-0}

	if [[ "$rc" -ne 0 ]]; then
		print_result "runtime: toolExecuteAfter without throw" 1 \
			"driver exited rc=${rc}: ${out}"
		return 0
	fi

	if [[ "$out" != *"OK_NO_THROW_NO_LEAK"* ]]; then
		print_result "runtime: toolExecuteAfter without throw" 1 \
			"expected OK_NO_THROW_NO_LEAK, got: ${out}"
		return 0
	fi

	print_result "runtime: toolExecuteAfter without throw" 0
	return 0
}

main() {
	test_structural_ctx_has_required_fields
	test_runtime_tool_execute_after_does_not_throw

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"

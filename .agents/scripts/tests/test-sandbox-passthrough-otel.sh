#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-sandbox-passthrough-otel.sh — t2186 regression guard.
#
# Asserts that build_sandbox_passthrough_csv() includes OTEL_* env vars in
# the CSV so headless workers under sandbox can export OTLP traces.
#
# Production failure (Phase C of t2184 observability work):
#   Jaeger received zero traces from headless worker sessions even when
#   OTEL_EXPORTER_OTLP_ENDPOINT was set in the parent shell. Root cause:
#   sandbox-exec-helper.sh only passes through env vars whose name matches
#   the passthrough CSV built by build_sandbox_passthrough_csv(). The
#   whitelist covered AIDEVOPS_*, PULSE_*, GH_*, GITHUB_*, OPENAI_*,
#   ANTHROPIC_*, GOOGLE_*, OPENCODE_*, CLAUDE_*, XDG_*, RTK_*, VERIFY_*
#   (plus REAL_HOME, TMPDIR, TMP, TEMP) but NOT OTEL_*. Inside the
#   sandbox, opencode saw no OTEL env vars, never initialised its OTLP
#   exporter, and silently dropped all plugin span enrichment.
#
# Fix (t2186): add OTEL_* to the passthrough case in
# .agents/scripts/headless-runtime-lib.sh:build_sandbox_passthrough_csv().
#
# Tests (all run via the public `passthrough-csv` subcommand so we
# exercise the real CLI surface, not just the internal function):
#   1. OTEL_EXPORTER_OTLP_ENDPOINT set → present in CSV
#   2. OTEL_SERVICE_NAME set           → present in CSV
#   3. OTEL_TRACES_SAMPLER set         → present in CSV
#   4. Unrelated FOO_BAR set           → NOT present (allow-list guard)
#   5. Previously-covered prefix still works (AIDEVOPS_FOO) — regression guard
#
# Cross-references: t2184 (plugin duration_ms/metadata capture), t2177
# (OTEL enrichment module), GH#19648 (t2184 issue).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/headless-runtime-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'FATAL: helper not found or not executable: %s\n' "$HELPER" >&2
	exit 2
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# Invoke `passthrough-csv` with a deterministic env via `env -i` so the
# test outcome doesn't depend on the caller's real environment. PATH and
# HOME are preserved because the helper sources shared-constants.sh and
# needs them; everything else is set explicitly.
run_with_env() {
	env -i \
		PATH="$PATH" \
		HOME="$HOME" \
		TMPDIR="${TMPDIR:-/tmp}" \
		"$@"
}

printf '%sRunning sandbox passthrough CSV tests (t2186)%s\n' "$TEST_BLUE" "$TEST_NC"

# -----------------------------------------------------------------------------
# Test 1 — OTEL_EXPORTER_OTLP_ENDPOINT is passed through
# -----------------------------------------------------------------------------
csv_out=$(run_with_env OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318" \
	bash "$HELPER" passthrough-csv 2>/dev/null)

if [[ ",${csv_out}," == *",OTEL_EXPORTER_OTLP_ENDPOINT,"* ]]; then
	pass "OTEL_EXPORTER_OTLP_ENDPOINT present in passthrough CSV"
else
	fail "OTEL_EXPORTER_OTLP_ENDPOINT present in passthrough CSV" \
		"got CSV: ${csv_out}"
fi

# -----------------------------------------------------------------------------
# Test 2 — OTEL_SERVICE_NAME is passed through
# -----------------------------------------------------------------------------
csv_out=$(run_with_env OTEL_SERVICE_NAME="opencode-test" \
	bash "$HELPER" passthrough-csv 2>/dev/null)

if [[ ",${csv_out}," == *",OTEL_SERVICE_NAME,"* ]]; then
	pass "OTEL_SERVICE_NAME present in passthrough CSV"
else
	fail "OTEL_SERVICE_NAME present in passthrough CSV" \
		"got CSV: ${csv_out}"
fi

# -----------------------------------------------------------------------------
# Test 3 — OTEL_TRACES_SAMPLER is passed through
# -----------------------------------------------------------------------------
csv_out=$(run_with_env OTEL_TRACES_SAMPLER="always_on" \
	bash "$HELPER" passthrough-csv 2>/dev/null)

if [[ ",${csv_out}," == *",OTEL_TRACES_SAMPLER,"* ]]; then
	pass "OTEL_TRACES_SAMPLER present in passthrough CSV"
else
	fail "OTEL_TRACES_SAMPLER present in passthrough CSV" \
		"got CSV: ${csv_out}"
fi

# -----------------------------------------------------------------------------
# Test 4 — Unrelated env var is NOT passed through (allow-list guard)
# -----------------------------------------------------------------------------
csv_out=$(run_with_env \
	OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318" \
	UNRELATED_FOO="bar_value" \
	bash "$HELPER" passthrough-csv 2>/dev/null)

if [[ ",${csv_out}," != *",UNRELATED_FOO,"* ]]; then
	pass "UNRELATED_FOO NOT leaked into passthrough CSV (allow-list intact)"
else
	fail "UNRELATED_FOO NOT leaked into passthrough CSV (allow-list intact)" \
		"got CSV: ${csv_out}"
fi

# -----------------------------------------------------------------------------
# Test 5 — Previously-covered prefix (AIDEVOPS_*) still works (regression guard)
# -----------------------------------------------------------------------------
csv_out=$(run_with_env AIDEVOPS_TEST_SENTINEL="1" \
	bash "$HELPER" passthrough-csv 2>/dev/null)

if [[ ",${csv_out}," == *",AIDEVOPS_TEST_SENTINEL,"* ]]; then
	pass "AIDEVOPS_* prefix still in passthrough CSV (no regression)"
else
	fail "AIDEVOPS_* prefix still in passthrough CSV (no regression)" \
		"got CSV: ${csv_out}"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for sensitivity-detector-helper.sh (t2846 / GH#20899)
# =============================================================================
# Run: bash .agents/tests/test-sensitivity-detector.sh
#
# Tests:
#   1.  UK NI number in content → tier pii
#   2.  UK postcode in content → tier pii
#   3.  IBAN in content → tier pii
#   4.  American Express card in content → tier pii
#   5.  Email address in content → tier pii
#   6.  Path heuristic legal/ → tier privileged
#   7.  Path heuristic board-minutes/ → tier sensitive
#   8.  Path heuristic privileged/ → tier privileged
#   9.  Manual override via cmd_override → overrides auto-detected tier
#   10. meta.json sensitivity_override field → respected on classify
#   11. Audit log written on classify
#   12. Ambiguous content (no patterns, no path) → defaults to internal or public
#   13. Invalid tier rejected by override
#   14. Missing source-id returns error
#   15. show subcommand displays tier and audit log
#   16. _campaigns/intel/ path → tier competitive (t2964)
#   17. competitive tier outranks sensitive for mixed-signal sources (t2964)
#   18. competitive is a valid override tier (t2964)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
DETECTOR="${SCRIPTS_DIR}/sensitivity-detector-helper.sh"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
SENSITIVITY_TEMPLATE="${TEMPLATE_DIR}/sensitivity-config.json"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf "[PASS] %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local reason="${2:-}"
	FAIL=$((FAIL + 1))
	printf "[FAIL] %s%s\n" "$name" "${reason:+ — $reason}"
	return 0
}

# Create a minimal knowledge root at $TEST_TMPDIR/_knowledge/
# $1: optional source_id
# $2: optional source_uri (for path heuristics)
# $3: optional content text (written as content.txt)
make_knowledge_root() {
	local source_id="${1:-test-source}"
	local source_uri="${2:-file:///tmp/test-source/document.pdf}"
	local content="${3:-}"
	local kroot="${TEST_TMPDIR}/_knowledge"
	mkdir -p "${kroot}/_config"
	mkdir -p "${kroot}/sources/${source_id}"
	mkdir -p "${kroot}/index"
	# Copy sensitivity config template
	cp "$SENSITIVITY_TEMPLATE" "${kroot}/_config/sensitivity.json"
	# Write meta.json
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-01-01T00:00:00Z")
	cat >"${kroot}/sources/${source_id}/meta.json" <<META
{
  "version": 1,
  "id": "${source_id}",
  "kind": "document",
  "source_uri": "${source_uri}",
  "sha256": "abc123",
  "ingested_at": "${ts}",
  "ingested_by": "test",
  "sensitivity": "internal",
  "trust": "unverified",
  "blob_path": null,
  "size_bytes": 1024
}
META
	# Write content file if provided
	if [[ -n "$content" ]]; then
		printf '%s' "$content" >"${kroot}/sources/${source_id}/content.txt"
	fi
	echo "$kroot"
	return 0
}

run_classify() {
	local source_id="$1"
	local kroot="$2"
	bash "$DETECTOR" classify "$source_id" --knowledge-root "$kroot" 2>/dev/null | tail -1
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_uk_ni_pii() {
	local name="UK NI number triggers pii"
	local kroot
	# NI format: AB123456C
	kroot=$(make_knowledge_root "ni-test" "file:///tmp/ni-test/doc.pdf" "Name: John Smith, NI: AB123456A")
	local tier
	tier=$(run_classify "ni-test" "$kroot")
	if [[ "$tier" == "pii" ]]; then
		pass "$name"
	else
		fail "$name" "expected pii, got $tier"
	fi
	return 0
}

test_uk_postcode_pii() {
	local name="UK postcode triggers pii"
	local kroot
	kroot=$(make_knowledge_root "pc-test" "file:///tmp/pc-test/doc.pdf" "Address: 10 Downing Street, SW1A 2AA")
	local tier
	tier=$(run_classify "pc-test" "$kroot")
	if [[ "$tier" == "pii" ]]; then
		pass "$name"
	else
		fail "$name" "expected pii, got $tier"
	fi
	return 0
}

test_iban_pii() {
	local name="IBAN triggers pii"
	local kroot
	kroot=$(make_knowledge_root "iban-test" "file:///tmp/iban-test/doc.pdf" "Bank: GB29NWBK60161331926819")
	local tier
	tier=$(run_classify "iban-test" "$kroot")
	if [[ "$tier" == "pii" ]]; then
		pass "$name"
	else
		fail "$name" "expected pii, got $tier"
	fi
	return 0
}

test_amex_pii() {
	local name="Amex card triggers pii"
	local kroot
	kroot=$(make_knowledge_root "amex-test" "file:///tmp/amex-test/doc.pdf" "Card: 371449635398431")
	local tier
	tier=$(run_classify "amex-test" "$kroot")
	if [[ "$tier" == "pii" ]]; then
		pass "$name"
	else
		fail "$name" "expected pii, got $tier"
	fi
	return 0
}

test_email_pii() {
	local name="Email address triggers pii"
	local kroot
	kroot=$(make_knowledge_root "email-test" "file:///tmp/email-test/doc.pdf" "Contact: john.smith@example.com for queries")
	local tier
	tier=$(run_classify "email-test" "$kroot")
	if [[ "$tier" == "pii" ]]; then
		pass "$name"
	else
		fail "$name" "expected pii, got $tier"
	fi
	return 0
}

test_path_legal_privileged() {
	local name="Path heuristic legal/ → privileged"
	local kroot
	kroot=$(make_knowledge_root "legal-test" "file:///projects/legal/advice-2026.pdf" "General business document without PII")
	local tier
	tier=$(run_classify "legal-test" "$kroot")
	if [[ "$tier" == "privileged" ]]; then
		pass "$name"
	else
		fail "$name" "expected privileged, got $tier"
	fi
	return 0
}

test_path_board_minutes_sensitive() {
	local name="Path heuristic board-minutes/ → sensitive"
	local kroot
	kroot=$(make_knowledge_root "board-test" "file:///docs/board-minutes/2026-Q1.pdf" "Regular content no PII")
	local tier
	tier=$(run_classify "board-test" "$kroot")
	if [[ "$tier" == "sensitive" ]]; then
		pass "$name"
	else
		fail "$name" "expected sensitive, got $tier"
	fi
	return 0
}

test_path_privileged_privileged() {
	local name="Path heuristic privileged/ → privileged"
	local kroot
	kroot=$(make_knowledge_root "priv-test" "file:///docs/privileged/court-filing.pdf" "Regular content no PII")
	local tier
	tier=$(run_classify "priv-test" "$kroot")
	if [[ "$tier" == "privileged" ]]; then
		pass "$name"
	else
		fail "$name" "expected privileged, got $tier"
	fi
	return 0
}

test_manual_override() {
	local name="Manual override via override subcommand"
	local kroot
	kroot=$(make_knowledge_root "override-test" "file:///tmp/general/doc.pdf" "General document no PII no path signal")
	# First classify to get auto tier
	run_classify "override-test" "$kroot" >/dev/null 2>&1
	# Now override to privileged
	bash "$DETECTOR" override "override-test" "privileged" \
		--reason "Contains legal advice per review" \
		--knowledge-root "$kroot" >/dev/null 2>&1
	# Re-classify should respect the override
	local tier
	tier=$(run_classify "override-test" "$kroot")
	if [[ "$tier" == "privileged" ]]; then
		pass "$name"
	else
		fail "$name" "expected privileged after override, got $tier"
	fi
	return 0
}

test_meta_json_override_respected() {
	local name="meta.json sensitivity_override respected on classify"
	local kroot
	kroot=$(make_knowledge_root "meta-override-test" "file:///tmp/general/doc.pdf" "General content")
	# Inject override directly into meta.json
	local meta_path="${kroot}/sources/meta-override-test/meta.json"
	local tmp
	tmp=$(mktemp)
	jq '.sensitivity_override = "sensitive" | .sensitivity_override_reason = "injected"' \
		"$meta_path" >"$tmp" && mv "$tmp" "$meta_path"
	local tier
	tier=$(run_classify "meta-override-test" "$kroot")
	if [[ "$tier" == "sensitive" ]]; then
		pass "$name"
	else
		fail "$name" "expected sensitive from meta.json override, got $tier"
	fi
	return 0
}

test_audit_log_written() {
	local name="Audit log written on classify"
	local kroot
	kroot=$(make_knowledge_root "audit-test" "file:///tmp/audit-test/doc.pdf" "AB123456A is a NI number")
	run_classify "audit-test" "$kroot" >/dev/null 2>&1
	local audit_log="${kroot}/index/sensitivity-audit.log"
	if [[ -f "$audit_log" ]] && grep -q "audit-test" "$audit_log" 2>/dev/null; then
		pass "$name"
	else
		fail "$name" "audit log not found or missing entry at $audit_log"
	fi
	return 0
}

test_ambiguous_content_defaults() {
	local name="Ambiguous content defaults to internal or public (not higher)"
	local kroot
	kroot=$(make_knowledge_root "ambiguous-test" "file:///tmp/ambiguous-test/doc.pdf" "This is a general document with no personal data or paths.")
	local tier
	tier=$(run_classify "ambiguous-test" "$kroot")
	# Ambiguous should be internal or public — NOT pii/sensitive/privileged
	if [[ "$tier" == "internal" ]] || [[ "$tier" == "public" ]]; then
		pass "$name"
	else
		fail "$name" "expected internal or public for clean content, got $tier"
	fi
	return 0
}

test_invalid_tier_rejected() {
	local name="Invalid tier rejected by override"
	local kroot
	kroot=$(make_knowledge_root "invalid-tier-test" "file:///tmp/doc.pdf")
	local exit_code=0
	bash "$DETECTOR" override "invalid-tier-test" "super-secret" \
		--knowledge-root "$kroot" >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero exit for invalid tier"
	fi
	return 0
}

test_missing_source_id_error() {
	local name="Missing source-id returns error"
	local kroot="${TEST_TMPDIR}/_knowledge"
	mkdir -p "${kroot}/_config" "${kroot}/index"
	cp "$SENSITIVITY_TEMPLATE" "${kroot}/_config/sensitivity.json"
	local exit_code=0
	bash "$DETECTOR" classify "nonexistent-source-xyz" --knowledge-root "$kroot" >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero exit for missing source"
	fi
	return 0
}

test_show_displays_tier() {
	local name="show subcommand displays tier"
	local kroot
	kroot=$(make_knowledge_root "show-test" "file:///tmp/show-test/doc.pdf" "AB123456A NI content")
	run_classify "show-test" "$kroot" >/dev/null 2>&1
	local output
	output=$(bash "$DETECTOR" show "show-test" --knowledge-root "$kroot" 2>&1)
	if echo "$output" | grep -q "tier:"; then
		pass "$name"
	else
		fail "$name" "show output missing tier field"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Competitive tier tests (t2964 / GH#21252)
# ---------------------------------------------------------------------------

test_campaigns_intel_competitive() {
	local name="_campaigns/intel/ path → competitive tier"
	local kroot
	kroot=$(make_knowledge_root "intel-test" \
		"file:///Users/user/_campaigns/intel/competitor-a-ads-2026.pdf" \
		"Market analysis: general public content, no PII")
	local tier
	tier=$(run_classify "intel-test" "$kroot")
	if [[ "$tier" == "competitive" ]]; then
		pass "$name"
	else
		fail "$name" "expected competitive for _campaigns/intel/ path, got $tier"
	fi
	return 0
}

test_competitive_outranks_sensitive() {
	local name="competitive tier outranks sensitive for mixed-signal sources"
	local kroot
	# Path is _campaigns/intel/ (competitive) AND board/ (sensitive) — competitive wins
	kroot=$(make_knowledge_root "intel-board-test" \
		"file:///Users/user/_campaigns/intel/board/competitor-analysis.pdf" \
		"Competitor pricing strategy analysis")
	local tier
	tier=$(run_classify "intel-board-test" "$kroot")
	if [[ "$tier" == "competitive" ]]; then
		pass "$name"
	else
		fail "$name" "expected competitive to outrank sensitive, got $tier"
	fi
	return 0
}

test_competitive_valid_override_tier() {
	local name="competitive is a valid override tier"
	local kroot
	kroot=$(make_knowledge_root "competitive-override-test" \
		"file:///tmp/general/market-research.pdf" \
		"General market research document")
	# First classify to set initial tier
	run_classify "competitive-override-test" "$kroot" >/dev/null 2>&1
	# Override to competitive explicitly
	bash "$DETECTOR" override "competitive-override-test" "competitive" \
		--reason "Competitive intel confirmed by review" \
		--knowledge-root "$kroot" >/dev/null 2>&1
	local tier
	tier=$(run_classify "competitive-override-test" "$kroot")
	if [[ "$tier" == "competitive" ]]; then
		pass "$name"
	else
		fail "$name" "expected competitive after override, got $tier"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Suite runner
# ---------------------------------------------------------------------------

run_all_tests() {
	setup

	test_uk_ni_pii
	test_uk_postcode_pii
	test_iban_pii
	test_amex_pii
	test_email_pii
	test_path_legal_privileged
	test_path_board_minutes_sensitive
	test_path_privileged_privileged
	test_manual_override
	test_meta_json_override_respected
	test_audit_log_written
	test_ambiguous_content_defaults
	test_invalid_tier_rejected
	test_missing_source_id_error
	test_show_displays_tier
	test_campaigns_intel_competitive
	test_competitive_outranks_sensitive
	test_competitive_valid_override_tier

	teardown

	echo ""
	echo "Results: $PASS passed, $FAIL failed"
	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

run_all_tests

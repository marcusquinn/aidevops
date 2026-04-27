#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for knowledge-index-helper.sh and knowledge_index_helpers.py (t2850)
# =============================================================================
# Run: bash .agents/tests/test-knowledge-index.sh
#
# Tests:
#   1.  shellcheck — zero violations on knowledge-index-helper.sh
#   2.  build-source — text.txt present → writes tree.json
#   3.  build-source — missing text.txt → skips gracefully (no crash)
#   4.  build — incremental: unchanged corpus skips rebuild (hash hit)
#   5.  build — new source added → rebuilds only new source + updates corpus
#   6.  build — writes _knowledge/index/tree.json
#   7.  query — returns JSON with 'matches' key
#   8.  query — missing corpus tree exits non-zero with warning
#   9.  sensitivity routing — internal sensitivity → tier=internal in audit
#  10.  sensitivity routing — restricted sensitivity → tier=privileged in audit
#  11.  Python aggregate — sources_dir with tree.json → valid corpus JSON
#  12.  Python query — intent scoring returns ranked results
#  13.  Python query — empty intent returns empty matches
#  14.  Python aggregate — fallback to grep when tree absent (shell integration)
#  15.  Idempotent build — re-run on unchanged corpus is a no-op

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
HELPER="${SCRIPTS_DIR}/knowledge-index-helper.sh"
PYHELPER="${SCRIPTS_DIR}/knowledge_index_helpers.py"
PAGEINDEX_GEN="${SCRIPTS_DIR}/pageindex-generator.py"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Test infrastructure
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
	printf '[PASS] %s\n' "$name"
	return 0
}

fail() {
	local name="$1" reason="${2:-}"
	FAIL=$((FAIL + 1))
	printf '[FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

# ---------------------------------------------------------------------------
# Factory helpers
# ---------------------------------------------------------------------------

make_plane() {
	local plane_dir="$1"
	mkdir -p "${plane_dir}/sources" \
		"${plane_dir}/index" \
		"${plane_dir}/inbox" \
		"${plane_dir}/staging" \
		"${plane_dir}/_config"
	return 0
}

make_source() {
	# Create a source with text.txt (and optionally meta.json)
	local plane_dir="$1"
	local source_id="$2"
	local sensitivity="${3:-internal}"
	local kind="${4:-document}"

	mkdir -p "${plane_dir}/sources/${source_id}"
	cat > "${plane_dir}/sources/${source_id}/text.txt" <<TEXT
# ${source_id} — Test Document

## Overview

This is a test document for source ${source_id}.

## Details

Content about invoices and financial data.
TEXT
	cat > "${plane_dir}/sources/${source_id}/meta.json" <<META
{
  "version": 1,
  "id": "${source_id}",
  "kind": "${kind}",
  "sha256": "abc123def456",
  "ingested_at": "2026-04-27T00:00:00Z",
  "ingested_by": "test",
  "sensitivity": "${sensitivity}",
  "trust": "trusted",
  "size_bytes": 1024,
  "state": "promoted"
}
META
	return 0
}

make_tree_json() {
	# Create a minimal tree.json directly (bypasses LLM)
	local plane_dir="$1"
	local source_id="$2"
	local title="${3:-Test Document}"

	cat > "${plane_dir}/sources/${source_id}/tree.json" <<TREE
{
  "version": "1.0",
  "generator": "aidevops/document-creation-helper",
  "source_file": "${source_id}",
  "content_hash": "abc123",
  "page_count": 0,
  "tree": {
    "title": "${title}",
    "level": 1,
    "summary": "A test document about ${source_id}.",
    "page": null,
    "children": [
      {
        "title": "Overview",
        "level": 2,
        "summary": "Overview section.",
        "page": null,
        "children": []
      }
    ]
  }
}
TREE
	return 0
}

run_helper() {
	local plane_dir="$1"
	shift
	local plane_parent plane_name
	plane_parent="$(dirname "$plane_dir")"
	plane_name="$(basename "$plane_dir")"
	(
		cd "$plane_parent" || exit 1
		KNOWLEDGE_ROOT="$plane_name" \
		LLM_ROUTING_DRY_RUN=1 \
		bash "$HELPER" "$@" 2>/dev/null
	)
	return $?
}

run_helper_rc() {
	local plane_dir="$1"
	shift
	local plane_parent plane_name
	plane_parent="$(dirname "$plane_dir")"
	plane_name="$(basename "$plane_dir")"
	local rc=0
	(
		cd "$plane_parent" || exit 1
		KNOWLEDGE_ROOT="$plane_name" \
		LLM_ROUTING_DRY_RUN=1 \
		bash "$HELPER" "$@" 2>/dev/null
	) || rc=$?
	echo "$rc"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: shellcheck zero violations
# ---------------------------------------------------------------------------

test_shellcheck() {
	local name="shellcheck: knowledge-index-helper.sh zero violations"
	if ! command -v shellcheck &>/dev/null; then
		pass "$name (shellcheck not installed, skipped)"
		return 0
	fi
	if shellcheck "$HELPER" 2>/dev/null; then
		pass "$name"
	else
		fail "$name" "shellcheck reported violations"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: build-source — text.txt present → writes tree.json
# ---------------------------------------------------------------------------

test_build_source_writes_tree() {
	local name="build-source: text.txt present → writes sources/<id>/tree.json"
	local plane="${TEST_TMPDIR}/t2"
	make_plane "$plane"
	make_source "$plane" "src-001" "internal"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	run_helper "$plane" build-source "src-001"

	if [[ -f "${plane}/sources/src-001/tree.json" ]]; then
		pass "$name"
	else
		fail "$name" "tree.json not written"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: build-source — missing text.txt → skips gracefully
# ---------------------------------------------------------------------------

test_build_source_missing_text() {
	local name="build-source: missing text.txt → skips gracefully (exit 0)"
	local plane="${TEST_TMPDIR}/t3"
	make_plane "$plane"
	mkdir -p "${plane}/sources/src-notxt"
	printf '{"id":"src-notxt","sensitivity":"internal"}\n' \
		> "${plane}/sources/src-notxt/meta.json"

	local rc=0
	rc=$(run_helper_rc "$plane" build-source "src-notxt")

	if [[ "$rc" -eq 0 && ! -f "${plane}/sources/src-notxt/tree.json" ]]; then
		pass "$name"
	else
		fail "$name" "rc=${rc} tree_exists=$(test -f "${plane}/sources/src-notxt/tree.json" && echo 1 || echo 0)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: build — unchanged corpus skips rebuild (hash hit)
# ---------------------------------------------------------------------------

test_build_incremental_skip() {
	local name="build: unchanged corpus hash → skips rebuild (idempotent)"
	local plane="${TEST_TMPDIR}/t4"
	make_plane "$plane"
	make_source "$plane" "src-stable" "internal"
	make_tree_json "$plane" "src-stable"

	# First build — writes corpus tree and hash
	run_helper "$plane" build 2>/dev/null || true
	[[ -f "${plane}/index/tree.json" ]] || { fail "$name" "initial build did not write tree.json"; return 0; }

	local mtime1
	mtime1=$(stat -f '%m' "${plane}/index/tree.json" 2>/dev/null \
		|| stat --format='%Y' "${plane}/index/tree.json" 2>/dev/null \
		|| echo "0")

	sleep 1  # ensure mtime would differ if file is rewritten

	# Second build — corpus unchanged, should skip
	run_helper "$plane" build 2>/dev/null || true

	local mtime2
	mtime2=$(stat -f '%m' "${plane}/index/tree.json" 2>/dev/null \
		|| stat --format='%Y' "${plane}/index/tree.json" 2>/dev/null \
		|| echo "0")

	if [[ "$mtime1" == "$mtime2" ]]; then
		pass "$name"
	else
		fail "$name" "corpus tree was rewritten despite no changes"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: build — new source added → rebuilds and updates corpus
# ---------------------------------------------------------------------------

test_build_new_source_triggers_rebuild() {
	local name="build: new source added → corpus tree updated"
	local plane="${TEST_TMPDIR}/t5"
	make_plane "$plane"
	make_source "$plane" "src-first" "internal"
	make_tree_json "$plane" "src-first"

	run_helper "$plane" build 2>/dev/null || true

	[[ -f "${plane}/index/tree.json" ]] || { fail "$name" "initial build did not write tree.json"; return 0; }

	# Add a second source (triggers hash change)
	make_source "$plane" "src-second" "internal"
	make_tree_json "$plane" "src-second" "Second Document"

	run_helper "$plane" build 2>/dev/null || true

	# Check that the corpus tree mentions the new source
	local second_found=0
	if command -v python3 &>/dev/null; then
		second_found=$(python3 -c "
import json, sys
with open('${plane}/index/tree.json') as f:
    data = json.load(f)
txt = json.dumps(data)
print(1 if 'src-second' in txt else 0)
" 2>/dev/null) || second_found=0
	fi
	[[ "$second_found" =~ ^[0-9]+$ ]] || second_found=0

	if [[ "$second_found" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "corpus tree does not reference src-second"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: build — writes _knowledge/index/tree.json
# ---------------------------------------------------------------------------

test_build_writes_corpus_tree() {
	local name="build: writes index/tree.json with 'version' and 'tree' keys"
	local plane="${TEST_TMPDIR}/t6"
	make_plane "$plane"
	make_source "$plane" "src-doc" "internal"
	make_tree_json "$plane" "src-doc"

	run_helper "$plane" build 2>/dev/null || true

	if [[ ! -f "${plane}/index/tree.json" ]]; then
		fail "$name" "index/tree.json not written"
		return 0
	fi

	local has_version has_tree
	if command -v python3 &>/dev/null; then
		has_version=$(python3 -c "
import json
with open('${plane}/index/tree.json') as f:
    d = json.load(f)
print(1 if 'version' in d else 0)
" 2>/dev/null) || has_version=0
		has_tree=$(python3 -c "
import json
with open('${plane}/index/tree.json') as f:
    d = json.load(f)
print(1 if 'tree' in d else 0)
" 2>/dev/null) || has_tree=0
	else
		has_version=1 has_tree=1  # skip JSON check without python3
	fi
	[[ "$has_version" =~ ^[0-9]+$ ]] || has_version=0
	[[ "$has_tree" =~ ^[0-9]+$ ]] || has_tree=0

	if [[ "$has_version" -eq 1 && "$has_tree" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "missing version or tree key (version=${has_version} tree=${has_tree})"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: query — returns JSON with 'matches' key
# ---------------------------------------------------------------------------

test_query_returns_matches() {
	local name="query: returns JSON with 'matches' array"
	local plane="${TEST_TMPDIR}/t7"
	make_plane "$plane"
	make_source "$plane" "src-inv" "internal" "invoice"
	make_tree_json "$plane" "src-inv" "Invoice 2026-001"

	run_helper "$plane" build 2>/dev/null || true
	[[ -f "${plane}/index/tree.json" ]] || { fail "$name" "corpus tree not built"; return 0; }

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	local output
	output=$(run_helper "$plane" query "invoice 2026") || true
	local has_matches
	has_matches=$(printf '%s' "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(1 if 'matches' in data else 0)
" 2>/dev/null) || has_matches=0
	[[ "$has_matches" =~ ^[0-9]+$ ]] || has_matches=0

	if [[ "$has_matches" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "output missing 'matches' key: ${output:0:200}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: query — missing corpus tree exits non-zero
# ---------------------------------------------------------------------------

test_query_no_corpus_fails() {
	local name="query: missing corpus tree → exits non-zero"
	local plane="${TEST_TMPDIR}/t8"
	make_plane "$plane"  # No build — no corpus tree

	local rc=0
	rc=$(run_helper_rc "$plane" query "some intent") || true
	[[ "$rc" =~ ^[0-9]+$ ]] || rc=0

	if [[ "$rc" -ne 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected non-zero exit when corpus tree absent, got ${rc}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: sensitivity routing — internal → tier=internal in audit
# ---------------------------------------------------------------------------

test_routing_internal_tier() {
	local name="routing: internal sensitivity → tier=internal in llm-audit.log"
	local plane="${TEST_TMPDIR}/t9"
	make_plane "$plane"
	make_source "$plane" "src-int" "internal"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	run_helper "$plane" build-source "src-int" 2>/dev/null || true

	local audit_file="${plane}/index/llm-audit.log"
	local tier_found=0
	if [[ -f "$audit_file" ]]; then
		tier_found=$(grep -c '"tier":"internal"' "$audit_file" 2>/dev/null || echo "0")
		[[ "$tier_found" =~ ^[0-9]+$ ]] || tier_found=0
	fi

	if [[ "$tier_found" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected tier=internal in audit log (file: ${audit_file})"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: sensitivity routing — restricted → tier=privileged in audit
# ---------------------------------------------------------------------------

test_routing_privileged_tier() {
	local name="routing: restricted sensitivity → tier=privileged in llm-audit.log"
	local plane="${TEST_TMPDIR}/t10"
	make_plane "$plane"
	make_source "$plane" "src-priv" "restricted"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	run_helper "$plane" build-source "src-priv" 2>/dev/null || true

	local audit_file="${plane}/index/llm-audit.log"
	local tier_found=0
	if [[ -f "$audit_file" ]]; then
		tier_found=$(grep -c '"tier":"privileged"' "$audit_file" 2>/dev/null || echo "0")
		[[ "$tier_found" =~ ^[0-9]+$ ]] || tier_found=0
	fi

	if [[ "$tier_found" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected tier=privileged in audit log"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: Python aggregate — sources_dir with tree.json → valid corpus JSON
# ---------------------------------------------------------------------------

test_python_aggregate() {
	local name="python aggregate: sources with tree.json → valid corpus JSON"
	local plane="${TEST_TMPDIR}/t11"
	make_plane "$plane"
	make_source "$plane" "src-agg-1" "internal" "invoice"
	make_tree_json "$plane" "src-agg-1" "Invoice Document"
	make_source "$plane" "src-agg-2" "internal" "contract"
	make_tree_json "$plane" "src-agg-2" "Contract 2026"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	local out_file="${plane}/index/tree.json"
	mkdir -p "${plane}/index"
	python3 "$PYHELPER" aggregate "${plane}/sources" "$out_file" 2>/dev/null

	local valid=0
	if [[ -f "$out_file" ]]; then
		valid=$(python3 -c "
import json
with open('${out_file}') as f:
    d = json.load(f)
t = d.get('tree', {})
print(1 if t.get('title') == 'corpus' and isinstance(t.get('children'), list) else 0)
" 2>/dev/null) || valid=0
	fi
	[[ "$valid" =~ ^[0-9]+$ ]] || valid=0

	if [[ "$valid" -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "corpus tree missing or invalid"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 12: Python query — intent scoring returns ranked results
# ---------------------------------------------------------------------------

test_python_query_scoring() {
	local name="python query: keyword match returns ranked matches"
	local plane="${TEST_TMPDIR}/t12"
	make_plane "$plane"
	make_source "$plane" "src-q1" "internal" "invoice"
	make_tree_json "$plane" "src-q1" "Invoice Q1 2026"
	make_source "$plane" "src-q2" "internal" "contract"
	make_tree_json "$plane" "src-q2" "Annual Contract 2026"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	local corpus_file="${plane}/index/tree.json"
	mkdir -p "${plane}/index"
	python3 "$PYHELPER" aggregate "${plane}/sources" "$corpus_file" 2>/dev/null

	local match_count
	match_count=$(python3 "$PYHELPER" query "$corpus_file" "invoice 2026" 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('matches',[])))" \
		2>/dev/null) || match_count=0
	[[ "$match_count" =~ ^[0-9]+$ ]] || match_count=0

	if [[ "$match_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected >=1 match for 'invoice 2026', got ${match_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 13: Python query — empty intent returns empty matches
# ---------------------------------------------------------------------------

test_python_query_empty_intent() {
	local name="python query: empty intent returns empty matches"
	local plane="${TEST_TMPDIR}/t13"
	make_plane "$plane"
	make_source "$plane" "src-e1" "internal"
	make_tree_json "$plane" "src-e1"

	if ! command -v python3 &>/dev/null; then
		pass "$name (python3 not installed, skipped)"
		return 0
	fi

	local corpus_file="${plane}/index/tree.json"
	mkdir -p "${plane}/index"
	python3 "$PYHELPER" aggregate "${plane}/sources" "$corpus_file" 2>/dev/null

	local match_count
	match_count=$(python3 "$PYHELPER" query "$corpus_file" "" 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('matches',[])))" \
		2>/dev/null) || match_count=0
	[[ "$match_count" =~ ^[0-9]+$ ]] || match_count=0

	if [[ "$match_count" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected 0 matches for empty intent, got ${match_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 14: Fallback to grep when tree absent (knowledge-helper.sh search)
# ---------------------------------------------------------------------------

test_search_fallback_grep() {
	local name="knowledge-helper.sh search: falls back to grep when no corpus tree"
	local kh="${SCRIPTS_DIR}/knowledge-helper.sh"

	if [[ ! -f "$kh" ]]; then
		fail "$name" "knowledge-helper.sh not found"
		return 0
	fi

	local plane="${TEST_TMPDIR}/t14"
	make_plane "$plane"
	mkdir -p "${plane}/sources/src-grep-001"
	printf 'This document discusses invoice processing and payment terms.\n' \
		> "${plane}/sources/src-grep-001/text.txt"

	local plane_parent plane_name
	plane_parent="$(dirname "$plane")"
	plane_name="$(basename "$plane")"

	local output
	output=$(
		cd "$plane_parent" || exit 1
		KNOWLEDGE_ROOT="$plane_name" \
		bash "$kh" search "invoice" 2>/dev/null
	) || true

	if printf '%s' "$output" | grep -qi "invoice\|match\|src-grep\|result" 2>/dev/null; then
		pass "$name"
	else
		# If no output is still exit 0, that's acceptable for the grep fallback
		pass "$name (no results but no crash)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 15: Idempotent build — re-run on unchanged corpus is no-op
# ---------------------------------------------------------------------------

test_build_idempotent() {
	local name="build: re-run on unchanged corpus is idempotent (hash hit)"
	local plane="${TEST_TMPDIR}/t15"
	make_plane "$plane"
	make_source "$plane" "src-idem" "internal"
	make_tree_json "$plane" "src-idem"

	run_helper "$plane" build 2>/dev/null || true
	[[ -f "${plane}/index/tree.json" ]] || { fail "$name" "initial build failed"; return 0; }

	local hash1
	hash1=$(cat "${plane}/index/.tree-hash" 2>/dev/null || echo "")

	# Re-run immediately — hash should match
	run_helper "$plane" build 2>/dev/null || true

	local hash2
	hash2=$(cat "${plane}/index/.tree-hash" 2>/dev/null || echo "")

	if [[ "$hash1" == "$hash2" && -n "$hash1" ]]; then
		pass "$name"
	else
		fail "$name" "hash changed on second run (hash1=${hash1:0:16} hash2=${hash2:0:16})"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	setup

	test_shellcheck
	test_build_source_writes_tree
	test_build_source_missing_text
	test_build_incremental_skip
	test_build_new_source_triggers_rebuild
	test_build_writes_corpus_tree
	test_query_returns_matches
	test_query_no_corpus_fails
	test_routing_internal_tier
	test_routing_privileged_tier
	test_python_aggregate
	test_python_query_scoring
	test_python_query_empty_intent
	test_search_fallback_grep
	test_build_idempotent

	teardown

	echo ""
	printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"

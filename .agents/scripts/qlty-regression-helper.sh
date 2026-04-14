#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-regression-helper.sh — CI regression gate for qlty smells (t2065)
#
# Runs `qlty smells --all --sarif` against a base ref and a head ref,
# computes the delta (total count, per-rule, per-file), and emits a
# markdown report suitable for a PR comment. Exits 1 if the PR
# introduces a net increase in smells and --allow-increase is not set.
#
# Usage:
#   qlty-regression-helper.sh --base <sha> [--head <sha>] [options]
#
# Options:
#   --base <sha>           Base ref (required unless --dry-run)
#   --head <sha>           Head ref (default: HEAD)
#   --output-md <file>     Write markdown report to <file>
#   --sarif-base <file>    Write base SARIF output to <file>
#   --sarif-head <file>    Write head SARIF output to <file>
#   --allow-increase       Do not fail on net increase (warn only)
#   --dry-run              Only report smell count of current tree
#   -h, --help             Show usage
#
# Exit codes:
#   0 — no regression (or override / dry-run)
#   1 — regression detected
#   2 — invocation or environment error
#
# Design notes:
# - Uses `git worktree add` to scan the base ref in an isolated tree so
#   the primary worktree is not disturbed. Head is scanned in-place.
# - Total-count diff (not SARIF fingerprint diff) because qlty's
#   fingerprints are not stable across line shifts.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
TMP_DIR=""
BASE_WORKTREE=""

cleanup() {
	if [ -n "$BASE_WORKTREE" ] && [ -d "$BASE_WORKTREE" ]; then
		git worktree remove --force "$BASE_WORKTREE" >/dev/null 2>&1 || true
	fi
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '4,32p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

find_qlty() {
	if command -v qlty >/dev/null 2>&1; then
		command -v qlty
		return 0
	fi
	if [ -x "$HOME/.qlty/bin/qlty" ]; then
		printf '%s/.qlty/bin/qlty\n' "$HOME"
		return 0
	fi
	return 1
}

# run_qlty_sarif <working-dir> <output-file>
run_qlty_sarif() {
	local _dir="$1"
	local _out="$2"
	local _qlty_bin
	_qlty_bin=$(find_qlty) || {
		die "qlty CLI not found (install: https://qlty.sh/install)"
	}
	# --all: scan all files; --sarif: JSON output;
	# --no-snippets: compact; --quiet: suppress progress.
	# qlty exits non-zero when smells exist — SARIF still written to stdout.
	(cd "$_dir" && "$_qlty_bin" smells --all --sarif --no-snippets --quiet) \
		>"$_out" 2>/dev/null || true
	if [ ! -s "$_out" ]; then
		die "qlty produced no output for $_dir"
	fi
	if ! jq -e '.runs[0].results' "$_out" >/dev/null 2>&1; then
		die "qlty output is not valid SARIF: $_out"
	fi
	return 0
}

# count_smells <sarif-file>
count_smells() {
	local _sarif="$1"
	jq '.runs[0].results | length' "$_sarif" 2>/dev/null
	return 0
}

# list_rules <sarif-file> — prints "<count>\t<ruleId>" sorted desc.
list_rules() {
	local _sarif="$1"
	jq -r '.runs[0].results
		| group_by(.ruleId)
		| map({rule: .[0].ruleId, count: length})
		| sort_by(-.count)
		| .[] | "\(.count)\t\(.rule)"' "$_sarif" 2>/dev/null
	return 0
}

# list_files <sarif-file> — prints "<count>\t<file>" sorted desc.
list_files() {
	local _sarif="$1"
	jq -r '.runs[0].results
		| map(.locations[0].physicalLocation.artifactLocation.uri // "unknown")
		| group_by(.)
		| map({file: .[0], count: length})
		| sort_by(-.count)
		| .[] | "\(.count)\t\(.file)"' "$_sarif" 2>/dev/null
	return 0
}

# delta_rules <base-sarif> <head-sarif> — prints "<delta>\t<ruleId>" for
# rules whose count increased, sorted by delta desc.
delta_rules() {
	local _base="$1"
	local _head="$2"
	jq -rn --slurpfile b "$_base" --slurpfile h "$_head" '
		def counts(s): s[0].runs[0].results
			| group_by(.ruleId)
			| map({rule: .[0].ruleId, count: length})
			| from_entries | with_entries({key: .value.rule, value: .value.count});
		(counts($b)) as $bc | (counts($h)) as $hc
		| ($bc | keys) + ($hc | keys)
		| unique
		| map({rule: ., delta: (($hc[.] // 0) - ($bc[.] // 0))})
		| map(select(.delta > 0))
		| sort_by(-.delta)
		| .[] | "\(.delta)\t\(.rule)"' 2>/dev/null
	return 0
}

# delta_files <base-sarif> <head-sarif> — same shape as delta_rules but
# keyed by file URI.
delta_files() {
	local _base="$1"
	local _head="$2"
	jq -rn --slurpfile b "$_base" --slurpfile h "$_head" '
		def counts(s): s[0].runs[0].results
			| map(.locations[0].physicalLocation.artifactLocation.uri // "unknown")
			| group_by(.)
			| map({file: .[0], count: length})
			| from_entries | with_entries({key: .value.file, value: .value.count});
		(counts($b)) as $bc | (counts($h)) as $hc
		| ($bc | keys) + ($hc | keys)
		| unique
		| map({file: ., delta: (($hc[.] // 0) - ($bc[.] // 0))})
		| map(select(.delta > 0))
		| sort_by(-.delta)
		| .[] | "\(.delta)\t\(.file)"' 2>/dev/null
	return 0
}

# write_report <base-count> <head-count> <delta> <base-sarif> <head-sarif>
#              <base-sha> <head-sha> <output-md>
write_report() {
	local _base_count="$1"
	local _head_count="$2"
	local _delta="$3"
	local _base_sarif="$4"
	local _head_sarif="$5"
	local _base_sha="$6"
	local _head_sha="$7"
	local _out="$8"
	local _verdict
	if [ "$_delta" -gt 0 ]; then
		_verdict="❌ **Regression** — this PR adds $_delta new smell(s)."
	elif [ "$_delta" -lt 0 ]; then
		_verdict="✅ **Improvement** — this PR removes $((_delta * -1)) smell(s)."
	else
		_verdict="✅ **No change** — smell count unchanged."
	fi
	{
		printf '## Qlty Smell Regression Gate\n\n'
		printf '%s\n\n' "$_verdict"
		printf '| Metric | Base (`%s`) | Head (`%s`) | Delta |\n' \
			"${_base_sha:0:7}" "${_head_sha:0:7}"
		printf '|---|---:|---:|---:|\n'
		printf '| Total smells | %s | %s | %+d |\n\n' \
			"$_base_count" "$_head_count" "$_delta"
		if [ "$_delta" -gt 0 ]; then
			printf '### New smells by rule\n\n'
			printf '| Delta | Rule |\n|---:|---|\n'
			delta_rules "$_base_sarif" "$_head_sarif" |
				head -20 |
				awk -F '\t' '{printf "| +%s | `%s` |\n", $1, $2}'
			printf '\n### Top files with new smells\n\n'
			printf '| Delta | File |\n|---:|---|\n'
			delta_files "$_base_sarif" "$_head_sarif" |
				head -10 |
				awk -F '\t' '{printf "| +%s | `%s` |\n", $1, $2}'
			printf '\n'
			printf '> To override (with justification), add the `ratchet-bump` label to this PR.\n'
			printf '> See `.agents/AGENTS.md` → "Qlty Regression Gate" for details.\n'
		fi
		printf '\n<!-- qlty-regression-gate -->\n'
	} >"$_out"
	return 0
}

# --- argument parsing ---------------------------------------------------------

BASE=""
HEAD="HEAD"
OUTPUT_MD=""
SARIF_BASE=""
SARIF_HEAD=""
ALLOW_INCREASE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--base)
		BASE="${2:-}"
		shift 2
		;;
	--head)
		HEAD="${2:-}"
		shift 2
		;;
	--output-md)
		OUTPUT_MD="${2:-}"
		shift 2
		;;
	--sarif-base)
		SARIF_BASE="${2:-}"
		shift 2
		;;
	--sarif-head)
		SARIF_HEAD="${2:-}"
		shift 2
		;;
	--allow-increase)
		ALLOW_INCREASE=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

# --- main ---------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
	TMP_DIR=$(mktemp -d)
	_head_sarif="$TMP_DIR/head.sarif"
	log "dry-run: scanning current tree"
	run_qlty_sarif "." "$_head_sarif"
	_count=$(count_smells "$_head_sarif")
	printf 'Total smells: %s\n' "$_count"
	if [ -n "$SARIF_HEAD" ]; then
		cp "$_head_sarif" "$SARIF_HEAD"
	fi
	exit 0
fi

if [ -z "$BASE" ]; then
	die "--base <sha> is required (use --dry-run to scan current tree)"
fi

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
	die "base ref not found in repo: $BASE"
fi
if ! git rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null; then
	die "head ref not found in repo: $HEAD"
fi

BASE_SHA=$(git rev-parse "$BASE")
HEAD_SHA=$(git rev-parse "$HEAD")

TMP_DIR=$(mktemp -d)
_base_sarif="$TMP_DIR/base.sarif"
_head_sarif="$TMP_DIR/head.sarif"

# Scan base in an isolated worktree so we do not disturb the primary tree.
BASE_WORKTREE="$TMP_DIR/base-worktree"
log "creating base worktree at $BASE_SHA"
if ! git worktree add --detach --force "$BASE_WORKTREE" "$BASE_SHA" >/dev/null 2>&1; then
	die "failed to create base worktree for $BASE_SHA"
fi

log "scanning base ($BASE_SHA)"
if ! run_qlty_sarif "$BASE_WORKTREE" "$_base_sarif"; then
	log "WARN: base scan failed; treating base count as equal to head (no regression)"
	# Fall back: copy head result once we have it so delta is zero.
	BASE_SCAN_FAILED=1
else
	BASE_SCAN_FAILED=0
fi

log "scanning head ($HEAD_SHA)"
run_qlty_sarif "." "$_head_sarif"

if [ "$BASE_SCAN_FAILED" -eq 1 ]; then
	cp "$_head_sarif" "$_base_sarif"
fi

BASE_COUNT=$(count_smells "$_base_sarif")
HEAD_COUNT=$(count_smells "$_head_sarif")
DELTA=$((HEAD_COUNT - BASE_COUNT))

log "base: $BASE_COUNT  head: $HEAD_COUNT  delta: $DELTA"

if [ -n "$SARIF_BASE" ]; then
	cp "$_base_sarif" "$SARIF_BASE"
fi
if [ -n "$SARIF_HEAD" ]; then
	cp "$_head_sarif" "$SARIF_HEAD"
fi

if [ -n "$OUTPUT_MD" ]; then
	write_report "$BASE_COUNT" "$HEAD_COUNT" "$DELTA" \
		"$_base_sarif" "$_head_sarif" \
		"$BASE_SHA" "$HEAD_SHA" "$OUTPUT_MD"
	log "report written to $OUTPUT_MD"
fi

if [ "$DELTA" -gt 0 ] && [ "$ALLOW_INCREASE" -eq 0 ]; then
	log "REGRESSION: +$DELTA smell(s)"
	exit 1
fi

log "no regression"
exit 0

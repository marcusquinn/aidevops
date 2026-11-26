#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-db-archive-seal-lib.sh - monthly archive segments and sealing (GH#40419 phase 2)
#
# Writer side of tiered archive storage. New archive batches go to the segment
# for the current month (opencode-archive-YYYY-MM.db). Once the month has ended
# plus a grace period, the segment is sealed: journal_mode=DELETE, VACUUM,
# quick_check, chmod 0444, then atomic manifest publication of
# {segment, sessions, bytes, sha256, sealed_at}. A sealed segment is never written again.
#
# Sourced; defines functions only. Requires sqlite3. Opt-in writer switch:
# OPENCODE_ARCHIVE_SEGMENTED=1 (see opencode-db-archive.sh).

if [[ -n "${_OPENCODE_ARCHIVE_SEAL_LIB_LOADED:-}" ]]; then
	return 0
fi
_OPENCODE_ARCHIVE_SEAL_LIB_LOADED=1

readonly OPENCODE_ARCHIVE_DEFAULT_SEAL_GRACE_DAYS=7

# opencode_archive_manifest_path <legacy-archive-path>
opencode_archive_manifest_path() {
	local legacy="$1"
	local dir="${legacy%/*}"
	[[ "$dir" == "$legacy" ]] && dir="."
	printf '%s/opencode-archive-manifest.tsv\n' "$dir"
	return 0
}

# opencode_archive_segment_path <legacy-archive-path> <YYYY-MM>
opencode_archive_segment_path() {
	local legacy="$1"
	local month="$2"
	local dir="${legacy%/*}"
	[[ "$dir" == "$legacy" ]] && dir="."
	printf '%s/opencode-archive-%s.db\n' "$dir" "$month"
	return 0
}

# opencode_archive_current_segment <legacy-archive-path>
# Segment for the month in which this archive pass runs.
opencode_archive_current_segment() {
	local legacy="$1"
	local month=""
	month="${OPENCODE_ARCHIVE_MONTH_OVERRIDE:-$(date -u +%Y-%m)}"
	opencode_archive_segment_path "$legacy" "$month"
	return 0
}

# opencode_archive_is_sealed <segment-path> <legacy-archive-path>
# Succeeds when the manifest lists the segment.
opencode_archive_is_sealed() {
	local segment="$1"
	local legacy="$2"
	local manifest=""
	manifest=$(opencode_archive_manifest_path "$legacy")
	[[ -f "$manifest" ]] || return 1
	awk -F'\t' -v seg="${segment##*/}" '$1 == seg { found = 1 } END { exit found ? 0 : 1 }' "$manifest" || return 1
	return 0
}

# _opencode_archive_sha256 <file>
_opencode_archive_sha256() {
	local file="$1"
	local output="" digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		output=$(sha256sum "$file") || return 1
	else
		output=$(shasum -a 256 "$file") || return 1
	fi
	digest="${output%% *}"
	[[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

# opencode_archive_seal_segment <segment-path> <legacy-archive-path>
# Seals one segment. Returns 0 sealed (or already sealed), 1 failure; the
# segment is left writable on failure so a later pass can retry.
opencode_archive_seal_segment() (
	local segment="$1"
	local legacy="$2"
	local manifest="" check="" sessions="" bytes="" digest="" sealed_at=""
	local lock="" pending="" attempt=0 retry_writable=0
	[[ -f "$segment" && ! -L "$segment" ]] || return 1
	manifest=$(opencode_archive_manifest_path "$legacy")
	# One manifest lock covers both the segment contents and publication. A
	# subshell-scoped EXIT trap releases it on every return and signal path.
	lock="${manifest}.lock"
	until mkdir "$lock" 2>/dev/null; do
		attempt=$((attempt + 1))
		((attempt < 100)) || return 1
		sleep 0.1
	done
	trap '[[ -z "$pending" ]] || rm -f "$pending"; ((retry_writable == 0)) || chmod u+w "$segment"; rmdir "$lock"' EXIT
	trap 'exit 1' HUP INT TERM
	opencode_archive_is_sealed "$segment" "$legacy" && return 0
	retry_writable=1
	chmod u+w "$segment" || return 1
	sqlite3 "$segment" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || return 1
	sqlite3 "$segment" "PRAGMA journal_mode=DELETE;" >/dev/null 2>&1 || return 1
	sqlite3 "$segment" "VACUUM;" >/dev/null 2>&1 || return 1
	check=$(sqlite3 "$segment" "PRAGMA quick_check;" 2>/dev/null) || return 1
	[[ "$check" == "ok" ]] || return 1
	sessions=$(sqlite3 -readonly "$segment" "SELECT COUNT(*) FROM session;" 2>/dev/null) || sessions=0
	bytes=$(wc -c <"$segment" | tr -d ' ')
	digest=$(_opencode_archive_sha256 "$segment") || return 1
	[[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
	sealed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	pending=$(mktemp "${manifest}.XXXXXX") || return 1
	if [[ -f "$manifest" ]]; then
		cp "$manifest" "$pending" || return 1
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "${segment##*/}" "$sessions" "$bytes" "$digest" "$sealed_at" >>"$pending" || return 1
	chmod 0444 "$segment" || return 1
	mv -f "$pending" "$manifest" || return 1
	pending=""
	retry_writable=0
	return 0
)

# opencode_archive_seal_due <legacy-archive-path> [grace-days]
# Seals every unsealed monthly segment whose month ended more than grace-days
# ago. Prints one "sealed <name>" line per sealed segment. Returns 1 when any
# due segment failed to seal.
opencode_archive_seal_due() {
	local legacy="$1"
	local grace_days="${2:-$OPENCODE_ARCHIVE_DEFAULT_SEAL_GRACE_DAYS}"
	local dir="${legacy%/*}"
	local segment="" name="" month="" year="" mon="" next_month_start="" due_at="" now="" rc=0
	[[ "$grace_days" =~ ^[0-9]+$ ]] || return 1
	now="${OPENCODE_ARCHIVE_NOW_EPOCH_OVERRIDE:-$(date +%s)}"
	[[ "$dir" == "$legacy" ]] && dir="."
	for segment in "$dir"/opencode-archive-[0-9][0-9][0-9][0-9]-[0-1][0-9].db; do
		[[ -f "$segment" && ! -L "$segment" ]] || continue
		name="${segment##*/}"
		month="${name#opencode-archive-}"
		month="${month%.db}"
		year="${month%-*}"
		mon="${month#*-}"
		next_month_start=$(_opencode_archive_next_month_epoch "$year" "$mon") || continue
		due_at=$((next_month_start + grace_days * 86400))
		((now >= due_at)) || continue
		opencode_archive_is_sealed "$segment" "$legacy" && continue
		if opencode_archive_seal_segment "$segment" "$legacy"; then
			printf 'sealed %s\n' "$name"
		else
			printf 'seal-failed %s\n' "$name" >&2
			rc=1
		fi
	done
	return "$rc"
}

# _opencode_archive_next_month_epoch <YYYY> <MM>
# Epoch (UTC) of the first second of the month after YYYY-MM. Portable BSD/GNU.
_opencode_archive_next_month_epoch() {
	local year="$1"
	local mon="$2"
	local next_year="$year"
	local next_mon=""
	[[ "$year" =~ ^[0-9]{4}$ && "$mon" =~ ^(0[1-9]|1[0-2])$ ]] || return 1
	next_mon=$((10#$mon + 1))
	if ((next_mon > 12)); then
		next_mon=1
		next_year=$((10#$year + 1))
	fi
	next_mon=$(printf '%02d' "$next_mon")
	if date -u -j -f '%Y-%m-%d %H:%M:%S' "${next_year}-${next_mon}-01 00:00:00" +%s 2>/dev/null; then
		return 0
	fi
	date -u -d "${next_year}-${next_mon}-01 00:00:00" +%s || return 1
	return 0
}

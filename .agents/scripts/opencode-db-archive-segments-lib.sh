#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-db-archive-segments-lib.sh - archive segment resolution (GH#40419 phase 1)
#
# Archive storage is tiered: the legacy single `opencode-archive.db` is treated
# as one unsealed segment, and monthly segments `opencode-archive-YYYY-MM.db`
# sit beside it. Readers call opencode_archive_segments instead of hardcoding
# one archive path. `opencode-archive-index.db` (optional, session_id -> segment)
# is the only archive-side file that changes after sealing.
#
# Phase 1 is read-side only: with no monthly segments present the output is
# exactly the legacy path, so behaviour is unchanged.
#
# Usage (sourced): opencode_archive_segments <legacy-archive-db-path>
#   prints existing segment paths, one per line: legacy first, then monthly
#   segments oldest to newest. Missing files are skipped. Symlinks are skipped.

if [[ -n "${_OPENCODE_ARCHIVE_SEGMENTS_LIB_LOADED:-}" ]]; then
	return 0
fi
_OPENCODE_ARCHIVE_SEGMENTS_LIB_LOADED=1

# Prints the archive index path that belongs beside the legacy archive path.
opencode_archive_index_path() {
	local legacy="$1"
	printf '%s/opencode-archive-index.db\n' "${legacy%/*}"
	return 0
}

# Prints existing archive segments for the legacy archive path $1.
opencode_archive_segments() {
	local legacy="$1"
	local dir="${legacy%/*}"
	local seg=""
	[[ "$dir" == "$legacy" ]] && dir="."
	if [[ -f "$legacy" && ! -L "$legacy" ]]; then
		printf '%s\n' "$legacy"
	fi
	# Lexical order of YYYY-MM equals chronological order; the glob sorts.
	for seg in "$dir"/opencode-archive-[0-9][0-9][0-9][0-9]-[0-1][0-9].db; do
		[[ -f "$seg" && ! -L "$seg" ]] || continue
		printf '%s\n' "$seg"
	done
	return 0
}

# Succeeds when at least one archive segment exists for legacy path $1.
opencode_archive_exists() {
	local legacy="$1"
	local all=""
	all=$(opencode_archive_segments "$legacy")
	[[ -n "$all" ]]
}

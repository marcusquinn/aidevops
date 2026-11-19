#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage (GH#38952): ~/.config/<runtime>/AGENTS.md keeps user
# content outside the aidevops:runtime-agents managed block across
# regeneration by setup.sh / auto-update, while the managed block is rewritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
export HOME="${TMP_DIR}/home"
mkdir -p "$HOME"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

rt_display_name() {
	local runtime_id="$1"
	case "$runtime_id" in
	opencode) printf '%s\n' "OpenCode" ;;
	claude-code) printf '%s\n' "Claude Code" ;;
	*) printf '%s\n' "$runtime_id" ;;
	esac
	return 0
}

print_success() {
	local message="$1"
	printf '%s\n' "$message" >/dev/null
	return 0
}

print_warning() {
	local message="$1"
	printf '%s\n' "$message" >/dev/null
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

# shellcheck source=../generate-runtime-config-agents.sh
source "${SCRIPT_DIR}/generate-runtime-config-agents.sh"

START='<!-- aidevops:runtime-agents:start -->'
END='<!-- aidevops:runtime-agents:end -->'
FALLBACK_START='<!-- aidevops:greeting-fallback:start -->'
BACKUP_DIR="${HOME}/.aidevops/config-backups/migrations/runtime-agents-md"

count_exact() {
	local needle="$1"
	local file="$2"
	grep -cxF "$needle" "$file" || true
	return 0
}

backup_count() {
	local runtime="$1"
	find "$BACKUP_DIR" -type f -name "*-${runtime}-AGENTS.md" 2>/dev/null | wc -l | tr -d ' '
	return 0
}

# Print the file without its managed block, for byte comparison of user content.
outside_block() {
	local file="$1"
	awk -v start="$START" -v end="$END" '
		$0 == start { inside = 1; next }
		$0 == end { inside = 0; next }
		!inside { print }
	' "$file"
	return 0
}

for runtime in opencode claude-code; do
	dir="${TMP_DIR}/${runtime}"
	file="${dir}/AGENTS.md"

	# 1. Fresh generation: exactly one managed block containing the template.
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: managed start missing on fresh generate"
	[[ "$(count_exact "$END" "$file")" -eq 1 ]] || fail "$runtime: managed end missing on fresh generate"
	[[ "$(head -n 1 "$file")" == "$START" ]] || fail "$runtime: fresh file does not start with the managed block"
	grep -qF 'content outside them is preserved' "$file" || fail "$runtime: preservation notice missing"
	[[ "$(count_exact "$FALLBACK_START" "$file")" -eq 1 ]] || fail "$runtime: greeting fallback missing"
	[[ "$(backup_count "$runtime")" -eq 0 ]] || fail "$runtime: fresh generation made a backup"

	# 2. User adds text above and below the block (the issue reproduction).
	{
		printf '%s\n' '## HARD RULE: local rule' 'Keep this line above.' ''
		cat "$file"
		printf '%s\n' '' 'Keep this line below.'
	} >"${file}.new"
	mv "${file}.new" "$file"
	before=$(outside_block "$file")

	# 3. Two regenerations keep the outside bytes and one managed block.
	_generate_greeting_agents_md "$runtime" "$dir"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(outside_block "$file")" == "$before" ]] || fail "$runtime: user content outside the block changed"
	[[ "$(head -n 1 "$file")" == '## HARD RULE: local rule' ]] || fail "$runtime: text above the block moved"
	[[ "$(tail -n 1 "$file")" == 'Keep this line below.' ]] || fail "$runtime: text below the block moved"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: managed block duplicated"
	[[ "$(count_exact "$FALLBACK_START" "$file")" -eq 1 ]] || fail "$runtime: greeting fallback duplicated"
	[[ "$(backup_count "$runtime")" -eq 0 ]] || fail "$runtime: marked file was backed up"

	# 4. A stale managed block is refreshed without touching outside content.
	awk -v start="$START" -v end="$END" '
		$0 == start { print; print "stale framework text"; inside = 1; next }
		$0 == end { inside = 0 }
		!inside { print }
	' "$file" >"${file}.new"
	mv "${file}.new" "$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	if grep -qF 'stale framework text' "$file"; then fail "$runtime: stale managed content kept"; fi
	[[ "$(outside_block "$file")" == "$before" ]] || fail "$runtime: refresh changed outside content"

	# 5. Unedited legacy file (old unwrapped template) migrates without a backup.
	awk -v start="$START" -v end="$END" '
		$0 == start { inside = 1; skip = 2; next }
		$0 == end { inside = 0; next }
		inside && skip > 0 { skip--; next }
		inside { print }
	' "$file" >"${TMP_DIR}/${runtime}-legacy.md"
	cp "${TMP_DIR}/${runtime}-legacy.md" "$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: legacy file not wrapped"
	[[ "$(backup_count "$runtime")" -eq 0 ]] || fail "$runtime: unedited legacy file was backed up"

	# 6. Edited legacy file is backed up once, then wrapped.
	{
		printf 'my legacy rule\n'
		cat "${TMP_DIR}/${runtime}-legacy.md"
	} >"$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(backup_count "$runtime")" -eq 1 ]] || fail "$runtime: edited legacy file not backed up exactly once"
	backup=$(find "$BACKUP_DIR" -type f -name "*-${runtime}-AGENTS.md" -print -quit)
	grep -qxF 'my legacy rule' "$backup" || fail "$runtime: backup lost the legacy rule"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: edited legacy file not wrapped"

	# 7. Malformed markers (unterminated) are backed up, never silently deleted.
	printf '%s\nuser text in a broken block\n' "$START" >"$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(backup_count "$runtime")" -eq 2 ]] || fail "$runtime: malformed file not backed up"
	[[ "$(count_exact "$START" "$file")" -eq 1 && "$(count_exact "$END" "$file")" -eq 1 ]] ||
		fail "$runtime: malformed file not repaired"

	# 8. CRLF user content outside the block is preserved byte-for-byte.
	{
		printf 'crlf rule\r\n\r\n'
		cat "$file"
	} >"${file}.new"
	mv "${file}.new" "$file"
	crlf_before=$(head -n 2 "$file" | od -c)
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(head -n 2 "$file" | od -c)" == "$crlf_before" ]] || fail "$runtime: CRLF user content changed"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: CRLF file block duplicated"

	# 9. An unterminated user suffix keeps its exact bytes (no added newline).
	printf 'unterminated tail' >>"$file"
	cp "$file" "${file}.before"
	_generate_greeting_agents_md "$runtime" "$dir"
	cmp -s "$file" "${file}.before" || fail "$runtime: unterminated suffix bytes changed"
	rm -f "${file}.before"

	# 10. Symlinked AGENTS.md is updated in place, not replaced.
	target="${TMP_DIR}/${runtime}-target.md"
	{
		printf 'linked rule\n\n'
		cat "$file"
	} >"$target"
	rm -f "$file"
	ln -s "$target" "$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ -L "$file" ]] || fail "$runtime: symlink replaced"
	grep -qxF 'linked rule' "$target" || fail "$runtime: user content lost through symlink"
	[[ "$(count_exact "$START" "$target")" -eq 1 ]] || fail "$runtime: symlink target block duplicated"
done

printf 'PASS: AGENTS.md user content outside the managed block survives regeneration\n'

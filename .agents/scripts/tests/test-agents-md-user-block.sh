#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage: a user-owned block in ~/.config/<runtime>/AGENTS.md
# (between aidevops:user-rules markers) survives regeneration by setup.sh /
# auto-update, while the framework-managed section is still rewritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

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

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

# shellcheck source=../generate-runtime-config-agents.sh
source "${SCRIPT_DIR}/generate-runtime-config-agents.sh"

START='<!-- aidevops:user-rules:start -->'
END='<!-- aidevops:user-rules:end -->'
FALLBACK_START='<!-- aidevops:greeting-fallback:start -->'

count_exact() {
	local needle="$1"
	local file="$2"
	grep -cxF "$needle" "$file" || true
	return 0
}

for runtime in opencode claude-code; do
	dir="${TMP_DIR}/${runtime}"
	file="${dir}/AGENTS.md"

	# 1. Fresh generation: no user block is invented.
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 0 ]] || fail "$runtime: unexpected user block on fresh generate"
	[[ "$(count_exact "$FALLBACK_START" "$file")" -eq 1 ]] || fail "$runtime: greeting fallback missing"

	# 2. User adds a block and some stray local text outside it.
	{
		printf '%s\n' "$START" '## HARD RULE: local rule' 'Keep this line.' "$END" ''
		printf 'stray text outside the block\n'
		cat "$file"
	} >"${file}.new"
	mv "${file}.new" "$file"

	# 3. Regenerate (what setup.sh --stage ai-session does on every update).
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: user block start lost or duplicated"
	[[ "$(count_exact "$END" "$file")" -eq 1 ]] || fail "$runtime: user block end lost or duplicated"
	grep -qxF '## HARD RULE: local rule' "$file" || fail "$runtime: user heading lost"
	grep -qxF 'Keep this line.' "$file" || fail "$runtime: user content lost"
	[[ "$(head -n 1 "$file")" == "$START" ]] || fail "$runtime: user block not at top"
	if grep -qF 'stray text outside the block' "$file"; then
		fail "$runtime: text outside the user block should stay framework-managed"
	fi
	[[ "$(count_exact "$FALLBACK_START" "$file")" -eq 1 ]] || fail "$runtime: greeting fallback duplicated"

	# 4. Idempotent across repeated updates.
	_generate_greeting_agents_md "$runtime" "$dir"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 1 ]] || fail "$runtime: user block duplicated on repeat"
	[[ "$(grep -cxF 'Keep this line.' "$file")" -eq 1 ]] || fail "$runtime: user content duplicated on repeat"

	# 5. An unterminated block is not copied (no partial/duplicated content).
	printf '%s\npartial\n' "$START" >"$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ "$(count_exact "$START" "$file")" -eq 0 ]] || fail "$runtime: unterminated block copied"

	# 6. Symlinked AGENTS.md is updated in place, not replaced.
	target="${TMP_DIR}/${runtime}-target.md"
	printf '%s\nlinked rule\n%s\n' "$START" "$END" >"$target"
	rm -f "$file"
	ln -s "$target" "$file"
	_generate_greeting_agents_md "$runtime" "$dir"
	[[ -L "$file" ]] || fail "$runtime: symlink replaced"
	grep -qxF 'linked rule' "$target" || fail "$runtime: user block lost through symlink"
done

printf 'PASS: AGENTS.md user block survives regeneration\n'

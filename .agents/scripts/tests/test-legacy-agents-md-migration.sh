#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#32592: cleanup_legacy_agents_md_templates moves only unmodified legacy
# home/Git-root AGENTS.md template copies (by git blob hash) into a backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
cleanup() {
	rm -rf "$SANDBOX"
	return 0
}
trap cleanup EXIT
export HOME="$SANDBOX"

print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }

# shellcheck source=../setup/modules/migrations.sh
source "${SCRIPT_DIR}/setup/modules/migrations.sh"

fail() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

# The embedded history must be well-formed blob ids.
[[ "${#_LEGACY_AGENTS_TEMPLATE_BLOBS[@]}" -eq 31 ]] || fail "expected 31 known template blobs"
for blob in "${_LEGACY_AGENTS_TEMPLATE_BLOBS[@]}"; do
	[[ "$blob" =~ ^[0-9a-f]{40}$ ]] || fail "malformed blob id: $blob"
done

# Shallow CI checkouts lack template history, so register a synthetic template.
mkdir -p "$HOME/Git" "$HOME/.factory"
printf '# legacy template\n' >"$HOME/Git/AGENTS.md"
cp "$HOME/Git/AGENTS.md" "$HOME/AGENTS.md"
_LEGACY_AGENTS_TEMPLATE_BLOBS+=("$(git hash-object --no-filters -- "$HOME/Git/AGENTS.md")")

# A newline-first IFS (as set by setup scripts) must not break membership.
IFS=$'\n\t'

# 1) The Git-root copy goes; the home copy stays while a memory file points at it.
# shellcheck disable=SC2088 # literal pointer text, not a path
printf 'At the beginning of each session, read ~/AGENTS.md\n' >"$HOME/.factory/DROID.md"
cleanup_legacy_agents_md_templates
[[ -f "$HOME/AGENTS.md" ]] || fail "referenced home copy removed"
[[ ! -e "$HOME/Git/AGENTS.md" ]] || fail "unmodified Git-root template kept"

# 2) Without a referencing memory file the home copy goes too.
rm "$HOME/.factory/DROID.md"
cleanup_legacy_agents_md_templates
[[ ! -e "$HOME/AGENTS.md" ]] || fail "unreferenced home template kept"

# 3) Edited copies are user content.
printf '# My own notes\n' >"$HOME/Git/AGENTS.md"
cleanup_legacy_agents_md_templates
[[ -f "$HOME/Git/AGENTS.md" ]] || fail "edited copy removed"

# 4) Every removal is recoverable.
backups=$(find "$HOME/.aidevops/config-backups/migrations/gh32592-agents-md" -type f -name '*-AGENTS.md' | wc -l | tr -d ' ')
[[ "$backups" -eq 2 ]] || fail "expected 2 backups, found $backups"

printf 'PASS: legacy AGENTS.md template migration\n'

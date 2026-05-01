#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../prework-discovery-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'stub-pr\n'
SH
chmod +x "$TMP_DIR/bin/gh"

output="$TMP_DIR/out.md"
PATH="$TMP_DIR/bin:$PATH" "$HELPER" --keywords 'helper token efficiency' --files '.agents/AGENTS.md' --repo 'owner/repo' >"$output"

grep -q 'Prework discovery' "$output"
grep -q 'Recently merged related PRs' "$output"
grep -q 'Open related PRs' "$output"
grep -q 'stub-pr' "$output"

printf 'PASS prework-discovery-helper\n'

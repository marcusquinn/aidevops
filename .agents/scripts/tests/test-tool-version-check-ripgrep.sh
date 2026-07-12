#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Ensure aidevops update keeps the ripgrep executable used by shell and
# OpenCode native Grep current through supported system package managers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_VERSION_CHECK="$REPO_ROOT/.agents/scripts/tool-version-check.sh"

python3 - "$TOOL_VERSION_CHECK" <<'PY'
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()
entry = re.search(
    r'"brew\|ripgrep\|rg\|--version\|ripgrep\|\$\(_brew_upgrade_cmd ripgrep\)"',
    content,
)
assert entry, "BREW_TOOLS must manage ripgrep through _brew_upgrade_cmd"

assert 'ripgrep) get_public_release_tag "BurntSushi/ripgrep" ;;' in content, (
    "Linux without Homebrew must resolve the latest ripgrep release"
)

helper_start = content.index("_brew_upgrade_cmd() {")
helper_end = content.index("\n}", helper_start)
helper = content[helper_start:helper_end]
for manager_command in (
    "brew upgrade",
    "apt-get install --only-upgrade",
    "dnf upgrade",
    "yum upgrade",
):
    assert manager_command in helper, f"missing package-manager path: {manager_command}"

print("PASS: ripgrep participates in cross-platform tool updates")
PY

exit 0

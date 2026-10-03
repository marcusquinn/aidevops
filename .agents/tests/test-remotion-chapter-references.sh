#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
python3 - "$repo_root/.agents" <<'PY'
import re
import sys
from pathlib import Path
agents = Path(sys.argv[1])
count = 0
files = list((agents / "tools/video/remotion").glob("*.md"))
files += list((agents / "services/hosting/cloudflare-platform-skill").glob("*.md"))
files += [agents / "services/hosting/cloudflare-platform-skill.md"]
for file in files:
    text = file.read_text()
    for link in re.findall(r"\]\(([^\s()]+\.md)(?:#[^\s()]*)?\)", text):
        if not re.match(r"[a-zA-Z]+:", link) and not link.startswith("/"):
            assert (file.parent / link).is_file(), f"Broken local link: {file.relative_to(agents)} -> {link}"
            count += 1
    if file.name == "remotion.md":
        for chapter in re.findall(r"`(remotion-[\w-]+\.md)`", text):
            assert (file.parent / chapter).is_file(), chapter
            count += 1
for file in agents.rglob("*.md"):
    assert not re.search(r"tools/video/remotion(?:\.md|-[\w-]+\.md)", file.read_text()), f"Stale inbound link: {file.relative_to(agents)}"
for relative in ("content/heygen-skill/rules-remotion-integration.md", "tools/design/threejs.md"):
    for chapter in re.findall(r"tools/video/remotion/[\w-]+\.md", (agents / relative).read_text()):
        assert (agents / chapter).is_file(), chapter
assert (agents / "scripts/higgsfield/remotion/src/Root.tsx").is_file()
print(f"PASS: {count} nested skill links resolve; inbound links, HeyGen, Three.js and Higgsfield preserved")
PY

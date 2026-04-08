#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# check-generator-rules.py — Validate deny/allow secret rules in settings updater
# Called by safety-policy-check.sh check_generator_rules()
# Usage: python3 check-generator-rules.py <target_file>

import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")


def extract_block(name: str) -> str:
    m = re.search(rf"{name}\s*=\s*\[(.*?)\]\n", text, re.S)
    return m.group(1) if m else ""


allow_block = extract_block("allow_rules")
deny_block = extract_block("deny_rules")

forbidden_in_allow = [
    "Bash(gopass show *)",
    "Bash(pass show *)",
    "Bash(op read *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
    "Read(~/.config/aidevops/credentials.sh)",
]

required_in_deny = [
    "Bash(gopass show *)",
    "Bash(pass show *)",
    "Bash(op read *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
    "Read(~/.config/aidevops/credentials.sh)",
]

errors = []
for rule in forbidden_in_allow:
    if rule in allow_block:
        errors.append(f"forbidden rule in allow_rules: {rule}")

for rule in required_in_deny:
    if rule not in deny_block:
        errors.append(f"required deny rule missing: {rule}")

if errors:
    for err in errors:
        print(f"FAIL: {err}", file=sys.stderr)
    sys.exit(1)

print("PASS: generator deny/allow secret rules")

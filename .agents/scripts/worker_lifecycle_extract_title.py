#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract --title value from an opencode/claude command line.

Extracted from the inline heredoc in worker-lifecycle-common.sh
(_extract_session_title) to reduce shell nesting depth (GH#17561).

Reads env vars:
    SESSION_CMD  - the full command line string to parse

Prints: the title value to stdout, or empty string if not found.
"""

import os
import shlex

cmd = os.environ.get("SESSION_CMD", "")
title = ""

try:
    tokens = shlex.split(cmd)
except Exception:
    tokens = cmd.split()

for idx, token in enumerate(tokens):
    if token == "--title" and idx + 1 < len(tokens):
        collected = []
        for next_token in tokens[idx + 1 :]:
            if next_token.startswith("--"):
                break
            if next_token == "/full-loop":
                break
            collected.append(next_token)
        title = " ".join(collected).strip()
        break

print(title)

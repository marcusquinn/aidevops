# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Scaffolding allowlist for added-only lines in file-split-verify.py."""

import re

RESIDUE_RES = tuple(
    re.compile(pattern)
    for pattern in (
        r"^$",
        r"^#",
        # Include guards: a complete test or assignment of a guard variable.
        r"^(?:readonly\s+|export\s+|declare\s+-\S+\s+)?[A-Za-z0-9_]*_(?:LOADED|INCLUDED|SOURCED)=[\w\"']*;?$",
        r"^(?:if\s+)?\[\[?(?!.*(?:\$\(|`))[^;&|]*_(?:LOADED|INCLUDED|SOURCED)\b[^;&|]*\]\]?"
        r"(?:\s*&&\s*(?:return|exit)\s+\d+(?:\s+2>\s*/dev/null)?)?(?:;\s*then)?;?$",
        r"^(?:if\s+!?\s*)?(?:source|\.)\s+(?!.*(?:\$\(|`))[^;&|<>]+(?:\s+2>\s*/dev/null)?"
        r"(?:\s*\|\|\s*(?:return|exit)\s+\d+)?(?:;\s*then)?;?$",
        # Directory resolution: `X="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`.
        r"^(?:readonly\s+|local\s+|export\s+)?[A-Za-z_]\w*=\"?\$\(\s*cd\s+\"?\$\(\s*dirname\s+\"?"
        r"\$\{BASH_SOURCE(?:\[0\])?(?::-[^}]*)?\}\"?\s*\)\"?\s*(?:&>\s*/dev/null\s*)?&&\s*pwd(?:\s+-P)?\s*\)\"?"
        r"(?:\s*\|\|\s*(?:return|exit)\s+\d+)?;?$",
        # Plain *_DIR assignment of a literal/variable-only value.
        r"^(?:readonly\s+|local\s+|export\s+)?[A-Za-z0-9_]*(?:_DIR|_dir)="
        r"(?:\"(?:[^\"`$]|\$\{[A-Za-z_]\w*\}|\$[A-Za-z_]\w*)*\"|[^\s;&|<>`$()\"']*);?$",
        # Directory existence tests.
        r"^(?:if\s+)?\[\[?\s+-[a-z]\s+\"\$\{?\w+_DIR\}?[^\"`$;&|]*\"\s+\]\]?(?:;\s*then)?;?$",
        r"^unset\s+[^;&|<>`$()]+;?$",
        r"^(?:fi|then|else)$",
        r"^(?:return|exit)\s+\d+(?:\s+2>\s*/dev/null\s*\|\|\s*exit\s+\d+)?;?$",
        r"^(?:printf|echo)\b(?!.*\$\()[^;&|<>`]*\b(?:failed to (?:load|source)|cannot (?:load|source))\b"
        r"[^;&|<>`]*>&2;?$",
    )
)


def is_residue(content):
    """Return True when an added-only line is split scaffolding."""
    stripped = content.strip()
    return any(pattern.search(stripped) for pattern in RESIDUE_RES)

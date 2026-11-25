# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""pnpm node-linker policy for controller dependency provisioning (t19381).

pnpm's hoisted linker keeps a flat root tree of real directories and leaves
member node_modules nearly empty, so isolated-layout checks can never pass; a
hoisted root also exceeds the copy budget. Refuse it before any lock reads.
"""

from pathlib import Path
import re

from _worktree_dependency_manifest import Rejected

# A top-level key, optionally quoted (valid YAML), with optional space before ':'.
HOISTED_WORKSPACE_SETTING = re.compile(
    rb"^(?:nodeLinker|'nodeLinker'|\"nodeLinker\")[ \t]*:[ \t]*['\"]?hoisted['\"]?[ \t]*(?:#.*)?\r?$",
    re.MULTILINE,
)
HOISTED_NPMRC_SETTING = re.compile(rb"^[ \t]*node-linker[ \t]*=[ \t]*['\"]?hoisted['\"]?[ \t]*\r?$", re.MULTILINE)


def reject_hoisted_linker(roots, read_bytes, workspace_config=b""):
    """Fail fast with a named reason when pnpm is configured for node-linker=hoisted.

    read_bytes is the caller's contained, budgeted reader (identity.regular_bytes).
    """
    if HOISTED_WORKSPACE_SETTING.search(workspace_config):
        raise Rejected("unsupported-node-linker-hoisted")
    for root in dict.fromkeys(roots):
        npmrc = Path(root) / ".npmrc"
        # A symlinked .npmrc is not read here; the existing checks still decide.
        if (npmrc.is_file() and not npmrc.is_symlink()
                and HOISTED_NPMRC_SETTING.search(read_bytes(npmrc))):
            raise Rejected("unsupported-node-linker-hoisted")

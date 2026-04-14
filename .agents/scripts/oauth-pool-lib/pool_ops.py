#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops.py — dispatcher facade for the per-command modules.

This file used to be a 1047-line monolith carrying every ``cmd_*`` function
(``cmd_refresh`` alone was cyclomatic 72 — the highest-complexity function in
the entire repo). The t2069 decomposition split each command into its own
module under ``oauth_pool_lib/`` so that:

  * ``cmd_refresh`` dispatcher is now a thin orchestrator of focused helpers
  * each per-command file stays under qlty's per-file complexity threshold
  * shared primitives (locking, atomic write, provider tables, auth-entry
    builder, token-endpoint POST) live in ``_common.py``

The shell wrapper continues to invoke ``python3 oauth-pool-lib/pool_ops.py
<command>`` exactly as before — this dispatcher is the only file that is
runnable as a script. The per-command modules are not directly executed.

Backwards compatibility: code that does
``from oauth_pool_lib.pool_ops import cmd_refresh, cmd_rotate, ...`` will
continue to work because every ``cmd_*`` symbol is re-exported below.

Security: No token values are printed to stdout/stderr (except structured
output consumed by the shell wrapper). Secrets flow via env vars, never argv.
"""

from __future__ import annotations

import os
import sys


# When invoked as ``python3 pool_ops.py``, ``__package__`` is empty and
# relative imports fail. Add the parent of this file's directory to
# ``sys.path`` so absolute ``oauth_pool_lib.<module>`` imports resolve.
_HERE = os.path.dirname(os.path.abspath(__file__))
_PARENT = os.path.dirname(_HERE)
if _PARENT not in sys.path:
    sys.path.insert(0, _PARENT)

# Inject a stable package alias so ``from oauth_pool_lib.<module> import ...``
# resolves even though the directory on disk is ``oauth-pool-lib`` (hyphenated,
# not a valid Python identifier). The parent ``scripts`` dir gets imported as a
# regular folder, but the hyphenated subdir needs an explicit alias.
import importlib.util
_PKG_INIT = os.path.join(_HERE, "__init__.py")
if "oauth_pool_lib" not in sys.modules:
    spec = importlib.util.spec_from_file_location(
        "oauth_pool_lib", _PKG_INIT, submodule_search_locations=[_HERE],
    )
    _mod = importlib.util.module_from_spec(spec)
    sys.modules["oauth_pool_lib"] = _mod
    spec.loader.exec_module(_mod)


from oauth_pool_lib.pool_ops_accounts import (  # noqa: E402
    cmd_assign_pending,
    cmd_check_pending,
    cmd_import_check,
    cmd_list_accounts,
    cmd_list_pending,
    cmd_remove_account,
    cmd_set_priority,
    cmd_status_stats,
    cmd_upsert,
)
from oauth_pool_lib.pool_ops_auto_clear import cmd_auto_clear  # noqa: E402
from oauth_pool_lib.pool_ops_cooldowns import (  # noqa: E402
    cmd_normalize_cooldowns,
    cmd_reset_cooldowns,
)
from oauth_pool_lib.pool_ops_health import (  # noqa: E402
    cmd_check_accounts,
    cmd_check_expiry,
    cmd_check_meta,
    cmd_check_validate,
)
from oauth_pool_lib.pool_ops_mark_failure import cmd_mark_failure  # noqa: E402
from oauth_pool_lib.pool_ops_refresh import cmd_refresh  # noqa: E402
from oauth_pool_lib.pool_ops_rotate import cmd_rotate  # noqa: E402
from oauth_pool_lib.pool_ops_token_utils import (  # noqa: E402
    cmd_cursor_decode_jwt,
    cmd_cursor_read_auth,
    cmd_extract_token_error,
    cmd_extract_token_fields,
    cmd_google_validate,
    cmd_openai_read_auth,
)


COMMANDS = {
    "auto-clear": cmd_auto_clear,
    "upsert": cmd_upsert,
    "normalize-cooldowns": cmd_normalize_cooldowns,
    "rotate": cmd_rotate,
    "refresh": cmd_refresh,
    "mark-failure": cmd_mark_failure,
    "check-accounts": cmd_check_accounts,
    "check-validate": cmd_check_validate,
    "check-meta": cmd_check_meta,
    "check-expiry": cmd_check_expiry,
    "reset-cooldowns": cmd_reset_cooldowns,
    "set-priority": cmd_set_priority,
    "remove-account": cmd_remove_account,
    "assign-pending": cmd_assign_pending,
    "check-pending": cmd_check_pending,
    "list-pending": cmd_list_pending,
    "import-check": cmd_import_check,
    "status-stats": cmd_status_stats,
    "list-accounts": cmd_list_accounts,
    "extract-token-fields": cmd_extract_token_fields,
    "extract-token-error": cmd_extract_token_error,
    "openai-read-auth": cmd_openai_read_auth,
    "cursor-read-auth": cmd_cursor_read_auth,
    "cursor-decode-jwt": cmd_cursor_decode_jwt,
    "google-validate": cmd_google_validate,
}


__all__ = list(COMMANDS) + ["main"]


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <command>", file=sys.stderr)
        print(f"Commands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

    COMMANDS[cmd]()


if __name__ == "__main__":
    main()

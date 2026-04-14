# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""oauth-pool-lib package — Python operations for ``oauth-pool-helper.sh``.

Split into per-command modules during the t2069 decomposition. The shell
wrapper continues to invoke ``python3 pool_ops.py <command>``; that file is
now a thin dispatcher that re-exports from the per-command submodules.
"""

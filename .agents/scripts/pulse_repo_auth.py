#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Compatibility entry point for the former Pulse auth CLI."""
import subprocess
import sys

import github_auth_runtime as runtime
from github_app_auth import AuthError

if __name__ == "__main__":
    try:
        sys.exit(runtime.main())
    except (AuthError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, AuthError) else "GitHub authentication failed", file=sys.stderr)
        sys.exit(1)
else:
    sys.modules[__name__] = runtime

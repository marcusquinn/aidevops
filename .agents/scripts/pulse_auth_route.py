# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Compatibility module for the former routing import path."""
import sys
import github_auth_routing

sys.modules[__name__] = github_auth_routing

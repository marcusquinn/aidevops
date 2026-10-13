# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Compatibility module for the former usage import path."""
import sys
import github_auth_usage

sys.modules[__name__] = github_auth_usage

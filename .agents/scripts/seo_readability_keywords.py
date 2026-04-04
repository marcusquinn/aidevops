#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Compatibility exports for readability and keyword modules."""

from seo_keywords import KeywordAnalyzer  # type: ignore[import-not-found]
from seo_readability import ReadabilityScorer  # type: ignore[import-not-found]

__all__ = [
    "ReadabilityScorer",
    "KeywordAnalyzer",
]

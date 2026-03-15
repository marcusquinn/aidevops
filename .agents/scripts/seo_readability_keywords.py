#!/usr/bin/env python3
"""Compatibility exports for readability and keyword modules."""

from seo_keywords import KeywordAnalyzer  # type: ignore[import-not-found]
from seo_readability import ReadabilityScorer  # type: ignore[import-not-found]

__all__ = [
    "ReadabilityScorer",
    "KeywordAnalyzer",
]

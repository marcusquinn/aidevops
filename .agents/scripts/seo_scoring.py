#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Compatibility exports for SEO scoring modules."""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from seo_intent_quality import SEOQualityRater, SearchIntentAnalyzer  # type: ignore[import-not-found]
from seo_readability_keywords import KeywordAnalyzer, ReadabilityScorer  # type: ignore[import-not-found]

__all__ = [
    "ReadabilityScorer",
    "KeywordAnalyzer",
    "SearchIntentAnalyzer",
    "SEOQualityRater",
]

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Search intent classification engine."""

import re
from typing import Any, Dict


class SearchIntentAnalyzer:
    """Classifies search intent from keyword patterns."""

    INFO_SIGNALS = [
        "what", "why", "how", "when", "where", "who", "guide", "tutorial",
        "learn", "tips", "best practices", "explained", "definition", "meaning",
    ]
    NAV_SIGNALS = ["login", "sign in", "website", "official", "home page", "account", "dashboard"]
    TRANS_SIGNALS = [
        "buy", "purchase", "order", "download", "get", "pricing", "cost",
        "free trial", "sign up", "subscribe", "install", "coupon", "deal", "discount",
    ]
    COMMERCIAL_SIGNALS = [
        "best", "top", "review", "vs", "versus", "compare", "comparison",
        "alternative", "alternatives", "better than", "instead of",
    ]
    RECOMMENDATIONS = {
        "informational": "Create comprehensive, educational content with step-by-step instructions.",
        "navigational": "Optimize brand pages and ensure clear navigation.",
        "transactional": "Focus on product pages with clear pricing and CTAs.",
        "commercial": "Create comparison and review content with pros/cons.",
    }

    def analyze(self, keyword: str) -> Dict[str, Any]:
        keyword_lower = keyword.lower()
        scores = {"informational": 0, "navigational": 0, "transactional": 0, "commercial": 0}

        signal_map = [
            (self.INFO_SIGNALS, "informational", 2),
            (self.NAV_SIGNALS, "navigational", 3),
            (self.TRANS_SIGNALS, "transactional", 2),
            (self.COMMERCIAL_SIGNALS, "commercial", 2),
        ]
        for signals, intent, weight in signal_map:
            for signal in signals:
                if signal in keyword_lower:
                    scores[intent] += weight

        if re.match(r"^(what|why|how|when|where|who|can|should|is|are|does)", keyword_lower):
            scores["informational"] += 3
        if re.search(r"\d+\s+(best|top)", keyword_lower):
            scores["commercial"] += 3

        total = sum(scores.values()) or 1
        confidence = {k: round(v / total * 100, 1) for k, v in scores.items()}
        primary = max(scores.items(), key=lambda item: item[1])[0]

        return {
            "keyword": keyword,
            "primary_intent": primary,
            "confidence": confidence,
            "recommendation": self.RECOMMENDATIONS.get(primary, ""),
        }

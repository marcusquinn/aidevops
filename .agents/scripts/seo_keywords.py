#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Keyword density and placement analysis engine."""

import re
from typing import Any, Dict, List, Optional

from seo_extraction import extract_markdown_sections  # type: ignore[import-not-found]


class KeywordAnalyzer:
    """Analyzes keyword density, distribution, and placement."""

    def analyze(
        self,
        content: str,
        primary_keyword: str,
        secondary_keywords: Optional[List[str]] = None,
        target_density: float = 1.5,
    ) -> Dict[str, Any]:
        secondary_keywords = secondary_keywords or []
        word_count = len(content.split())
        sections = extract_markdown_sections(content)

        primary = self._analyze_keyword(content, primary_keyword, word_count, sections, target_density)

        secondary_results = []
        for keyword in secondary_keywords:
            secondary_results.append(
                self._analyze_keyword(content, keyword, word_count, sections, target_density * 0.5)
            )

        stuffing = self._detect_stuffing(content, primary_keyword, primary["density"])

        return {
            "word_count": word_count,
            "primary_keyword": {"keyword": primary_keyword, **primary},
            "secondary_keywords": secondary_results,
            "keyword_stuffing": stuffing,
            "recommendations": self._recommendations(primary, secondary_results, stuffing, target_density),
        }

    def _analyze_keyword(
        self,
        content: str,
        keyword: str,
        word_count: int,
        sections: List[Dict[str, str]],
        target_density: float,
    ) -> Dict[str, Any]:
        content_lower = content.lower()
        keyword_lower = keyword.lower()
        count = content_lower.count(keyword_lower)
        density = (count / word_count * 100) if word_count > 0 else 0

        first_100 = " ".join(content.split()[:100]).lower()
        in_first_100 = keyword_lower in first_100

        in_h1 = False
        h2_count = 0
        h2_with_keyword = 0
        for section in sections:
            if section["type"] == "h1" and keyword_lower in section["header"].lower():
                in_h1 = True
            if section["type"] == "h2":
                h2_count += 1
                if keyword_lower in section["header"].lower():
                    h2_with_keyword += 1

        last_para = content.split("\n\n")[-1].lower() if "\n\n" in content else content[-500:].lower()
        in_conclusion = keyword_lower in last_para

        status = self._density_status(density, target_density)

        return {
            "occurrences": count,
            "density": round(density, 2),
            "target_density": target_density,
            "density_status": status,
            "in_first_100_words": in_first_100,
            "in_h1": in_h1,
            "in_h2_headings": f"{h2_with_keyword}/{h2_count}",
            "in_conclusion": in_conclusion,
        }

    def _density_status(self, density: float, target: float) -> str:
        if density < target * 0.5:
            return "too_low"
        if density < target * 0.8:
            return "slightly_low"
        if density > target * 1.5:
            return "too_high"
        if density > target * 1.2:
            return "slightly_high"
        return "optimal"

    def _detect_stuffing(self, content: str, keyword: str, density: float) -> Dict[str, Any]:
        risk = "none"
        warnings: List[str] = []
        if density > 3.0:
            risk = "high"
            warnings.append(f"Density {density}% is very high (over 3%)")
        elif density > 2.5:
            risk = "medium"
            warnings.append(f"Density {density}% is high (over 2.5%)")

        keyword_lower = keyword.lower()
        sentences = re.split(r"[.!?]+", content)
        consecutive = 0
        max_consecutive = 0
        for sentence in sentences:
            if keyword_lower in sentence.lower():
                consecutive += 1
                max_consecutive = max(max_consecutive, consecutive)
            else:
                consecutive = 0

        if max_consecutive >= 5:
            risk = "high"
            warnings.append(f"Keyword in {max_consecutive} consecutive sentences")
        elif max_consecutive >= 3:
            if risk == "none":
                risk = "low"
            warnings.append(f"Keyword in {max_consecutive} consecutive sentences")

        return {"risk_level": risk, "warnings": warnings, "safe": risk in ("none", "low")}

    def _recommendations(
        self,
        primary: Dict[str, Any],
        secondary: List[Dict[str, Any]],
        stuffing: Dict[str, Any],
        target_density: float,
    ) -> List[str]:
        recommendations: List[str] = []
        status = primary["density_status"]
        if status == "too_low":
            recommendations.append(
                f"Primary keyword density too low ({primary['density']}%). Target {target_density}%."
            )
        elif status == "too_high":
            recommendations.append(
                f"Primary keyword density too high ({primary['density']}%). Risk of stuffing."
            )

        if not primary["in_first_100_words"]:
            recommendations.append("Primary keyword missing from first 100 words.")
        if not primary["in_h1"]:
            recommendations.append("Primary keyword missing from H1 heading.")
        if not primary["in_conclusion"]:
            recommendations.append("Consider mentioning primary keyword in conclusion.")
        if not stuffing["safe"]:
            recommendations.append(f"KEYWORD STUFFING RISK: {stuffing['risk_level'].upper()}")

        for result in secondary:
            if result["occurrences"] == 0:
                recommendations.append(f"Secondary keyword '{result.get('keyword', '?')}' not found.")

        return recommendations

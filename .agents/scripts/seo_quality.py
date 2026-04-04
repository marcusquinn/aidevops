#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""SEO quality rating engine."""

from typing import Any, Dict, List, Optional, Tuple

from seo_extraction import analyze_quality_structure, count_links  # type: ignore[import-not-found]


class SEOQualityRater:
    """Rates content against SEO best practices (0-100)."""

    def __init__(self) -> None:
        self.guidelines = {
            "min_word_count": 2000,
            "optimal_word_count": 2500,
            "primary_keyword_density_min": 1.0,
            "primary_keyword_density_max": 2.0,
            "min_internal_links": 3,
            "min_external_links": 2,
            "meta_title_min": 50,
            "meta_title_max": 60,
            "meta_desc_min": 150,
            "meta_desc_max": 160,
            "min_h2_sections": 4,
        }

    def _score_content(self, structure: Dict[str, Any], issues: List[str], warnings: List[str]) -> int:
        word_count = structure["word_count"]
        score = 100
        if word_count < self.guidelines["min_word_count"]:
            score -= 30
            issues.append(f"Content too short ({word_count} words). Min {self.guidelines['min_word_count']}.")
        elif word_count < self.guidelines["optimal_word_count"]:
            score -= 10
            warnings.append(f"Content could be longer ({word_count} words).")
        return max(0, score)

    def _score_structure(self, structure: Dict[str, Any], issues: List[str], warnings: List[str]) -> int:
        score = 100
        if not structure["has_h1"]:
            score -= 30
            issues.append("Missing H1 heading.")
        if structure["h2_count"] < self.guidelines["min_h2_sections"]:
            score -= 15
            warnings.append(
                f"Too few H2 sections ({structure['h2_count']}). Target {self.guidelines['min_h2_sections']}+."
            )
        return max(0, score)

    def _score_keywords(
        self,
        structure: Dict[str, Any],
        primary_keyword: Optional[str],
        issues: List[str],
        warnings: List[str],
    ) -> int:
        if not primary_keyword:
            warnings.append("No primary keyword specified.")
            return 50
        score = 100
        if not structure["keyword_in_h1"]:
            score -= 20
            issues.append(f"Keyword '{primary_keyword}' missing from H1.")
        if not structure["keyword_in_first_100"]:
            score -= 15
            issues.append(f"Keyword '{primary_keyword}' missing from first 100 words.")
        return max(0, score)

    def _score_meta(
        self,
        primary_keyword: Optional[str],
        meta_title: Optional[str],
        meta_description: Optional[str],
        issues: List[str],
        warnings: List[str],
    ) -> int:
        score = 100
        if not meta_title:
            score -= 40
            issues.append("Meta title missing.")
        else:
            title_len = len(meta_title)
            if title_len < self.guidelines["meta_title_min"] or title_len > self.guidelines["meta_title_max"] + 10:
                score -= 15
                warnings.append(
                    f"Meta title length ({title_len}) outside "
                    f"{self.guidelines['meta_title_min']}-{self.guidelines['meta_title_max']} range."
                )
            if primary_keyword and primary_keyword.lower() not in meta_title.lower():
                score -= 15
                warnings.append("Primary keyword not in meta title.")

        if not meta_description:
            score -= 40
            issues.append("Meta description missing.")
        else:
            desc_len = len(meta_description)
            if desc_len < self.guidelines["meta_desc_min"] or desc_len > self.guidelines["meta_desc_max"] + 10:
                score -= 15
                warnings.append(
                    f"Meta description length ({desc_len}) outside "
                    f"{self.guidelines['meta_desc_min']}-{self.guidelines['meta_desc_max']} range."
                )
        return max(0, score)

    def _score_links(self, content: str, warnings: List[str]) -> Tuple[int, int, int]:
        score = 100
        internal, external = count_links(content)
        if internal < self.guidelines["min_internal_links"]:
            score -= 20
            warnings.append(
                f"Too few internal links ({internal}). Target {self.guidelines['min_internal_links']}+."
            )
        if external < self.guidelines["min_external_links"]:
            score -= 15
            warnings.append(
                f"Too few external links ({external}). Target {self.guidelines['min_external_links']}+."
            )
        return max(0, score), internal, external

    def rate(
        self,
        content: str,
        primary_keyword: Optional[str] = None,
        meta_title: Optional[str] = None,
        meta_description: Optional[str] = None,
    ) -> Dict[str, Any]:
        structure = analyze_quality_structure(content, primary_keyword)
        issues: List[str] = []
        warnings: List[str] = []
        suggestions: List[str] = []

        scores: Dict[str, float] = {}
        scores["content"] = self._score_content(structure, issues, warnings)
        scores["structure"] = self._score_structure(structure, issues, warnings)
        scores["keywords"] = self._score_keywords(structure, primary_keyword, issues, warnings)
        scores["meta"] = self._score_meta(primary_keyword, meta_title, meta_description, issues, warnings)
        links_score, internal, external = self._score_links(content, warnings)
        scores["links"] = links_score

        weights = {"content": 0.20, "structure": 0.15, "keywords": 0.25, "meta": 0.15, "links": 0.15}
        overall = sum(scores.get(key, 0) * weight for key, weight in weights.items()) + 10

        grade = "A" if overall >= 90 else "B" if overall >= 80 else "C" if overall >= 70 else "D" if overall >= 60 else "F"

        return {
            "overall_score": round(overall, 1),
            "grade": grade,
            "category_scores": scores,
            "critical_issues": issues,
            "warnings": warnings,
            "suggestions": suggestions,
            "publishing_ready": overall >= 80 and len(issues) == 0,
            "details": {
                "word_count": structure["word_count"],
                "h2_count": structure["h2_count"],
                "internal_links": internal,
                "external_links": external,
            },
        }

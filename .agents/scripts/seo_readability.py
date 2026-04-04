#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Readability scoring engine for SEO content analysis."""

from typing import Any, Dict, List

from seo_extraction import (  # type: ignore[import-not-found]
    analyze_readability_structure,
    analyze_text_complexity,
    calculate_basic_readability_metrics,
    clean_readability_content,
)


class ReadabilityScorer:
    """Analyzes content readability using multiple metrics."""

    def __init__(self) -> None:
        self.target_reading_level = (8, 10)
        self.target_flesch_ease = (60, 70)
        self.max_avg_sentence_length = 20
        self.max_paragraph_sentences = 4

    def analyze(self, content: str) -> Dict[str, Any]:
        clean_text = clean_readability_content(content)
        if not clean_text:
            return {"error": "No readable content provided"}

        metrics = self._calculate_metrics(clean_text)
        structure = analyze_readability_structure(content, clean_text)
        complexity = analyze_text_complexity(clean_text)
        overall_score = self._calculate_overall_score(metrics, structure, complexity)
        grade = self._get_grade(overall_score)
        recommendations = self._generate_recommendations(metrics, structure, complexity)

        return {
            "overall_score": overall_score,
            "grade": grade,
            "reading_level": metrics.get("flesch_kincaid_grade", 0),
            "readability_metrics": metrics,
            "structure_analysis": structure,
            "complexity_analysis": complexity,
            "recommendations": recommendations,
        }

    def _calculate_metrics(self, text: str) -> Dict[str, Any]:
        try:
            import textstat  # type: ignore

            return {
                "flesch_reading_ease": round(textstat.flesch_reading_ease(text), 1),
                "flesch_kincaid_grade": round(textstat.flesch_kincaid_grade(text), 1),
                "gunning_fog": round(textstat.gunning_fog(text), 1),
                "smog_index": round(textstat.smog_index(text), 1),
                "syllable_count": textstat.syllable_count(text),
                "lexicon_count": textstat.lexicon_count(text),
                "sentence_count": textstat.sentence_count(text),
            }
        except ImportError:
            return calculate_basic_readability_metrics(text)

    def _calculate_overall_score(
        self,
        metrics: Dict[str, Any],
        structure: Dict[str, Any],
        complexity: Dict[str, Any],
    ) -> float:
        score = 100.0
        flesch = metrics.get("flesch_reading_ease", 0)
        if flesch < 30:
            score -= 30
        elif flesch < 50:
            score -= 20
        elif flesch < 60:
            score -= 10

        grade = metrics.get("flesch_kincaid_grade", 0)
        if grade > 14:
            score -= 25
        elif grade > 12:
            score -= 15
        elif grade > 10:
            score -= 5

        avg_sentence = structure.get("avg_sentence_length", 0)
        if avg_sentence > 30:
            score -= 20
        elif avg_sentence > 25:
            score -= 10
        elif avg_sentence > 20:
            score -= 5

        very_long = structure.get("very_long_sentences", 0)
        if very_long > 0:
            score -= min(15, very_long * 3)

        passive_ratio = complexity.get("passive_sentence_ratio", 0)
        if passive_ratio > 30:
            score -= 10
        elif passive_ratio > 20:
            score -= 5

        return max(0, min(100, score))

    def _get_grade(self, score: float) -> str:
        if score >= 90:
            return "A (Excellent)"
        if score >= 80:
            return "B (Good)"
        if score >= 70:
            return "C (Average)"
        if score >= 60:
            return "D (Needs Work)"
        return "F (Poor)"

    def _generate_recommendations(
        self,
        metrics: Dict[str, Any],
        structure: Dict[str, Any],
        complexity: Dict[str, Any],
    ) -> List[str]:
        recommendations: List[str] = []
        grade = metrics.get("flesch_kincaid_grade", 0)
        if grade > 12:
            recommendations.append(
                f"Reading level too high (Grade {grade}). Target 8-10. Simplify sentences."
            )

        flesch = metrics.get("flesch_reading_ease", 0)
        if flesch < 50:
            recommendations.append(
                f"Content is difficult to read (Flesch {flesch}). Break up complex sentences."
            )

        avg_sentence = structure.get("avg_sentence_length", 0)
        if avg_sentence > 25:
            recommendations.append(
                f"Average sentence length too long ({avg_sentence:.1f} words). Target under 20."
            )

        very_long = structure.get("very_long_sentences", 0)
        if very_long > 0:
            recommendations.append(f"{very_long} sentences are very long (35+ words). Split them.")

        passive_ratio = complexity.get("passive_sentence_ratio", 0)
        if passive_ratio > 20:
            recommendations.append(
                f"Passive voice is high ({passive_ratio:.0f}%). Use more active voice."
            )

        if not recommendations:
            recommendations.append("Readability is excellent.")

        return recommendations

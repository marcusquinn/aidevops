#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extraction and parsing utilities for SEO content analysis."""

import re
from typing import Any, Dict, List, Optional, Tuple


def clean_readability_content(content: str) -> str:
    text = re.sub(r"^#+\s+", "", content, flags=re.MULTILINE)
    text = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", text)
    text = re.sub(r"```[^`]*```", "", text)
    text = re.sub(r"\n\s*\n", "\n\n", text)
    return text.strip()


def calculate_basic_readability_metrics(text: str) -> Dict[str, Any]:
    sentences = [s.strip() for s in re.split(r"[.!?]+", text) if s.strip()]
    words = text.split()
    syllables = sum(max(1, len(re.findall(r"[aeiouy]+", w.lower()))) for w in words)
    word_count = len(words)
    sentence_count = max(1, len(sentences))
    avg_sentence_len = word_count / sentence_count
    avg_syllables_per_word = syllables / max(1, word_count)

    flesch = 206.835 - 1.015 * avg_sentence_len - 84.6 * avg_syllables_per_word
    grade = 0.39 * avg_sentence_len + 11.8 * avg_syllables_per_word - 15.59

    return {
        "flesch_reading_ease": round(max(0, min(100, flesch)), 1),
        "flesch_kincaid_grade": round(max(0, grade), 1),
        "gunning_fog": 0,
        "smog_index": 0,
        "syllable_count": syllables,
        "lexicon_count": word_count,
        "sentence_count": sentence_count,
        "note": "Install textstat for more accurate metrics: pip3 install textstat",
    }


def analyze_readability_structure(original: str, clean_text: str) -> Dict[str, Any]:
    sentences = [s.strip() for s in re.split(r"[.!?]+", clean_text) if s.strip()]
    sentence_lengths = [len(s.split()) for s in sentences]
    avg_sentence_length = sum(sentence_lengths) / len(sentence_lengths) if sentence_lengths else 0

    paragraphs = [p for p in original.split("\n\n") if p.strip() and not p.strip().startswith("#")]
    words = clean_text.split()

    return {
        "total_sentences": len(sentences),
        "avg_sentence_length": round(avg_sentence_length, 1),
        "longest_sentence": max(sentence_lengths) if sentence_lengths else 0,
        "total_paragraphs": len(paragraphs),
        "total_words": len(words),
        "long_sentences": len([s for s in sentence_lengths if s > 25]),
        "very_long_sentences": len([s for s in sentence_lengths if s > 35]),
    }


def analyze_text_complexity(text: str) -> Dict[str, Any]:
    transition_words = [
        "however", "moreover", "furthermore", "therefore", "consequently",
        "additionally", "meanwhile", "nevertheless", "thus", "hence",
        "for example", "for instance", "in addition", "on the other hand",
    ]
    text_lower = text.lower()
    transition_count = sum(text_lower.count(word) for word in transition_words)

    sentences = re.split(r"[.!?]+", text)
    passive_indicators = ["was", "were", "been", "being", "is", "are"]
    passive_count = 0
    for sentence in sentences:
        sentence_lower = sentence.lower()
        if any(f" {word} " in f" {sentence_lower} " for word in passive_indicators):
            if re.search(r"\b\w+(ed|en)\b", sentence_lower):
                passive_count += 1

    total_sentences = len([s for s in sentences if s.strip()])
    passive_ratio = (passive_count / total_sentences * 100) if total_sentences > 0 else 0

    words = text.split()
    complex_words = sum(1 for w in words if len(re.findall(r"[aeiouy]+", w.lower())) >= 3)
    complex_ratio = (complex_words / len(words) * 100) if words else 0

    return {
        "transition_word_count": transition_count,
        "passive_sentence_ratio": round(passive_ratio, 1),
        "complex_word_ratio": round(complex_ratio, 1),
    }


def extract_markdown_sections(content: str) -> List[Dict[str, str]]:
    sections: List[Dict[str, str]] = []
    current: Dict[str, str] = {"type": "intro", "header": "", "content": ""}
    for line in content.split("\n"):
        heading1 = re.match(r"^#\s+(.+)$", line)
        heading2 = re.match(r"^##\s+(.+)$", line)
        heading3 = re.match(r"^###\s+(.+)$", line)
        heading = heading1 or heading2 or heading3
        if heading:
            if current["content"]:
                sections.append(current.copy())
            heading_type = "h1" if heading1 else ("h2" if heading2 else "h3")
            current = {"type": heading_type, "header": heading.group(1), "content": ""}
        else:
            current["content"] += line + "\n"

    if current["content"]:
        sections.append(current)

    return sections


def analyze_quality_structure(content: str, keyword: Optional[str]) -> Dict[str, Any]:
    lines = content.split("\n")
    h1_count = 0
    h1_text = ""
    h2_count = 0

    for line in lines:
        if re.match(r"^#\s+", line):
            h1_count += 1
            if not h1_text:
                h1_text = re.sub(r"^#\s+", "", line)
        elif re.match(r"^##\s+", line):
            h2_count += 1

    keyword_lower = keyword.lower() if keyword else ""
    return {
        "word_count": len(content.split()),
        "has_h1": h1_count > 0,
        "h1_count": h1_count,
        "h2_count": h2_count,
        "keyword_in_h1": keyword_lower in h1_text.lower() if keyword_lower else False,
        "keyword_in_first_100": keyword_lower in " ".join(content.split()[:100]).lower() if keyword_lower else False,
    }


def count_links(content: str) -> Tuple[int, int]:
    internal = len(re.findall(r"\[([^\]]+)\]\((?!http)", content))
    external = len(re.findall(r"\[([^\]]+)\]\(https?://", content))
    return internal, external

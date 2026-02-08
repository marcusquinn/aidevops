#!/usr/bin/env python3
"""
SEO Content Analyzer

Comprehensive content analysis combining readability scoring, keyword density,
search intent classification, and SEO quality rating.

Adapted from TheCraigHewitt/seomachine (MIT License) for aidevops.
Original: https://github.com/TheCraigHewitt/seomachine

Usage:
    python3 seo-content-analyzer.py analyze <file> [--keyword "primary keyword"] [--secondary "kw1,kw2"]
    python3 seo-content-analyzer.py readability <file>
    python3 seo-content-analyzer.py keywords <file> --keyword "primary keyword"
    python3 seo-content-analyzer.py intent "search query"
    python3 seo-content-analyzer.py quality <file> [--keyword "primary keyword"] [--meta-title "title"] [--meta-desc "desc"]
    python3 seo-content-analyzer.py help

Dependencies (install with pip):
    pip3 install textstat  # For readability scoring (optional - falls back to basic metrics)
"""

import sys
import re
import json
import os
from collections import Counter
from typing import Dict, List, Optional, Any


# ---------------------------------------------------------------------------
# Readability Scorer
# ---------------------------------------------------------------------------

class ReadabilityScorer:
    """Analyzes content readability using multiple metrics."""

    def __init__(self):
        self.target_reading_level = (8, 10)
        self.target_flesch_ease = (60, 70)
        self.max_avg_sentence_length = 20
        self.max_paragraph_sentences = 4

    def analyze(self, content: str) -> Dict[str, Any]:
        clean_text = self._clean_content(content)
        if not clean_text:
            return {"error": "No readable content provided"}

        metrics = self._calculate_metrics(clean_text)
        structure = self._analyze_structure(content, clean_text)
        complexity = self._analyze_complexity(clean_text)
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

    def _clean_content(self, content: str) -> str:
        text = re.sub(r"^#+\s+", "", content, flags=re.MULTILINE)
        text = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", text)
        text = re.sub(r"```[^`]*```", "", text)
        text = re.sub(r"\n\s*\n", "\n\n", text)
        return text.strip()

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
            # Fallback: basic metrics without textstat
            sentences = [s.strip() for s in re.split(r"[.!?]+", text) if s.strip()]
            words = text.split()
            syllables = sum(max(1, len(re.findall(r"[aeiouy]+", w.lower()))) for w in words)
            word_count = len(words)
            sentence_count = max(1, len(sentences))
            avg_sentence_len = word_count / sentence_count
            avg_syllables_per_word = syllables / max(1, word_count)

            # Flesch Reading Ease approximation
            flesch = 206.835 - 1.015 * avg_sentence_len - 84.6 * avg_syllables_per_word
            # Flesch-Kincaid Grade Level approximation
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

    def _analyze_structure(self, original: str, clean_text: str) -> Dict[str, Any]:
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

    def _analyze_complexity(self, text: str) -> Dict[str, Any]:
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
            sl = sentence.lower()
            if any(f" {w} " in f" {sl} " for w in passive_indicators):
                if re.search(r"\b\w+(ed|en)\b", sl):
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

    def _calculate_overall_score(self, metrics, structure, complexity) -> float:
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
        elif score >= 80:
            return "B (Good)"
        elif score >= 70:
            return "C (Average)"
        elif score >= 60:
            return "D (Needs Work)"
        return "F (Poor)"

    def _generate_recommendations(self, metrics, structure, complexity) -> List[str]:
        recs: List[str] = []
        grade = metrics.get("flesch_kincaid_grade", 0)
        if grade > 12:
            recs.append(f"Reading level too high (Grade {grade}). Target 8-10. Simplify sentences.")
        flesch = metrics.get("flesch_reading_ease", 0)
        if flesch < 50:
            recs.append(f"Content is difficult to read (Flesch {flesch}). Break up complex sentences.")
        avg = structure.get("avg_sentence_length", 0)
        if avg > 25:
            recs.append(f"Average sentence length too long ({avg:.1f} words). Target under 20.")
        vl = structure.get("very_long_sentences", 0)
        if vl > 0:
            recs.append(f"{vl} sentences are very long (35+ words). Split them.")
        pr = complexity.get("passive_sentence_ratio", 0)
        if pr > 20:
            recs.append(f"Passive voice is high ({pr:.0f}%). Use more active voice.")
        if not recs:
            recs.append("Readability is excellent.")
        return recs


# ---------------------------------------------------------------------------
# Keyword Analyzer
# ---------------------------------------------------------------------------

class KeywordAnalyzer:
    """Analyzes keyword density, distribution, and placement."""

    def analyze(self, content: str, primary_keyword: str,
                secondary_keywords: Optional[List[str]] = None,
                target_density: float = 1.5) -> Dict[str, Any]:
        secondary_keywords = secondary_keywords or []
        word_count = len(content.split())
        sections = self._extract_sections(content)

        primary = self._analyze_keyword(content, primary_keyword, word_count, sections, target_density)

        secondary_results = []
        for kw in secondary_keywords:
            secondary_results.append(
                self._analyze_keyword(content, kw, word_count, sections, target_density * 0.5)
            )

        stuffing = self._detect_stuffing(content, primary_keyword, primary["density"])

        return {
            "word_count": word_count,
            "primary_keyword": {"keyword": primary_keyword, **primary},
            "secondary_keywords": secondary_results,
            "keyword_stuffing": stuffing,
            "recommendations": self._recommendations(primary, secondary_results, stuffing, target_density),
        }

    def _extract_sections(self, content: str) -> List[Dict]:
        sections: List[Dict] = []
        current: Dict[str, Any] = {"type": "intro", "header": "", "content": ""}
        for line in content.split("\n"):
            m1 = re.match(r"^#\s+(.+)$", line)
            m2 = re.match(r"^##\s+(.+)$", line)
            m3 = re.match(r"^###\s+(.+)$", line)
            if m1 or m2 or m3:
                if current["content"]:
                    sections.append(current.copy())
                htype = "h1" if m1 else ("h2" if m2 else "h3")
                header = (m1 or m2 or m3).group(1)  # type: ignore[union-attr]
                current = {"type": htype, "header": header, "content": ""}
            else:
                current["content"] += line + "\n"
        if current["content"]:
            sections.append(current)
        return sections

    def _analyze_keyword(self, content, keyword, word_count, sections, target) -> Dict[str, Any]:
        cl = content.lower()
        kl = keyword.lower()
        count = cl.count(kl)
        density = (count / word_count * 100) if word_count > 0 else 0

        first_100 = " ".join(content.split()[:100]).lower()
        in_first_100 = kl in first_100

        in_h1 = False
        h2_count = 0
        h2_with_kw = 0
        for s in sections:
            if s["type"] == "h1" and kl in s["header"].lower():
                in_h1 = True
            if s["type"] == "h2":
                h2_count += 1
                if kl in s["header"].lower():
                    h2_with_kw += 1

        last_para = content.split("\n\n")[-1].lower() if "\n\n" in content else content[-500:].lower()
        in_conclusion = kl in last_para

        status = "optimal"
        if density < target * 0.5:
            status = "too_low"
        elif density < target * 0.8:
            status = "slightly_low"
        elif density > target * 1.5:
            status = "too_high"
        elif density > target * 1.2:
            status = "slightly_high"

        return {
            "occurrences": count,
            "density": round(density, 2),
            "target_density": target,
            "density_status": status,
            "in_first_100_words": in_first_100,
            "in_h1": in_h1,
            "in_h2_headings": f"{h2_with_kw}/{h2_count}",
            "in_conclusion": in_conclusion,
        }

    def _detect_stuffing(self, content, keyword, density) -> Dict[str, Any]:
        risk = "none"
        warnings: List[str] = []
        if density > 3.0:
            risk = "high"
            warnings.append(f"Density {density}% is very high (over 3%)")
        elif density > 2.5:
            risk = "medium"
            warnings.append(f"Density {density}% is high (over 2.5%)")

        kl = keyword.lower()
        sentences = re.split(r"[.!?]+", content)
        consecutive = 0
        max_consecutive = 0
        for s in sentences:
            if kl in s.lower():
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

    def _recommendations(self, primary, secondary, stuffing, target) -> List[str]:
        recs: List[str] = []
        st = primary["density_status"]
        if st == "too_low":
            recs.append(f"Primary keyword density too low ({primary['density']}%). Target {target}%.")
        elif st == "too_high":
            recs.append(f"Primary keyword density too high ({primary['density']}%). Risk of stuffing.")
        if not primary["in_first_100_words"]:
            recs.append("Primary keyword missing from first 100 words.")
        if not primary["in_h1"]:
            recs.append("Primary keyword missing from H1 heading.")
        if not primary["in_conclusion"]:
            recs.append("Consider mentioning primary keyword in conclusion.")
        if not stuffing["safe"]:
            recs.append(f"KEYWORD STUFFING RISK: {stuffing['risk_level'].upper()}")
        for s in secondary:
            if s["occurrences"] == 0:
                recs.append(f"Secondary keyword '{s.get('keyword', '?')}' not found.")
        return recs


# ---------------------------------------------------------------------------
# Search Intent Analyzer
# ---------------------------------------------------------------------------

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

    def analyze(self, keyword: str) -> Dict[str, Any]:
        kl = keyword.lower()
        scores = {"informational": 0, "navigational": 0, "transactional": 0, "commercial": 0}

        for s in self.INFO_SIGNALS:
            if s in kl:
                scores["informational"] += 2
        for s in self.NAV_SIGNALS:
            if s in kl:
                scores["navigational"] += 3
        for s in self.TRANS_SIGNALS:
            if s in kl:
                scores["transactional"] += 2
        for s in self.COMMERCIAL_SIGNALS:
            if s in kl:
                scores["commercial"] += 2

        if re.match(r"^(what|why|how|when|where|who|can|should|is|are|does)", kl):
            scores["informational"] += 3
        if re.search(r"\d+\s+(best|top)", kl):
            scores["commercial"] += 3

        total = sum(scores.values()) or 1
        confidence = {k: round(v / total * 100, 1) for k, v in scores.items()}
        primary = max(scores, key=scores.get)  # type: ignore[arg-type]

        recs = {
            "informational": "Create comprehensive, educational content with step-by-step instructions.",
            "navigational": "Optimize brand pages and ensure clear navigation.",
            "transactional": "Focus on product pages with clear pricing and CTAs.",
            "commercial": "Create comparison and review content with pros/cons.",
        }

        return {
            "keyword": keyword,
            "primary_intent": primary,
            "confidence": confidence,
            "recommendation": recs.get(primary, ""),
        }


# ---------------------------------------------------------------------------
# SEO Quality Rater
# ---------------------------------------------------------------------------

class SEOQualityRater:
    """Rates content against SEO best practices (0-100)."""

    def __init__(self):
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

    def rate(self, content: str, primary_keyword: Optional[str] = None,
             meta_title: Optional[str] = None,
             meta_description: Optional[str] = None) -> Dict[str, Any]:
        structure = self._analyze_structure(content, primary_keyword)
        scores = {}
        issues: List[str] = []
        warnings: List[str] = []
        suggestions: List[str] = []

        # Content score
        wc = structure["word_count"]
        cs = 100
        if wc < self.guidelines["min_word_count"]:
            cs -= 30
            issues.append(f"Content too short ({wc} words). Min {self.guidelines['min_word_count']}.")
        elif wc < self.guidelines["optimal_word_count"]:
            cs -= 10
            warnings.append(f"Content could be longer ({wc} words).")
        scores["content"] = max(0, cs)

        # Structure score
        ss = 100
        if not structure["has_h1"]:
            ss -= 30
            issues.append("Missing H1 heading.")
        if structure["h2_count"] < self.guidelines["min_h2_sections"]:
            ss -= 15
            warnings.append(f"Too few H2 sections ({structure['h2_count']}). Target {self.guidelines['min_h2_sections']}+.")
        scores["structure"] = max(0, ss)

        # Keyword score
        ks = 100
        if primary_keyword:
            if not structure["keyword_in_h1"]:
                ks -= 20
                issues.append(f"Keyword '{primary_keyword}' missing from H1.")
            if not structure["keyword_in_first_100"]:
                ks -= 15
                issues.append(f"Keyword '{primary_keyword}' missing from first 100 words.")
        else:
            ks = 50
            warnings.append("No primary keyword specified.")
        scores["keywords"] = max(0, ks)

        # Meta score
        ms = 100
        if not meta_title:
            ms -= 40
            issues.append("Meta title missing.")
        else:
            tl = len(meta_title)
            if tl < self.guidelines["meta_title_min"] or tl > self.guidelines["meta_title_max"] + 10:
                ms -= 15
                warnings.append(f"Meta title length ({tl}) outside {self.guidelines['meta_title_min']}-{self.guidelines['meta_title_max']} range.")
            if primary_keyword and primary_keyword.lower() not in meta_title.lower():
                ms -= 15
                warnings.append("Primary keyword not in meta title.")

        if not meta_description:
            ms -= 40
            issues.append("Meta description missing.")
        else:
            dl = len(meta_description)
            if dl < self.guidelines["meta_desc_min"] or dl > self.guidelines["meta_desc_max"] + 10:
                ms -= 15
                warnings.append(f"Meta description length ({dl}) outside {self.guidelines['meta_desc_min']}-{self.guidelines['meta_desc_max']} range.")
        scores["meta"] = max(0, ms)

        # Links score
        ls = 100
        internal = len(re.findall(r"\[([^\]]+)\]\((?!http)", content))
        external = len(re.findall(r"\[([^\]]+)\]\(https?://", content))
        if internal < self.guidelines["min_internal_links"]:
            ls -= 20
            warnings.append(f"Too few internal links ({internal}). Target {self.guidelines['min_internal_links']}+.")
        if external < self.guidelines["min_external_links"]:
            ls -= 15
            warnings.append(f"Too few external links ({external}). Target {self.guidelines['min_external_links']}+.")
        scores["links"] = max(0, ls)

        # Overall weighted score
        weights = {"content": 0.20, "structure": 0.15, "keywords": 0.25, "meta": 0.15, "links": 0.15}
        # Readability gets remaining 0.10 but we don't compute it here
        overall = sum(scores.get(k, 0) * w for k, w in weights.items()) + 10  # baseline readability

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
                "word_count": wc,
                "h2_count": structure["h2_count"],
                "internal_links": internal,
                "external_links": external,
            },
        }

    def _analyze_structure(self, content: str, keyword: Optional[str]) -> Dict[str, Any]:
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

        kl = keyword.lower() if keyword else ""
        return {
            "word_count": len(content.split()),
            "has_h1": h1_count > 0,
            "h1_count": h1_count,
            "h2_count": h2_count,
            "keyword_in_h1": kl in h1_text.lower() if kl else False,
            "keyword_in_first_100": kl in " ".join(content.split()[:100]).lower() if kl else False,
        }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def read_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, ensure_ascii=False))


def cmd_help() -> None:
    print("""SEO Content Analyzer - aidevops
Adapted from TheCraigHewitt/seomachine (MIT License)

Commands:
  analyze <file> [--keyword KW] [--secondary KW1,KW2]
      Full analysis: readability + keywords + SEO quality

  readability <file>
      Readability scoring (Flesch, grade level, structure)

  keywords <file> --keyword "primary keyword" [--secondary "kw1,kw2"]
      Keyword density, placement, and stuffing detection

  intent "search query"
      Search intent classification (informational/commercial/transactional/navigational)

  quality <file> [--keyword KW] [--meta-title TITLE] [--meta-desc DESC]
      SEO quality rating (0-100) with category breakdown

  help
      Show this help message

Optional dependency:
  pip3 install textstat   # More accurate readability metrics
""")


def parse_args(args: List[str]) -> Dict[str, Any]:
    result: Dict[str, Any] = {"command": args[0] if args else "help", "positional": [], "flags": {}}
    i = 1
    while i < len(args):
        if args[i].startswith("--"):
            key = args[i][2:]
            if i + 1 < len(args) and not args[i + 1].startswith("--"):
                result["flags"][key] = args[i + 1]
                i += 2
            else:
                result["flags"][key] = True
                i += 1
        else:
            result["positional"].append(args[i])
            i += 1
    return result


def main() -> None:
    if len(sys.argv) < 2:
        cmd_help()
        sys.exit(0)

    parsed = parse_args(sys.argv[1:])
    cmd = parsed["command"]

    if cmd == "help":
        cmd_help()
        return

    if cmd == "intent":
        query = " ".join(parsed["positional"]) if parsed["positional"] else parsed["flags"].get("keyword", "")
        if not query:
            print("Error: provide a search query", file=sys.stderr)
            sys.exit(1)
        analyzer = SearchIntentAnalyzer()
        print_json(analyzer.analyze(query))
        return

    # Commands that need a file
    if not parsed["positional"]:
        print(f"Error: {cmd} requires a file path", file=sys.stderr)
        sys.exit(1)

    filepath = parsed["positional"][0]
    if not os.path.isfile(filepath):
        print(f"Error: file not found: {filepath}", file=sys.stderr)
        sys.exit(1)

    content = read_file(filepath)
    keyword = parsed["flags"].get("keyword")
    secondary_str = parsed["flags"].get("secondary", "")
    secondary = [s.strip() for s in secondary_str.split(",") if s.strip()] if secondary_str else []

    if cmd == "readability":
        scorer = ReadabilityScorer()
        print_json(scorer.analyze(content))

    elif cmd == "keywords":
        if not keyword:
            print("Error: --keyword is required for keyword analysis", file=sys.stderr)
            sys.exit(1)
        analyzer = KeywordAnalyzer()
        print_json(analyzer.analyze(content, keyword, secondary))

    elif cmd == "quality":
        meta_title = parsed["flags"].get("meta-title")
        meta_desc = parsed["flags"].get("meta-desc")
        rater = SEOQualityRater()
        print_json(rater.rate(content, keyword, meta_title, meta_desc))

    elif cmd == "analyze":
        results: Dict[str, Any] = {}

        scorer = ReadabilityScorer()
        results["readability"] = scorer.analyze(content)

        if keyword:
            ka = KeywordAnalyzer()
            results["keywords"] = ka.analyze(content, keyword, secondary)

        rater = SEOQualityRater()
        meta_title = parsed["flags"].get("meta-title")
        meta_desc = parsed["flags"].get("meta-desc")
        results["seo_quality"] = rater.rate(content, keyword, meta_title, meta_desc)

        if keyword:
            ia = SearchIntentAnalyzer()
            results["search_intent"] = ia.analyze(keyword)

        print_json(results)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        cmd_help()
        sys.exit(1)


if __name__ == "__main__":
    main()

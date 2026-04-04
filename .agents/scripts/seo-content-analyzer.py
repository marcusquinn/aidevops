#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
import json
import os
from typing import Any, Dict, List

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from seo_scoring import (  # type: ignore[import-not-found]
    KeywordAnalyzer,
    ReadabilityScorer,
    SEOQualityRater,
    SearchIntentAnalyzer,
)


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


def _run_file_command(cmd: str, parsed: Dict[str, Any]) -> None:
    """Dispatch commands that operate on a file."""
    filepath = parsed["positional"][0]
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

    _run_file_command(cmd, parsed)


if __name__ == "__main__":
    main()

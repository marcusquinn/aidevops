#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Language detection and line counting for repo_metrics.py."""

from __future__ import annotations

from pathlib import Path
from typing import Any

LANGUAGE_BY_EXTENSION = {
    ".sh": "Shell",
    ".bash": "Shell",
    ".zsh": "Shell",
    ".fish": "Shell",
    ".py": "Python",
    ".pyw": "Python",
    ".js": "JavaScript",
    ".mjs": "JavaScript",
    ".cjs": "JavaScript",
    ".jsx": "JSX",
    ".ts": "TypeScript",
    ".tsx": "TSX",
    ".json": "JSON",
    ".jsonc": "JSON",
    ".yaml": "YAML",
    ".yml": "YAML",
    ".toml": "TOML",
    ".md": "Markdown",
    ".mdx": "MDX",
    ".html": "HTML",
    ".htm": "HTML",
    ".css": "CSS",
    ".scss": "SCSS",
    ".sass": "Sass",
    ".less": "Less",
    ".go": "Go",
    ".rs": "Rust",
    ".java": "Java",
    ".kt": "Kotlin",
    ".kts": "Kotlin",
    ".swift": "Swift",
    ".c": "C",
    ".h": "C/C++ Header",
    ".cc": "C++",
    ".cpp": "C++",
    ".cxx": "C++",
    ".hpp": "C++ Header",
    ".cs": "C#",
    ".php": "PHP",
    ".rb": "Ruby",
    ".pl": "Perl",
    ".pm": "Perl",
    ".lua": "Lua",
    ".r": "R",
    ".scala": "Scala",
    ".ex": "Elixir",
    ".exs": "Elixir",
    ".erl": "Erlang",
    ".hrl": "Erlang",
    ".hs": "Haskell",
    ".clj": "Clojure",
    ".dart": "Dart",
    ".vue": "Vue",
    ".svelte": "Svelte",
    ".zig": "Zig",
    ".nix": "Nix",
    ".sql": "SQL",
    ".awk": "AWK",
    ".ps1": "PowerShell",
    ".psm1": "PowerShell",
    ".tf": "Terraform",
    ".hcl": "HCL",
    ".xml": "XML",
    ".svg": "SVG",
}

LANGUAGE_BY_BASENAME = {
    "Dockerfile": "Dockerfile",
    "Containerfile": "Dockerfile",
    "Makefile": "Makefile",
    "Rakefile": "Ruby",
    "Gemfile": "Ruby",
    "Brewfile": "Ruby",
    "Justfile": "Just",
    "Procfile": "Procfile",
}

COMMENT_PREFIXES = {
    "Shell": ("#",),
    "Python": ("#",),
    "Ruby": ("#",),
    "Perl": ("#",),
    "R": ("#",),
    "YAML": ("#",),
    "TOML": ("#",),
    "Makefile": ("#",),
    "Dockerfile": ("#",),
    "PowerShell": ("#",),
    "JavaScript": ("//", "/*", "*"),
    "TypeScript": ("//", "/*", "*"),
    "JSX": ("//", "/*", "*"),
    "TSX": ("//", "/*", "*"),
    "Go": ("//", "/*", "*"),
    "Rust": ("//", "/*", "*"),
    "Java": ("//", "/*", "*"),
    "Kotlin": ("//", "/*", "*"),
    "Swift": ("//", "/*", "*"),
    "C": ("//", "/*", "*"),
    "C++": ("//", "/*", "*"),
    "C#": ("//", "/*", "*"),
    "PHP": ("//", "#", "/*", "*"),
    "CSS": ("/*", "*"),
    "SCSS": ("//", "/*", "*"),
    "Sass": ("//", "/*", "*"),
    "Less": ("//", "/*", "*"),
    "SQL": ("--", "/*", "*"),
    "HTML": ("<!--",),
    "XML": ("<!--",),
    "SVG": ("<!--",),
}

LANGUAGE_COLORS = {
    "Shell": "#89e051",
    "Python": "#3572A5",
    "JavaScript": "#f1e05a",
    "TypeScript": "#3178c6",
    "JSX": "#f1e05a",
    "TSX": "#3178c6",
    "Markdown": "#083fa1",
    "MDX": "#083fa1",
    "JSON": "#292929",
    "YAML": "#cb171e",
    "TOML": "#9c4221",
    "XML": "#0060ac",
    "HTML": "#e34c26",
    "CSS": "#563d7c",
    "SCSS": "#c6538c",
    "Sass": "#c6538c",
    "Dockerfile": "#384d54",
    "Makefile": "#427819",
    "Ruby": "#701516",
    "Go": "#00ADD8",
    "Rust": "#dea584",
    "Java": "#b07219",
    "Kotlin": "#A97BFF",
    "Swift": "#ffac45",
    "C": "#555555",
    "C++": "#f34b7d",
    "C#": "#178600",
    "PHP": "#4F5D95",
    "Perl": "#0298c3",
    "Lua": "#000080",
    "R": "#198CE7",
    "Scala": "#c22d40",
    "Elixir": "#6e4a7e",
    "Erlang": "#B83998",
    "Haskell": "#5e5086",
    "Clojure": "#db5855",
    "Dart": "#00B4AB",
    "Vue": "#41b883",
    "Svelte": "#ff3e00",
    "Zig": "#ec915c",
    "Nix": "#7e7eff",
    "SQL": "#e38c00",
    "AWK": "#c30e9b",
    "Terraform": "#844FBA",
    "HCL": "#844FBA",
}


def language_for(path: Path) -> str:
    name = path.name
    if name in LANGUAGE_BY_BASENAME:
        return LANGUAGE_BY_BASENAME[name]
    if name.startswith("Dockerfile"):
        return "Dockerfile"
    suffix = path.suffix.lower()
    return LANGUAGE_BY_EXTENSION.get(suffix, "")


def count_file(path: Path, language: str) -> dict[str, int]:
    prefixes = COMMENT_PREFIXES.get(language, ())
    code = comments = blanks = 0
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {"code": 0, "comments": 0, "blanks": 0}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            blanks += 1
        elif prefixes and stripped.startswith(prefixes):
            comments += 1
        else:
            code += 1
    return {"code": code, "comments": comments, "blanks": blanks}


def collect_languages(root: Path, files: list[Path]) -> tuple[list[dict[str, Any]], dict[str, int]]:
    aggregate: dict[str, dict[str, int]] = {}
    source_files = 0
    for path in files:
        language = language_for(path)
        if not language:
            continue
        counts = count_file(path, language)
        if counts["code"] == 0 and counts["comments"] == 0 and counts["blanks"] == 0:
            continue
        source_files += 1
        item = aggregate.setdefault(language, {"files": 0, "code": 0, "comments": 0, "blanks": 0})
        item["files"] += 1
        item["code"] += counts["code"]
        item["comments"] += counts["comments"]
        item["blanks"] += counts["blanks"]

    total_code = sum(item["code"] for item in aggregate.values())
    total_comments = sum(item["comments"] for item in aggregate.values())
    total_blanks = sum(item["blanks"] for item in aggregate.values())
    languages: list[dict[str, Any]] = []
    for name, item in aggregate.items():
        percentage = (item["code"] * 100 / total_code) if total_code else 0.0
        languages.append(
            {
                "name": name,
                "files": item["files"],
                "code": item["code"],
                "comments": item["comments"],
                "blanks": item["blanks"],
                "percentage": round(percentage, 2),
                "color": LANGUAGE_COLORS.get(name, "#6e7781"),
            }
        )
    languages.sort(key=lambda item: (-int(item["code"]), str(item["name"])))
    totals = {
        "source_files": source_files,
        "code": total_code,
        "comments": total_comments,
        "blanks": total_blanks,
        "languages": len(languages),
    }
    return languages, totals

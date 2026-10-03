#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Detect the search surfaces a repository can be found on."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

WEB_MARKERS = ["next.config.js", "next.config.mjs", "next.config.ts", "astro.config.mjs", "astro.config.ts",
               "nuxt.config.ts", "svelte.config.js", "vite.config.ts", "hugo.toml", "_config.yml", "CNAME",
               "index.html", "public/index.html", "docs/index.md", "mkdocs.yml", "docusaurus.config.js",
               "wp-config.php", "wp-content"]
ECOMMERCE_MARKERS = ["layout/theme.liquid", "config/settings_schema.json", "shopify.app.toml",
                     "woocommerce.php", "app/code/Magento"]


def _exists(root: Path, *names: str) -> bool:
    return any((root / name).exists() for name in names)


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def _package_json(root: Path) -> dict:
    try:
        return json.loads(_read(root / "package.json") or "{}")
    except json.JSONDecodeError:
        return {}


def _remote(root: Path) -> str:
    result = subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip()


def github_slug(root: Path) -> str:
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", _remote(root))
    return match.group(1) if match else ""


def npm_package(root: Path) -> str:
    package = _package_json(root)
    return "" if package.get("private") else str(package.get("name") or "")


def _package_surfaces(root: Path) -> list[str]:
    found = []
    if npm_package(root):
        found.append("npm")
    if re.search(r"^\[project\]", _read(root / "pyproject.toml"), re.M) or _exists(root, "setup.py"):
        found.append("pypi")
    if re.search(r"^\[package\]", _read(root / "Cargo.toml"), re.M):
        found.append("crates")
    if _exists(root, "Formula", "HomebrewFormula"):
        found.append("homebrew")
    return found


def _app_surfaces(root: Path) -> list[str]:
    found = []
    if list(root.glob("*.xcodeproj")) or _exists(root, "fastlane", "ios"):
        found.append("app-store")
    if _exists(root, "app/src/main/AndroidManifest.xml", "android"):
        found.append("play-store")
    if '"manifest_version"' in _read(root / "manifest.json"):
        found.append("chrome-web-store")
    if re.search(r"^Stable tag:", _read(root / "readme.txt"), re.M | re.I):
        found.append("wordpress-org")
    return found


def surfaces(root: Path, has_interface: bool = False, platform: str = "") -> list[str]:
    """Return detected surfaces; `ai-answers` always applies."""
    root = Path(root)
    found = []
    if github_slug(root):
        found.append("github")
    found += _package_surfaces(root)
    found += _app_surfaces(root)
    if platform == "shopify" or _exists(root, *ECOMMERCE_MARKERS):
        found.append("ecommerce")
    if has_interface or _exists(root, *WEB_MARKERS) or "ecommerce" in found:
        found.append("website")
    found.append("ai-answers")
    return list(dict.fromkeys(found))

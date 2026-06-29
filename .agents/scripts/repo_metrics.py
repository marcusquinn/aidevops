#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Generate local repository metrics for README badges and app about pages.

The scanner is intentionally dependency-light: Python stdlib plus git when the
target is a git repository. It counts tracked and unignored source files,
detects language mix by extension/basename, extracts dependency counts from
common manifests/lockfiles, and writes stable local artifacts:

  docs/metrics/repo-metrics.json
  docs/metrics/repo-metrics.md
  docs/metrics/badges/{loc,languages,dependencies}.svg

It can also write legacy .github/badges/loc-total.svg and
.github/badges/loc-languages.svg for existing aidevops-managed README blocks.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Iterable

try:  # Python 3.11+
    import tomllib  # type: ignore[attr-defined]
except Exception:  # pragma: no cover - Python <3.11 fallback
    tomllib = None  # type: ignore[assignment]


TOOL_VERSION = "1.0.0"

DEFAULT_EXCLUDES = (
    ".git",
    ".hg",
    ".svn",
    "__aidevops",
    "node_modules",
    "vendor",
    "dist",
    "build",
    ".next",
    ".nuxt",
    ".cache",
    ".venv",
    "venv",
    "env",
    "target",
    "coverage",
    "docs/metrics",
    ".github/badges",
)

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


def run_command(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            args,
            cwd=str(cwd),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None


def repo_root(path: Path) -> Path:
    proc = run_command(["git", "rev-parse", "--show-toplevel"], path)
    if proc and proc.returncode == 0 and proc.stdout.strip():
        return Path(proc.stdout.strip()).resolve()
    return path.resolve()


def git_remote_slug(root: Path) -> str:
    proc = run_command(["git", "config", "--get", "remote.origin.url"], root)
    if not proc or proc.returncode != 0:
        return ""
    url = proc.stdout.strip()
    if not url:
        return ""
    match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return match.group(1) if match else ""


def is_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            sample = handle.read(4096)
        return b"\0" in sample
    except OSError:
        return True


def should_exclude(rel: str, excludes: Iterable[str]) -> bool:
    rel_posix = rel.replace(os.sep, "/")
    parts = rel_posix.split("/")
    for pattern in excludes:
        clean = pattern.strip().strip("/")
        if not clean:
            continue
        if clean in parts:
            return True
        if rel_posix == clean or rel_posix.startswith(f"{clean}/"):
            return True
        if fnmatch.fnmatch(rel_posix, clean) or fnmatch.fnmatch(rel_posix, pattern):
            return True
    return False


def scan_prefixes(root: Path, paths: list[Path]) -> list[str]:
    prefixes: list[str] = []
    for scan_path in paths:
        resolved = scan_path.resolve()
        try:
            rel = resolved.relative_to(root)
        except ValueError:
            continue
        rel_s = rel.as_posix()
        if rel_s == ".":
            continue
        prefixes.append(rel_s)
    return prefixes


def matches_prefix(rel: str, prefixes: list[str]) -> bool:
    if not prefixes:
        return True
    for prefix in prefixes:
        if rel == prefix or rel.startswith(f"{prefix}/"):
            return True
    return False


def git_repo_relpaths(root: Path) -> list[str]:
    proc = run_command(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    if proc and proc.returncode == 0:
        return [part for part in proc.stdout.split("\0") if part]
    return []


def walk_repo_relpaths(root: Path, excludes: Iterable[str]) -> list[str]:
    rels: list[str] = []
    for walk_root, dirnames, filenames in os.walk(root):
        walk_path = Path(walk_root)
        rel_dir = walk_path.relative_to(root).as_posix() if walk_path != root else ""
        dirnames[:] = [
            item
            for item in dirnames
            if not should_exclude(f"{rel_dir}/{item}".strip("/"), excludes)
        ]
        rels.extend((walk_path / filename).relative_to(root).as_posix() for filename in filenames)
    return rels


def repo_relpaths(root: Path, excludes: Iterable[str]) -> list[str]:
    rels = git_repo_relpaths(root)
    return rels if rels else walk_repo_relpaths(root, excludes)


def is_countable_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not is_binary(path)


def list_repo_files(root: Path, paths: list[Path], excludes: Iterable[str]) -> list[Path]:
    prefixes = scan_prefixes(root, paths)
    rels = repo_relpaths(root, excludes)

    files: list[Path] = []
    seen: set[str] = set()
    for rel in rels:
        if rel in seen or should_exclude(rel, excludes) or not matches_prefix(rel, prefixes):
            continue
        seen.add(rel)
        path = root / rel
        if is_countable_file(path):
            files.append(path)
    return files


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


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_toml(path: Path) -> dict[str, Any]:
    if tomllib is None:
        return {}
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def normalise_dep_name(value: str) -> str:
    value = value.strip().strip('"\'')
    if not value or value.startswith(("#", "-r ", "--", "git+", "http://", "https://")):
        return ""
    if value.startswith("@"):
        parts = value.split("/")
        if len(parts) >= 2:
            return f"{parts[0]}/{re.split(r'[\s@<>=~!;]', parts[1], maxsplit=1)[0]}"
    match = re.match(r"([A-Za-z0-9_.-]+)", value)
    return match.group(1) if match else ""


def manifest_record(path: Path, root: Path, ecosystem: str, direct: set[str], locked: int = 0) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "ecosystem": ecosystem,
        "direct": len(direct),
        "locked": locked,
        "dependencies": sorted(direct),
    }


ManifestParseResult = tuple[dict[str, Any] | None, set[str], set[str]]
ManifestParser = Callable[[Path, Path], ManifestParseResult]
LockParser = Callable[[Path], tuple[int, set[str]]]


def normalised_names(values: Iterable[Any]) -> set[str]:
    names: set[str] = set()
    for value in values:
        name = normalise_dep_name(str(value))
        if name:
            names.add(name)
    return names


def parse_package_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    if not isinstance(data, dict):
        return None, set(), set()
    direct: set[str] = set()
    for key in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        deps = data.get(key)
        if isinstance(deps, dict):
            direct.update(str(name) for name in deps.keys())
    return manifest_record(path, root, "npm", direct), {f"npm:{name}" for name in direct}, set()


def parse_package_lock(path: Path) -> tuple[int, set[str]]:
    data = load_json(path)
    locked: set[str] = set()
    if isinstance(data, dict) and isinstance(data.get("packages"), dict):
        for key in data["packages"].keys():
            if isinstance(key, str) and key.startswith("node_modules/"):
                locked.add(key.removeprefix("node_modules/"))
    return len(locked), {f"npm:{name}" for name in locked}


def parse_requirements(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for raw in lines:
        name = normalise_dep_name(raw.split(";", 1)[0])
        if name:
            direct.add(name)
    return manifest_record(path, root, "python", direct), {f"python:{name}" for name in direct}, set()


def pyproject_project_dependencies(project: Any) -> set[str]:
    direct: set[str] = set()
    if not isinstance(project, dict):
        return direct

    deps = project.get("dependencies", [])
    if isinstance(deps, list):
        direct.update(normalised_names(deps))

    optional = project.get("optional-dependencies", {})
    if isinstance(optional, dict):
        for group in optional.values():
            if isinstance(group, list):
                direct.update(normalised_names(group))
    return direct


def pyproject_poetry_dependencies(data: dict[str, Any]) -> set[str]:
    tool = data.get("tool", {})
    poetry = tool.get("poetry", {}) if isinstance(tool, dict) else {}
    poetry_deps = poetry.get("dependencies", {}) if isinstance(poetry, dict) else {}
    if isinstance(poetry_deps, dict):
        return {str(name) for name in poetry_deps.keys() if str(name).lower() != "python"}
    return set()


def parse_pyproject(path: Path, root: Path) -> ManifestParseResult:
    data = load_toml(path)
    project = data.get("project", {}) if isinstance(data, dict) else {}
    direct = pyproject_project_dependencies(project)
    direct.update(pyproject_poetry_dependencies(data))
    return manifest_record(path, root, "python", direct), {f"python:{name}" for name in direct}, set()


def go_require_block_state(line: str, in_block: bool) -> tuple[bool, bool]:
    if line == "require (":
        return True, True
    if in_block and line == ")":
        return False, True
    return in_block, False


def go_require_name_from_line(line: str, in_block: bool) -> str:
    if line.startswith("require "):
        source = line.removeprefix("require ")
    elif in_block and line and not line.startswith("//"):
        source = line
    else:
        source = ""

    parts = source.split()
    return parts[0] if parts else ""


def parse_go_mod(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    in_block = False
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for raw in lines:
        line = raw.strip()
        in_block, handled = go_require_block_state(line, in_block)
        if handled:
            continue
        name = go_require_name_from_line(line, in_block)
        if name:
            direct.add(name)
    return manifest_record(path, root, "go", direct), {f"go:{name}" for name in direct}, set()


def parse_cargo_toml(path: Path, root: Path) -> ManifestParseResult:
    data = load_toml(path)
    direct: set[str] = set()
    for key in ("dependencies", "dev-dependencies", "build-dependencies"):
        deps = data.get(key, {}) if isinstance(data, dict) else {}
        if isinstance(deps, dict):
            direct.update(str(name) for name in deps.keys())
    return manifest_record(path, root, "cargo", direct), {f"cargo:{name}" for name in direct}, set()


def parse_cargo_lock(path: Path) -> tuple[int, set[str]]:
    names: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return 0, set()
    for line in lines:
        match = re.match(r'name\s*=\s*"([^"]+)"', line.strip())
        if match:
            names.add(match.group(1))
    return len(names), {f"cargo:{name}" for name in names}


def parse_composer_json(path: Path, root: Path) -> ManifestParseResult:
    data = load_json(path)
    direct: set[str] = set()
    if isinstance(data, dict):
        for key in ("require", "require-dev"):
            deps = data.get(key)
            if isinstance(deps, dict):
                direct.update(str(name) for name in deps.keys() if str(name).lower() != "php")
    return manifest_record(path, root, "composer", direct), {f"composer:{name}" for name in direct}, set()


def composer_lock_packages(data: Any) -> list[Any]:
    if not isinstance(data, dict):
        return []

    packages: list[Any] = []
    for key in ("packages", "packages-dev"):
        value = data.get(key)
        if isinstance(value, list):
            packages.extend(value)
    return packages


def composer_package_name(package: Any) -> str:
    if isinstance(package, dict) and package.get("name"):
        return str(package["name"])
    return ""


def parse_composer_lock(path: Path) -> tuple[int, set[str]]:
    data = load_json(path)
    names: set[str] = set()
    for package in composer_lock_packages(data):
        name = composer_package_name(package)
        if name:
            names.add(name)
    return len(names), {f"composer:{name}" for name in names}


def parse_gemfile(path: Path, root: Path) -> ManifestParseResult:
    direct: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return None, set(), set()
    for line in lines:
        match = re.match(r"\s*gem\s+['\"]([^'\"]+)['\"]", line)
        if match:
            direct.add(match.group(1))
    return manifest_record(path, root, "bundler", direct), {f"bundler:{name}" for name in direct}, set()


def parse_gemfile_lock(path: Path) -> tuple[int, set[str]]:
    names: set[str] = set()
    in_specs = False
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return 0, set()
    for line in lines:
        if line.strip() == "specs:":
            in_specs = True
            continue
        if in_specs:
            match = re.match(r"\s{4}([A-Za-z0-9_.-]+)\s", line)
            if match:
                names.add(match.group(1))
    return len(names), {f"bundler:{name}" for name in names}


MANIFEST_PARSERS: dict[str, ManifestParser] = {
    "package.json": parse_package_json,
    "pyproject.toml": parse_pyproject,
    "go.mod": parse_go_mod,
    "Cargo.toml": parse_cargo_toml,
    "composer.json": parse_composer_json,
    "Gemfile": parse_gemfile,
}

LOCK_PARSERS: dict[str, tuple[str, LockParser]] = {
    "package-lock.json": ("npm", parse_package_lock),
    "Cargo.lock": ("cargo", parse_cargo_lock),
    "composer.lock": ("composer", parse_composer_lock),
    "Gemfile.lock": ("bundler", parse_gemfile_lock),
}


def manifest_parser_for(name: str) -> ManifestParser | None:
    if name.startswith("requirements") and name.endswith(".txt"):
        return parse_requirements
    return MANIFEST_PARSERS.get(name)


def parse_manifest_file(path: Path, root: Path) -> ManifestParseResult:
    parser = manifest_parser_for(path.name)
    if parser is None:
        return None, set(), set()
    return parser(path, root)


def parse_lock_file(path: Path) -> tuple[str, int, set[str]] | None:
    lock_parser = LOCK_PARSERS.get(path.name)
    if lock_parser is None:
        return None
    ecosystem, parser = lock_parser
    locked_count, locked = parser(path)
    return ecosystem, locked_count, locked


def dependency_file_order(root: Path, files: list[Path]) -> list[Path]:
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def apply_manifest_lock_counts(
    root: Path,
    manifests: list[dict[str, Any]],
    lock_counts_by_dir: dict[tuple[str, str], int],
) -> None:
    for record in manifests:
        manifest_path = root / record["path"]
        key = (str(manifest_path.parent), str(record["ecosystem"]))
        if key in lock_counts_by_dir:
            record["locked"] = max(int(record.get("locked", 0)), lock_counts_by_dir[key])


def dependency_summary(
    manifests: list[dict[str, Any]],
    direct_names: set[str],
    locked_names: set[str],
) -> dict[str, Any]:
    ecosystems = sorted({str(record["ecosystem"]) for record in manifests})
    direct_count = len(direct_names)
    locked_count = len(locked_names)
    return {
        "direct": direct_count,
        "locked": locked_count,
        "total": max(direct_count, locked_count),
        "ecosystems": ecosystems,
        "manifests": manifests,
    }


def collect_dependencies(root: Path, files: list[Path]) -> dict[str, Any]:
    manifests: list[dict[str, Any]] = []
    direct_names: set[str] = set()
    locked_names: set[str] = set()
    lock_counts_by_dir: dict[tuple[str, str], int] = {}

    for path in dependency_file_order(root, files):
        record, direct, locked = parse_manifest_file(path, root)
        if record is not None:
            manifests.append(record)
            direct_names.update(direct)
            locked_names.update(locked)

        lock_result = parse_lock_file(path)
        if lock_result is not None:
            ecosystem, locked_count, locked = lock_result
            lock_counts_by_dir[(str(path.parent), ecosystem)] = locked_count
            locked_names.update(locked)

    apply_manifest_lock_counts(root, manifests, lock_counts_by_dir)
    return dependency_summary(manifests, direct_names, locked_names)


def human_count(value: int) -> str:
    if value < 10_000:
        return str(value)
    if value < 1_000_000:
        return f"{value / 1000:.1f}k"
    if value < 1_000_000_000:
        return f"{value / 1_000_000:.2f}M"
    return f"{value / 1_000_000_000:.2f}G"


def width_for_text(text: str) -> int:
    return max(34, len(text) * 7 + 14)


def render_flat_badge(label: str, value: str, color: str = "#007ec6") -> str:
    label_w = width_for_text(label)
    value_w = width_for_text(value)
    total_w = label_w + value_w
    label_e = html.escape(label)
    value_e = html.escape(value)
    aria = html.escape(f"{label}: {value}")
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="20" role="img" aria-label="{aria}">
  <title>{aria}</title>
  <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
  <clipPath id="r"><rect width="{total_w}" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)"><rect width="{label_w}" height="20" fill="#555"/><rect x="{label_w}" width="{value_w}" height="20" fill="{color}"/><rect width="{total_w}" height="20" fill="url(#s)"/></g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="{label_w / 2:.1f}" y="15" fill="#010101" fill-opacity=".3">{label_e}</text><text x="{label_w / 2:.1f}" y="14">{label_e}</text>
    <text x="{label_w + value_w / 2:.1f}" y="15" fill="#010101" fill-opacity=".3">{value_e}</text><text x="{label_w + value_w / 2:.1f}" y="14">{value_e}</text>
  </g>
</svg>
'''


def render_languages_svg(languages: list[dict[str, Any]], top_n: int) -> str:
    top = languages[:top_n]
    if not top:
        return render_flat_badge("languages", "none", "#6e7781")
    displayed_total = sum(int(item["code"]) for item in top) or 1
    bar_w = 480
    svg_w = 520
    row_h = 16
    rows = (len(top) + 1) // 2
    svg_h = 48 + rows * row_h
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" role="img" aria-label="languages by lines of code">',
        "  <title>languages by lines of code</title>",
        f'  <rect width="{svg_w}" height="{svg_h}" fill="#ffffff"/>',
        f'  <rect x="20" y="10" width="{bar_w}" height="14" rx="3" fill="#eaecef"/>',
    ]
    x = 20
    for index, item in enumerate(top):
        width = max(1, int(int(item["code"]) * bar_w / displayed_total))
        if index == len(top) - 1:
            width = max(1, 20 + bar_w - x)
        parts.append(
            f'  <rect x="{x}" y="10" width="{width}" height="14" fill="{item["color"]}"/>'
        )
        x += width
    for index, item in enumerate(top):
        col = index % 2
        row = index // 2
        base_x = 20 + col * 250
        base_y = 44 + row * row_h
        pct = float(item["percentage"])
        name = html.escape(str(item["name"]))
        parts.append(f'  <rect x="{base_x}" y="{base_y - 10}" width="10" height="10" rx="2" fill="{item["color"]}"/>')
        parts.append(
            f'  <text x="{base_x + 14}" y="{base_y}" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11" fill="#24292f">{name} <tspan fill="#57606a">{pct:.1f}%</tspan></text>'
        )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def render_markdown(metrics: dict[str, Any]) -> str:
    summary = metrics["summary"]
    deps = metrics["dependencies"]
    lines = [
        "<!-- aidevops:repo-metrics:start -->",
        "# Repository metrics",
        "",
        "Generated by `aidevops metrics generate`.",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Source files | {summary['source_files']:,} |",
        f"| Lines of code | {summary['code']:,} |",
        f"| Comment lines | {summary['comments']:,} |",
        f"| Blank lines | {summary['blanks']:,} |",
        f"| Languages | {summary['languages']:,} |",
        f"| Direct dependencies | {deps['direct']:,} |",
        f"| Locked/total dependencies | {deps['total']:,} |",
        "",
        "## Languages",
        "",
        "| Language | Code lines | Files | Share |",
        "|---|---:|---:|---:|",
    ]
    for item in metrics["languages"]:
        lines.append(
            f"| {item['name']} | {int(item['code']):,} | {int(item['files']):,} | {float(item['percentage']):.1f}% |"
        )
    lines.extend(["", "## Dependency manifests", "", "| Ecosystem | Manifest | Direct | Locked |", "|---|---|---:|---:|"])
    if deps["manifests"]:
        for item in deps["manifests"]:
            lines.append(
                f"| {item['ecosystem']} | `{item['path']}` | {int(item['direct']):,} | {int(item['locked']):,} |"
            )
    else:
        lines.append("| none detected | — | 0 | 0 |")
    lines.extend(
        [
            "",
            "Refresh policy: run locally when needed, or use the managed weekly/24h-fresh workflow. The scanner uses git-tracked/unignored files and does not contact external services by default.",
            "<!-- aidevops:repo-metrics:end -->",
            "",
        ]
    )
    return "\n".join(lines)


def build_metrics(root: Path, paths: list[Path], excludes: list[str], top_n: int) -> dict[str, Any]:
    files = list_repo_files(root, paths, excludes)
    languages, totals = collect_languages(root, files)
    dependencies = collect_dependencies(root, files)
    generated_at = _dt.datetime.now(tz=_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    summary = {
        **totals,
        "dependencies": dependencies["total"],
    }
    slug = git_remote_slug(root)
    repo_name = slug.split("/", 1)[1] if "/" in slug else root.name
    return {
        "schema": "aidevops.repo-metrics.v1",
        "schema_version": 1,
        "generated_at": generated_at,
        "tool": {"name": "aidevops repo-metrics", "version": TOOL_VERSION},
        "repo": {"name": repo_name, "slug": slug},
        "summary": summary,
        "languages": languages,
        "dependencies": dependencies,
        "refresh": {
            "default_policy": "weekly scheduled refresh plus manual runs; skip generated outputs younger than 24h in managed workflows",
            "cost_profile": "fast local git/unignored-file scan; no network by default",
            "top_languages": top_n,
        },
    }


def loc_summary(metrics: dict[str, Any], top_n: int) -> dict[str, Any]:
    summary = metrics["summary"]
    languages = metrics["languages"]
    return {
        "total": {
            "code": summary["code"],
            "comments": summary["comments"],
            "blanks": summary["blanks"],
            "files": summary["source_files"],
        },
        "languages": [
            {"name": item["name"], "code": item["code"], "files": item["files"]} for item in languages
        ],
        "top": [
            {"name": item["name"], "code": item["code"], "files": item["files"]}
            for item in languages[:top_n]
        ],
    }


def resolve_output(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def outputs_fresh(json_path: Path, badge_dir: Path, legacy_badge_dir: Path | None, max_age_hours: float | None) -> bool:
    if max_age_hours is None:
        return False
    required = [json_path, json_path.with_suffix(".md"), badge_dir / "loc.svg", badge_dir / "languages.svg", badge_dir / "dependencies.svg"]
    if legacy_badge_dir is not None:
        required.extend([legacy_badge_dir / "loc-total.svg", legacy_badge_dir / "loc-languages.svg"])
    if any(not item.exists() for item in required):
        return False
    age_seconds = _dt.datetime.now().timestamp() - json_path.stat().st_mtime
    return age_seconds < max_age_hours * 3600


def write_outputs(metrics: dict[str, Any], output_dir: Path, badge_dir: Path, legacy_badge_dir: Path | None, top_n: int) -> None:
    json_path = output_dir / "repo-metrics.json"
    md_path = output_dir / "repo-metrics.md"
    badge_dir.mkdir(parents=True, exist_ok=True)
    write_text(json_path, json.dumps(metrics, indent=2, sort_keys=False) + "\n")
    write_text(md_path, render_markdown(metrics))

    total_code = int(metrics["summary"]["code"])
    deps = metrics["dependencies"]
    write_text(badge_dir / "loc.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
    write_text(badge_dir / "languages.svg", render_languages_svg(metrics["languages"], top_n))
    dep_value = f"{int(deps['direct'])} direct" if int(deps["total"]) == int(deps["direct"]) else f"{int(deps['direct'])}/{int(deps['total'])}"
    write_text(badge_dir / "dependencies.svg", render_flat_badge("dependencies", dep_value, "#4c1"))

    write_text(badge_dir / "loc-total.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
    write_text(badge_dir / "loc-languages.svg", render_languages_svg(metrics["languages"], top_n))
    if legacy_badge_dir is not None:
        legacy_badge_dir.mkdir(parents=True, exist_ok=True)
        write_text(legacy_badge_dir / "loc-total.svg", render_flat_badge("lines of code", human_count(total_code), "#007ec6"))
        write_text(legacy_badge_dir / "loc-languages.svg", render_languages_svg(metrics["languages"], top_n))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate local repository metrics and README badge assets")
    parser.add_argument("paths", nargs="*", default=["."], help="repository or sub-paths to scan")
    parser.add_argument("--output-dir", default="docs/metrics", help="directory for repo-metrics.json/md")
    parser.add_argument("--badge-dir", default="", help="directory for SVG badges (default: OUTPUT_DIR/badges)")
    parser.add_argument("--legacy-badge-dir", default="", help="optional legacy .github/badges output directory")
    parser.add_argument("--top", type=int, default=6, help="top-N languages for stacked language badge")
    parser.add_argument("--exclude", action="append", default=[], help="extra path or glob pattern to exclude")
    parser.add_argument("--json-only", action="store_true", help="print full metrics JSON without writing files")
    parser.add_argument("--loc-summary-json", action="store_true", help="print legacy LOC summary JSON without writing files")
    parser.add_argument("--skip-if-fresh-hours", type=float, default=None, help="skip writes when outputs are newer than this age")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    scan_paths = [Path(item).expanduser() for item in args.paths]
    first_path = scan_paths[0] if scan_paths else Path(".")
    root = repo_root(first_path.resolve())
    excludes = list(DEFAULT_EXCLUDES) + list(args.exclude or [])
    output_dir = resolve_output(root, args.output_dir)
    badge_dir = resolve_output(root, args.badge_dir) if args.badge_dir else output_dir / "badges"
    legacy_badge_dir = resolve_output(root, args.legacy_badge_dir) if args.legacy_badge_dir else None
    json_path = output_dir / "repo-metrics.json"

    if not args.json_only and not args.loc_summary_json and outputs_fresh(json_path, badge_dir, legacy_badge_dir, args.skip_if_fresh_hours):
        print(f"repo metrics fresh: {json_path}", file=sys.stderr)
        return 0

    metrics = build_metrics(root, scan_paths, excludes, max(args.top, 1))
    if args.loc_summary_json:
        print(json.dumps(loc_summary(metrics, max(args.top, 1)), indent=2, sort_keys=False))
        return 0
    if args.json_only:
        print(json.dumps(metrics, indent=2, sort_keys=False))
        return 0

    write_outputs(metrics, output_dir, badge_dir, legacy_badge_dir, max(args.top, 1))
    print(f"repo metrics written: {json_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

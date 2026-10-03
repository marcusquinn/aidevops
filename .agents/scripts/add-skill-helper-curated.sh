#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Registry-owned curated imports. Sourced by add-skill-helper-import.sh.

has_curated_policy() {
	local name="$1"
	local url="${2:-}"
	[[ -f "$SKILL_SOURCES" ]] || return 1
	jq -e --arg name "$name" --arg url "$url" '.skills[] | select(.name == $name and .import_policy != null and ($url == "" or .upstream_url == $url))' "$SKILL_SOURCES" >/dev/null
	return $?
}

# Stage the complete mapping before touching installed files. Never prune unknown
# files: setup owns the explicit historical retirement list, not the importer.
install_curated_tree() {
	local source_dir="$1"
	local name="$2"
	local stage_dir="$3"
	local commit="${4:-}"
	bash "${SCRIPT_DIR}/add-skill-helper-curated.sh" "$SKILL_SOURCES" "$AGENTS_DIR" "$source_dir" "$name" "$stage_dir" "$commit"
	return $?
}

# Run the deterministic transposer only as a subprocess, not while sourcing the
# command library. Keeping it outside a shell function also keeps shell complexity
# measurements about executable shell control flow rather than embedded Python.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	python3 - "$@" <<'PY'
import fnmatch
import json
import posixpath
import re
import shutil
import sys
from pathlib import Path

registry, agents, source, name, stage, commit = sys.argv[1:]
agents, source, stage = (Path(p).resolve() for p in (agents, source, stage))
entry = next(s for s in json.loads(Path(registry).read_text())["skills"] if s["name"] == name)
policy = entry["import_policy"]
if policy.get("version") != 1:
    raise ValueError("Unsupported curated import policy version")

def safe_path(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts or not path.resolve().is_relative_to(root):
        raise ValueError("Curated import path escapes root: " + relative)
    return path

index = entry["local_path"].removeprefix(".agents/")
safe_path(agents, index)
resources = policy["resource_path"]
mapping = {}
for rule in policy["rules"]:
    for path in sorted(source.glob(rule["include"])):
        relative = path.relative_to(source).as_posix()
        if relative in mapping or not path.is_file() or any(fnmatch.fnmatchcase(relative, p) for p in policy["exclude"]):
            continue
        safe_path(source, relative)
        suffix = path.relative_to(source / rule["root"]).as_posix()
        suffix = rule.get("rename", {}).get(suffix, suffix)
        suffix = suffix.removeprefix("references/")
        if rule.get("rename_readme") and suffix.endswith("/README.md"):
            suffix = suffix.removesuffix("/README.md") + ".md"
        if suffix == "SKILL.md" or suffix == "index.md":
            suffix = ""
        suffix = suffix.removesuffix(".md").replace("/", "-").lower()
        target = (rule["prefix"] + suffix).rstrip("-") + ".md"
        target = rule.get("targets", {}).get(relative, target)
        destination = index if relative == policy["index_source"] else resources + "/" + target
        safe_path(agents, destination)
        if destination in mapping.values():
            raise ValueError("Colliding curated target: " + destination)
        mapping[relative] = destination
if policy["index_source"] not in mapping:
    raise ValueError("Missing curated index source")

# Alias copies in upstream routers point to the canonical selected chapters.
aliases = dict(mapping)
for prefix, replacement in policy.get("link_aliases", {}).items():
    for relative, destination in mapping.items():
        if relative.startswith(replacement):
            alias = prefix + relative[len(replacement):]
            aliases[alias.replace("/SKILL.md", "/REFERENCE.md")] = destination

def transpose(text, relative, destination):
    def link(match):
        href = match.group(1)
        if re.match(r"[a-zA-Z]+:", href) or href.startswith(("#", "/")):
            return match.group(0)
        path, separator, fragment = href.partition("#")
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), path))
        if resolved in aliases:
            href = posixpath.relpath(aliases[resolved], posixpath.dirname(destination))
        else:
            # Trimmed references stay readable upstream instead of breaking locally.
            href = f'{entry["upstream_url"]}/blob/{commit or entry["upstream_commit"]}/{resolved}'
        return f"({href}{separator}{fragment})"
    text = re.sub(r"\(([^\s()]+\.md(?:#[^\s()]*)?)\)", link, text)
    lines, fenced = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            if not fenced and line.strip() == "```":
                line = line.rstrip() + "text"
            if not fenced and lines and lines[-1]:
                lines.append("")
            fenced = not fenced
            lines.append(line)
            if not fenced:
                lines.append("")
            continue
        if not fenced and re.match(r"^#{1,6} ", line):
            if lines and lines[-1]:
                lines.append("")
            lines.extend([line.rstrip(), ""])
            continue
        if line.endswith("  ") and not fenced:
            line = line.rstrip() + "<br>"
        if not fenced:
            line = re.sub(r"(?<=\s)\*(?=\))", r"`*`", line)
            if not line.strip() and (not lines or not lines[-1]):
                continue
        # Upstream mixes spaces and tabs in some examples; normalize presentation.
        lines.append(line.expandtabs(2).rstrip())
    return "\n".join(lines).rstrip() + "\n"

for relative, destination in mapping.items():
    text = transpose(safe_path(source, relative).read_text(), relative, destination)
    if destination == index:
        existing = safe_path(agents, index)
        marker = policy["preserve_before"]
        if existing.exists():
            original = existing.read_text()
            if marker not in original:
                raise ValueError("Missing local integration boundary: " + marker)
            prefix = original.split(marker, 1)[0].rstrip()
        else:
            prefix = "---\nmode: subagent\nimported_from: external\n---\n\n# " + name
        text = re.sub(r"\A---\n.*?\n---\n", "", text, count=1, flags=re.S).lstrip()
        text = prefix + "\n\n" + marker + "\n\n" + text
    staged = safe_path(stage, destination)
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_text(text)

# All targets are validated before the first install; unrelated custom files survive.
for destination in mapping.values():
    target = safe_path(agents, destination)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(safe_path(stage, destination), target)
print("Curated import: " + str(len(mapping)) + " files; policy v1; unknown files preserved")
PY
	exit $?
fi

import_curated_skill() {
	local url="$1"
	local name="$2"
	local dry_run="$3"
	local skip_security="$4"
	local force="$5"
	local temp_dir="" commit="" registry_tmp=""
	local local_path=""
	local_path=$(jq -r --arg name "$name" '.skills[] | select(.name == $name) | .local_path' "$SKILL_SOURCES")
	if [[ "$force" != true && "$dry_run" != true && -e "$AGENTS_DIR/${local_path#.agents/}" ]]; then
		log_error "Curated skill already installed (use --force): $name"
		return 1
	fi
	temp_dir=$(mktemp -d)
	if ! git clone --depth 1 "$url" "$temp_dir/repo"; then
		rm -rf "$temp_dir"
		return 1
	fi
	if [[ "$dry_run" == true ]]; then
		log_info "DRY RUN: curated registry policy for $name"
		rm -rf "$temp_dir"
		return 0
	fi
	# Keep the scanner boundary ahead of all installed-file mutation.
	if ! scan_skill_security "$temp_dir/repo" "$name" "$skip_security"; then
		rm -rf "$temp_dir"
		return 1
	fi
	if ! commit=$(git -C "$temp_dir/repo" rev-parse HEAD); then
		rm -rf "$temp_dir"
		return 1
	fi
	if ! install_curated_tree "$temp_dir/repo" "$name" "$temp_dir/stage" "$commit"; then
		rm -rf "$temp_dir"
		return 1
	fi
	registry_tmp=$(mktemp)
	if ! jq --arg name "$name" --arg commit "$commit" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '(.skills[] | select(.name == $name)) |= (.upstream_commit = $commit | .last_checked = $timestamp | .format_detected = "skill-md-curated")' "$SKILL_SOURCES" >"$registry_tmp"; then
		rm -rf "$temp_dir"
		rm -f "$registry_tmp"
		return 1
	fi
	mv "$registry_tmp" "$SKILL_SOURCES"
	rm -rf "$temp_dir"
	return 0
}

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Sync Tabby terminal profiles from aidevops repos.json.

Creates a profile for each registered repo with:
- Unique bright tab colour (dark-mode friendly)
- Matching built-in Tabby colour scheme (closest hue)
- TABBY_AUTORUN=opencode env var for TUI compatibility
- Grouped under "Projects"

Existing profiles (matched by cwd path) are never overwritten.
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import os
import re
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# Curated dark-mode colour schemes shipped with Tabby
# Each entry: (name, dominant_hue_degrees, foreground, background, cursor, 16_ansi_colours)
# Hue is approximate dominant accent hue (0-360) for matching.
# ---------------------------------------------------------------------------
DARK_SCHEMES = [
    {
        "name": "Tabby Default",
        "hue": 200,
        "foreground": "#cacaca",
        "background": "#171717",
        "cursor": "#bbbbbb",
        "colors": [
            "#000000", "#ff615a", "#b1e969", "#ebd99c",
            "#5da9f6", "#e86aff", "#82fff7", "#dedacf",
            "#90a4ae", "#f58c80", "#ddf88f", "#eee5b2",
            "#a5c7ff", "#ddaaff", "#b7fff9", "#ffffff",
        ],
    },
    {
        "name": "Night Owl",
        "hue": 210,
        "foreground": "#d6deeb",
        "background": "#011627",
        "cursor": "#80a4c2",
        "colors": [
            "#011627", "#ef5350", "#22da6e", "#addb67",
            "#82aaff", "#c792ea", "#21c7a8", "#ffffff",
            "#969696", "#ef5350", "#22da6e", "#ffeb95",
            "#82aaff", "#c792ea", "#7fdbca", "#ffffff",
        ],
    },
    {
        "name": "TokyoNight",
        "hue": 230,
        "foreground": "#c0caf5",
        "background": "#1a1b26",
        "cursor": "#c0caf5",
        "colors": [
            "#15161e", "#f7768e", "#9ece6a", "#e0af68",
            "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
            "#414868", "#f7768e", "#9ece6a", "#e0af68",
            "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
        ],
    },
    {
        "name": "Rose Pine Moon",
        "hue": 260,
        "foreground": "#e0def4",
        "background": "#232136",
        "cursor": "#59546d",
        "colors": [
            "#393552", "#eb6f92", "#3e8fb0", "#f6c177",
            "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4",
            "#817c9c", "#eb6f92", "#3e8fb0", "#f6c177",
            "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4",
        ],
    },
    {
        "name": "Dracula",
        "hue": 265,
        "foreground": "#f8f8f2",
        "background": "#282a36",
        "cursor": "#f8f8f2",
        "colors": [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
            "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
            "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
        ],
    },
    {
        "name": "Cobalt Neon",
        "hue": 150,
        "foreground": "#8ff586",
        "background": "#142838",
        "cursor": "#c4206f",
        "colors": [
            "#142631", "#ff2320", "#3ba5ff", "#e9e75c",
            "#8ff586", "#781aa0", "#8ff586", "#ba46b2",
            "#fff688", "#d4312e", "#8ff586", "#e9f06d",
            "#3c7dd2", "#8230a7", "#6cbc67", "#8ff586",
        ],
    },
    {
        "name": "Tomorrow Night Bright",
        "hue": 0,
        "foreground": "#eaeaea",
        "background": "#000000",
        "cursor": "#eaeaea",
        "colors": [
            "#000000", "#d54e53", "#b9ca4a", "#e7c547",
            "#7aa6da", "#c397d8", "#70c0b1", "#ffffff",
            "#000000", "#d54e53", "#b9ca4a", "#e7c547",
            "#7aa6da", "#c397d8", "#70c0b1", "#ffffff",
        ],
    },
    {
        "name": "Belafonte Night",
        "hue": 25,
        "foreground": "#968c83",
        "background": "#20111b",
        "cursor": "#968c83",
        "colors": [
            "#20111b", "#be100e", "#858162", "#eaa549",
            "#426a79", "#97522c", "#989a9c", "#968c83",
            "#5e5252", "#be100e", "#858162", "#eaa549",
            "#426a79", "#97522c", "#989a9c", "#d5ccba",
        ],
    },
    {
        "name": "AtelierSulphurpool",
        "hue": 220,
        "foreground": "#979db4",
        "background": "#202746",
        "cursor": "#979db4",
        "colors": [
            "#202746", "#c94922", "#ac9739", "#c08b30",
            "#3d8fd1", "#6679cc", "#22a2c9", "#979db4",
            "#6b7394", "#c76b29", "#293256", "#5e6687",
            "#898ea4", "#dfe2f1", "#9c637a", "#f5f7ff",
        ],
    },
    {
        "name": "Floraverse",
        "hue": 290,
        "foreground": "#dbd1b9",
        "background": "#0e0d15",
        "cursor": "#bbbbbb",
        "colors": [
            "#08002e", "#64002c", "#5d731a", "#cd751c",
            "#1d6da1", "#b7077e", "#42a38c", "#f3e0b8",
            "#331e4d", "#d02063", "#b4ce59", "#fac357",
            "#40a4cf", "#f12aae", "#62caa8", "#fff5db",
        ],
    },
    {
        "name": "Square",
        "hue": 340,
        "foreground": "#acacab",
        "background": "#1a1a1a",
        "cursor": "#fcfbcc",
        "colors": [
            "#050505", "#e9897c", "#b6377d", "#ecebbe",
            "#a9cdeb", "#75507b", "#c9caec", "#f2f2f2",
            "#141414", "#f99286", "#c3f786", "#fcfbcc",
            "#b6defb", "#ad7fa8", "#d7d9fc", "#e2e2e2",
        ],
    },
    {
        "name": "base2tone-cave-dark",
        "hue": 45,
        "foreground": "#9f999b",
        "background": "#222021",
        "cursor": "#996e00",
        "colors": [
            "#222021", "#936c7a", "#cca133", "#ffcc4d",
            "#9c818b", "#cca133", "#d27998", "#9f999b",
            "#635f60", "#ddaf3c", "#2f2d2e", "#565254",
            "#706b6d", "#f0a8c1", "#c39622", "#ffebf2",
        ],
    },
    {
        "name": "base2tone-space-dark",
        "hue": 20,
        "foreground": "#a1a1b5",
        "background": "#24242e",
        "cursor": "#b25424",
        "colors": [
            "#24242e", "#7676f4", "#ec7336", "#fe8c52",
            "#767693", "#ec7336", "#8a8aad", "#a1a1b5",
            "#5b5b76", "#f37b3f", "#333342", "#515167",
            "#737391", "#cecee3", "#e66e33", "#ebebff",
        ],
    },
    {
        "name": "base2tone-forest-dark",
        "hue": 120,
        "foreground": "#a1b5a1",
        "background": "#2a2d2a",
        "cursor": "#656b47",
        "colors": [
            "#2a2d2a", "#5c705c", "#bfd454", "#e5fb79",
            "#687d68", "#bfd454", "#8fae8f", "#a1b5a1",
            "#535f53", "#cbe25a", "#353b35", "#485148",
            "#5e6e5e", "#c8e4c8", "#b1c44f", "#f0fff0",
        ],
    },
    {
        "name": "Catppuccin Mocha",
        "hue": 250,
        "foreground": "#cdd6f4",
        "background": "#1e1e2e",
        "cursor": "#f5e0dc",
        "colors": [
            "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
            "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
            "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
            "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
        ],
    },
    {
        "name": "Gruvbox Dark",
        "hue": 40,
        "foreground": "#ebdbb2",
        "background": "#282828",
        "cursor": "#ebdbb2",
        "colors": [
            "#282828", "#cc241d", "#98971a", "#d79921",
            "#458588", "#b16286", "#689d6a", "#a89984",
            "#928374", "#fb4934", "#b8bb26", "#fabd2f",
            "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
        ],
    },
    {
        "name": "Nord",
        "hue": 210,
        "foreground": "#d8dee9",
        "background": "#2e3440",
        "cursor": "#d8dee9",
        "colors": [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
        ],
    },
    {
        "name": "Solarized Dark",
        "hue": 190,
        "foreground": "#839496",
        "background": "#002b36",
        "cursor": "#839496",
        "colors": [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ],
    },
    {
        "name": "One Dark",
        "hue": 220,
        "foreground": "#abb2bf",
        "background": "#282c34",
        "cursor": "#528bff",
        "colors": [
            "#282c34", "#e06c75", "#98c379", "#e5c07b",
            "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#545862", "#e06c75", "#98c379", "#e5c07b",
            "#61afef", "#c678dd", "#56b6c2", "#c8ccd4",
        ],
    },
    {
        "name": "Monokai",
        "hue": 55,
        "foreground": "#f8f8f2",
        "background": "#272822",
        "cursor": "#f8f8f2",
        "colors": [
            "#272822", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
            "#75715e", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
        ],
    },
]


def hex_to_hsl(hex_color: str) -> tuple[float, float, float]:
    """Convert hex colour to HSL (hue 0-360, sat 0-1, light 0-1)."""
    hex_color = hex_color.lstrip("#")
    r, g, b = (int(hex_color[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    h, lightness, s = colorsys.rgb_to_hls(r, g, b)
    return h * 360, s, lightness


def hsl_to_hex(h: float, s: float, lightness: float) -> str:
    """Convert HSL (hue 0-360, sat 0-1, light 0-1) to hex."""
    r, g, b = colorsys.hls_to_rgb(h / 360.0, lightness, s)
    return "#{:02X}{:02X}{:02X}".format(int(r * 255), int(g * 255), int(b * 255))


def hue_distance(h1: float, h2: float) -> float:
    """Circular distance between two hues (0-180)."""
    d = abs(h1 - h2) % 360
    return min(d, 360 - d)


def generate_tab_colour(repo_path: str) -> str:
    """Generate a deterministic bright colour from repo path.

    Uses a hash of the path to pick a hue, then constrains
    saturation (60-90%) and lightness (50-70%) for dark-mode visibility.
    """
    h = int(hashlib.sha256(repo_path.encode()).hexdigest()[:8], 16)
    hue = h % 360
    # Use different bits for saturation and lightness variation
    sat = 0.60 + (((h >> 8) % 31) / 100.0)  # 0.60 - 0.90
    lit = 0.50 + (((h >> 16) % 21) / 100.0)  # 0.50 - 0.70
    return hsl_to_hex(hue, sat, lit)


def find_closest_scheme(tab_colour_hex: str) -> dict:
    """Find the built-in scheme whose dominant hue is closest to the tab colour."""
    tab_hue, _, _ = hex_to_hsl(tab_colour_hex)
    best = None
    best_dist = 999
    for scheme in DARK_SCHEMES:
        dist = hue_distance(tab_hue, scheme["hue"])
        if dist < best_dist:
            best_dist = dist
            best = scheme
    return best


def profile_name_from_path(repo_path: str) -> str:
    """Derive a profile name from the repo path.

    Uses the last path component, or last two if nested (e.g., cloudron/netbird-app).
    """
    parts = Path(repo_path).parts
    if len(parts) >= 2:
        parent = parts[-2]
        name = parts[-1]
        # If parent is a grouping dir (not Git or home), include it
        if parent.lower() not in ("git", "repos", "projects", "src", "code",
                                   os.path.basename(os.path.expanduser("~"))):
            return f"{parent}/{name}"
    return Path(repo_path).name


def load_yaml_simple(path: str) -> str:
    """Load file content as string."""
    with open(path, "r") as f:
        return f.read()


def save_yaml(path: str, content: str) -> None:
    """Save content to file."""
    with open(path, "w") as f:
        f.write(content)


def extract_existing_cwds(config_text: str) -> set[str]:
    """Extract all cwd paths from existing profiles."""
    cwds = set()
    # Match cwd: lines in profile blocks
    for match in re.finditer(r"^\s+cwd:\s+(.+)$", config_text, re.MULTILINE):
        cwd = match.group(1).strip().strip("'\"")
        cwds.add(cwd)
    return cwds


def extract_group_id(config_text: str) -> str | None:
    """Find the 'Projects' group ID, or return None."""
    # Look for groups section — capture all indented content after "groups:"
    groups_match = re.search(
        r"^groups:\s*\n((?:[ \t]+.*\n)*)", config_text, re.MULTILINE
    )
    if not groups_match:
        return None

    # Parse group entries by accumulating blocks (each starts with "  - ")
    group_block = groups_match.group(1)
    blocks: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in group_block.split("\n"):
        if not line.strip():
            continue
        # New group entry starts with "  - " (list item)
        if re.match(r"\s+-\s+", line):
            if current:
                blocks.append(current)
            current = {}
            # The first field may be on the same line as "-"
            line = re.sub(r"^\s+-\s+", "  ", line)
        # Extract key: value pairs
        kv_match = re.match(r"\s+(\w+):\s+(.+)", line)
        if kv_match:
            current[kv_match.group(1)] = kv_match.group(2).strip().strip("'\"")
    if current:
        blocks.append(current)

    # Find the "Projects" group
    for block in blocks:
        if block.get("name") == "Projects" and "id" in block:
            return block["id"]
    return None


def build_profile_yaml(
    name: str,
    cwd: str,
    tab_colour: str,
    scheme: dict,
    group_id: str,
) -> str:
    """Build a YAML profile block as a string."""
    profile_id = f"local:custom:{name.replace('/', '-')}:{uuid.uuid4()}"

    # Build colour list
    colours_yaml = ""
    for c in scheme["colors"]:
        colours_yaml += f"        - '{c}'\n"

    profile = f"""  - name: {name}
    icon: fas fa-terminal
    options:
      command: /bin/zsh
      args:
        - '-l'
        - '-i'
      env:
        TABBY_AUTORUN: opencode
      cwd: {cwd}
    terminalColorScheme:
      name: {scheme['name']}
      foreground: '{scheme['foreground']}'
      background: '{scheme['background']}'
      cursor: '{scheme['cursor']}'
      colors:
{colours_yaml.rstrip()}
    color: '{tab_colour}'
    id: {profile_id}
    group: {group_id}
    type: local"""

    return profile


def build_group_yaml(group_id: str) -> str:
    """Build a YAML group block."""
    return f"""  - id: {group_id}
    name: Projects"""


def ensure_groups_section(config_text: str, group_id: str) -> str:
    """Ensure the groups section exists with a Projects group."""
    if re.search(r"^groups:", config_text, re.MULTILINE):
        # Check if Projects group exists
        existing_id = extract_group_id(config_text)
        if existing_id:
            return config_text  # Already has Projects group
        # Add Projects group to existing groups section
        group_entry = build_group_yaml(group_id)
        config_text = re.sub(
            r"^(groups:\s*\n)",
            f"\\1{group_entry}\n",
            config_text,
            count=1,
            flags=re.MULTILINE,
        )
    else:
        # Add groups section before the first non-profile top-level key
        # or at the end
        group_section = f"groups:\n{build_group_yaml(group_id)}\n"
        # Insert before configSync, hotkeys, terminal, ssh, etc.
        for key in ("configSync:", "hotkeys:", "terminal:", "ssh:", "clickableLinks:"):
            if key in config_text:
                config_text = config_text.replace(key, f"{group_section}{key}", 1)
                return config_text
        # Fallback: append
        config_text += f"\n{group_section}"
    return config_text


def get_repos(repos_json_path: str) -> list[dict]:
    """Load repos from repos.json, filtering to those suitable for profiles."""
    with open(repos_json_path) as f:
        data = json.load(f)

    repos = data.get("initialized_repos", [])
    result = []
    for repo in repos:
        path = repo.get("path", "")
        # Skip repos without a path
        if not path:
            continue
        # Expand ~ in path
        path = os.path.expanduser(path)
        # Skip repos that don't exist on disk
        if not os.path.isdir(path):
            continue
        # Skip worktree paths (contain dots suggesting branch names like repo.feature-name)
        basename = os.path.basename(path)
        if "." in basename and "-" in basename.split(".", 1)[1]:
            # Heuristic: worktrees have patterns like "repo.feature-branch-name"
            # But repos like "essentials.com" are valid — check if it looks like a branch
            after_dot = basename.split(".", 1)[1]
            if "/" in after_dot or after_dot.startswith(("feature-", "bugfix-", "hotfix-",
                                                          "refactor-", "chore-", "experiment-")):
                continue
        result.append({"path": path, "name": profile_name_from_path(path), "repo": repo})
    return result


def main():
    parser = argparse.ArgumentParser(description="Sync Tabby profiles from repos.json")
    parser.add_argument("--repos-json", required=True, help="Path to repos.json")
    parser.add_argument("--tabby-config", required=True, help="Path to Tabby config.yaml")
    parser.add_argument("--status-only", action="store_true", help="Show status without modifying")
    args = parser.parse_args()

    repos = get_repos(args.repos_json)
    config_text = load_yaml_simple(args.tabby_config)
    existing_cwds = extract_existing_cwds(config_text)

    if args.status_only:
        print(f"Repos in repos.json: {len(repos)}")
        has_profile = 0
        needs_profile = 0
        for repo in repos:
            if repo["path"] in existing_cwds:
                has_profile += 1
                print(f"  [exists] {repo['name']} -> {repo['path']}")
            else:
                needs_profile += 1
                print(f"  [new]    {repo['name']} -> {repo['path']}")
        print(f"\nExisting: {has_profile}, New: {needs_profile}")
        if needs_profile > 0:
            print("Note: existing profiles are never modified — only new ones are created.")
        return

    # Determine group ID
    group_id = extract_group_id(config_text)
    if not group_id:
        group_id = str(uuid.uuid4())
        config_text = ensure_groups_section(config_text, group_id)

    # Find new repos that need profiles
    new_profiles = []
    for repo in repos:
        if repo["path"] not in existing_cwds:
            tab_colour = generate_tab_colour(repo["path"])
            scheme = find_closest_scheme(tab_colour)
            profile_yaml = build_profile_yaml(
                name=repo["name"],
                cwd=repo["path"],
                tab_colour=tab_colour,
                scheme=scheme,
                group_id=group_id,
            )
            new_profiles.append((repo, profile_yaml, tab_colour, scheme["name"]))

    if not new_profiles:
        print("All repos already have Tabby profiles. Nothing to do.")
        return

    # Insert new profiles into the profiles section
    lines = config_text.split("\n")
    has_profiles_key = False
    in_profiles = False
    insert_line = None
    for i, line in enumerate(lines):
        if re.match(r"^profiles:", line):
            has_profiles_key = True
            in_profiles = True
            continue
        if in_profiles and re.match(r"^[a-zA-Z]", line):
            # This is the next top-level key after profiles
            insert_line = i
            break

    # Build the new profiles block
    new_block = "\n".join(p[1] for p in new_profiles)

    if not has_profiles_key:
        # No profiles section exists — create one at the top of the file
        # (after version: line if present, otherwise at the very top)
        version_line = None
        for i, line in enumerate(lines):
            if re.match(r"^version:", line):
                version_line = i
                break
        insert_at = (version_line + 1) if version_line is not None else 0
        lines.insert(insert_at, f"profiles:\n{new_block}")
    else:
        if insert_line is None:
            # Profiles section goes to end of file — insert before EOF
            insert_line = len(lines)
        lines.insert(insert_line, new_block)

    config_text = "\n".join(lines)

    # Save
    save_yaml(args.tabby_config, config_text)

    # Report
    print(f"Created {len(new_profiles)} new Tabby profile(s):")
    for repo, _, colour, scheme_name in new_profiles:
        print(f"  + {repo['name']} (colour: {colour}, scheme: {scheme_name})")


if __name__ == "__main__":
    main()

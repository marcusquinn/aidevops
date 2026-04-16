#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Colour utilities for tabby-profile-sync.py.

Extracted from tabby-profile-sync.py to reduce file complexity.
Provides tab colour generation and colour scheme matching.
"""

from __future__ import annotations

import colorsys
import hashlib

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

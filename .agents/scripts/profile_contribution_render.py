# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pure SVG rendering for aggregate-only contribution history."""

import html


def compact(value):
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1000:
        return f"{value / 1000:.0f}K"
    return str(round(value))


def render_svg(data, dark=False):
    bg, fg, muted, grid = ("#0d1117", "#e6edf3", "#8b949e", "#30363d") if dark else ("#ffffff", "#24292f", "#57606a", "#d0d7de")
    user = html.escape(data["user"], quote=True)
    points = data["months"]
    values = [point["cumulative"] for point in points] or [0]
    maximum = max(max(values), 1)
    left, top, width, height = 76, 100, 848, 250
    coords = [(left + i * width / max(len(values) - 1, 1), top + height * (1 - value / maximum)) for i, value in enumerate(values)]
    line = " ".join(f'{"M" if i == 0 else "L"}{x:.1f},{y:.1f}' for i, (x, y) in enumerate(coords))
    area = line + f" L{coords[-1][0]:.1f},{top + height} L{left},{top + height} Z"
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="960" height="420" viewBox="0 0 960 420" role="img" aria-labelledby="title desc">',
        f'<title id="title">{user}: Total Contributions</title>',
        f'<desc id="desc">{data["total"]:,} cumulative GitHub contributions through {data["through"]}. Updated {data["updated"]} UTC.</desc>',
        '<defs><linearGradient id="area" x2="0" y2="1"><stop stop-color="#16a34a" stop-opacity=".2"/><stop offset="1" stop-color="#16a34a" stop-opacity=".02"/></linearGradient></defs>',
        f'<rect width="960" height="420" fill="{bg}"/>',
        f'<g font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" fill="{fg}">',
        '<text x="32" y="39" font-size="26" font-weight="600">Total Contributions</text>',
        f'<text x="924" y="39" text-anchor="end" font-size="26" font-weight="600">{data["total"]:,}</text>',
        f'<text x="32" y="66" font-size="14" fill="{muted}">@{user} · Cumulative monthly totals · Through {data["through"]} UTC</text>',
    ]
    for index in range(5):
        y = top + height * index / 4
        parts.extend([
            f'<path d="M{left},{y} H924" stroke="{grid}" stroke-width="1"/>',
            f'<text x="64" y="{y + 5}" text-anchor="end" font-size="13" fill="{muted}">{compact(maximum * (1 - index / 4))}</text>',
        ])
    for index in sorted({round(i * (len(points) - 1) / 5) for i in range(6)}) if points else []:
        x = coords[index][0]
        parts.append(f'<text x="{x:.1f}" y="377" text-anchor="middle" font-size="13" fill="{muted}">{points[index]["month"]}</text>')
    parts.extend([
        f'<path d="{area}" fill="url(#area)"/>',
        f'<path d="{line}" fill="none" stroke="#16a34a" stroke-width="3" stroke-linejoin="round"/>',
        f'<circle cx="{coords[-1][0]:.1f}" cy="{coords[-1][1]:.1f}" r="4" fill="#16a34a"/>',
        f'<text x="32" y="406" font-size="12" fill="{muted}">Source: GitHub · Includes all six contribution types · Updated {data["updated"]} UTC</text>',
        '</g></svg>',
    ])
    return "\n".join(parts) + "\n"

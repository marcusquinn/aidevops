<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Advanced Configuration & Styling

## Init Directive

```mermaid
%%{init: {
  'theme': 'base',
  'themeVariables': {
    'primaryColor': '#3b82f6',
    'primaryTextColor': '#ffffff',
    'primaryBorderColor': '#2563eb',
    'secondaryColor': '#10b981',
    'tertiaryColor': '#f1f5f9',
    'lineColor': '#64748b',
    'textColor': '#1e293b',
    'fontSize': '16px',
    'fontFamily': 'Inter, sans-serif'
  }
}}%%
flowchart LR
    A[Start] --> B{Decision}
    B -->|Yes| C[Success]
    B -->|No| D[Failure]
```

## Frontmatter (alternative to init)

```yaml
---
title: My Diagram
config:
  theme: forest
  flowchart:
    defaultRenderer: elk
---
```

## Theme Variables

Themes: `default`, `dark`, `forest`, `neutral`, `base` — see cheatsheet `## Styling`.

| Variable | Description |
|----------|-------------|
| `primaryColor` | Main node fill |
| `primaryTextColor` | Text in primary nodes |
| `primaryBorderColor` | Primary node border |
| `secondaryColor` | Secondary elements |
| `tertiaryColor` | Background/tertiary |
| `lineColor` | Edge/arrow color |
| `textColor` | General text |
| `background` | Diagram background |
| `fontSize` | Base font size |
| `fontFamily` | Font family |

Diagram-specific variables:
- **Flowchart:** `nodeBorder`, `nodeTextColor`, `clusterBkg`, `clusterBorder`, `edgeLabelBackground`
- **Sequence:** `actorBorder`, `actorBkg`, `actorTextColor`, `activationBorderColor`, `activationBkgColor`, `signalColor`, `signalTextColor`, `noteBkgColor`, `noteBorderColor`, `noteTextColor`
- **State:** `labelColor`, `altBackground`
- **Gantt:** `gridColor`, `todayLineColor`, `taskTextColor`, `doneTaskBkgColor`, `activeTaskBkgColor`, `critBkgColor`, `taskBorderColor`

## Class-Based Styling

```mermaid
flowchart LR
    A[Start]:::success --> B[Process]:::info --> C[End]:::warning

    classDef success fill:#10b981,stroke:#059669,color:white
    classDef info fill:#3b82f6,stroke:#2563eb,color:white
    classDef warning fill:#f59e0b,stroke:#d97706,color:white
    classDef default fill:#f8fafc,stroke:#cbd5e1
```

## Individual Node & Link Styling

```mermaid
flowchart LR
    A --> B --> C --> D

    style A fill:#10b981,stroke:#059669,color:white
    style B fill:#3b82f6,stroke:#2563eb,color:white
    style C fill:#ef4444,stroke:#dc2626,color:white

    linkStyle 0 stroke:green,stroke-width:2px
    linkStyle 1 stroke:blue,stroke-width:2px
    linkStyle default stroke:gray,stroke-width:1px
```

Properties: `fill`, `stroke`, `stroke-width`, `stroke-dasharray`, `color`, `font-weight`

## Layout & Directives

**ELK Renderer (v9.4+):** Better complex layouts, predictable edge routing, improved subgraph positioning.

```
%%{init: {
  'theme': 'default',
  'flowchart': { 'defaultRenderer': 'elk', 'curve': 'basis', 'padding': 15 },
  'sequence': { 'showSequenceNumbers': true, 'actorMargin': 50, 'boxMargin': 10 },
  'gantt': { 'barHeight': 20, 'fontSize': 11, 'sectionFontSize': 14 }
}}%%
```

Directive keys: `flowchart`, `sequenceDiagram`, `classDiagram`, `stateDiagram`, `erDiagram`, `gantt`

## Security Levels

| Level | Description |
|-------|-------------|
| `strict` | Most secure, no HTML/JS |
| `loose` | Allows some interaction |
| `antiscript` | Allows HTML, blocks scripts |
| `sandbox` | iframe sandbox |

Use `securityLevel: 'loose'` to enable `click` handlers (e.g., `click A href "https://example.com" _blank`).

## Troubleshooting

**Special characters** — escape with HTML entities or use quoted strings (see cheatsheet `## Special Characters`):

```mermaid
flowchart LR
    A["Node with #quot;quotes#quot;"]
    B["Arrow -> symbol"]
    C["Hash #35; symbol"]
```

**Long labels:**

```mermaid
flowchart LR
    A["`This is a very long
    label that wraps
    across multiple lines`"]
```

**Arrow syntax by diagram type:**

| Diagram | Sync | Async | Dotted |
|---------|------|-------|--------|
| Flowchart | `-->` | N/A | `-.->` |
| Sequence | `->>` | `-->>` | `--->` |
| Class | `-->` | N/A | `..>` |
| State | `-->` | N/A | N/A |

**Debugging:** Verify diagram type declaration; check unclosed brackets/quotes; match arrow syntax to type. Start minimal, add elements one at a time to isolate the breaking change. Live editor: https://mermaid.live — export PNG/SVG for guaranteed rendering across platforms.

## Accessibility & Performance

Provide context text before diagrams for screen readers: `<div class="mermaid" role="img" aria-label="...">`. Split large diagrams; prefer class-based styling over inline; cache renders and lazy load in documentation.

## Export

| Method | Command/Usage |
|--------|--------------|
| Live editor | PNG, SVG, Markdown at https://mermaid.live |
| Programmatic | `const svg = await mermaid.render('id', diagramText)` |
| CLI | `npx @mermaid-js/mermaid-cli -i input.md -o output.svg` |

# Advanced Configuration & Styling

Theming, configuration, custom styling, and troubleshooting for Mermaid diagrams.

---

# Configuration

## Init Directive

```mermaid
%%{init: { 'theme': 'dark' } }%%
flowchart LR
    A --> B
```

Multi-line with theme variables:

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

---

# Themes

| Theme | Description |
|-------|-------------|
| `default` | Default blue |
| `dark` | Dark mode |
| `forest` | Green |
| `neutral` | Grayscale |
| `base` | Base for customization |

---

# Theme Variables

## Core Variables

| Variable | Description |
|----------|-------------|
| `primaryColor` | Main node color |
| `primaryTextColor` | Text in primary nodes |
| `primaryBorderColor` | Primary node border |
| `secondaryColor` | Secondary elements |
| `tertiaryColor` | Tertiary/background |
| `lineColor` | Edge/arrow color |
| `textColor` | General text |
| `background` | Diagram background |
| `fontSize` | Base font size |
| `fontFamily` | Font family |

## Diagram-Specific Variables

**Flowchart:** `nodeBorder`, `nodeTextColor`, `clusterBkg`, `clusterBorder`, `edgeLabelBackground`

**Sequence:** `actorBorder`, `actorBkg`, `actorTextColor`, `activationBorderColor`, `activationBkgColor`, `signalColor`, `signalTextColor`, `noteBkgColor`, `noteBorderColor`, `noteTextColor`

**State:** `labelColor`, `altBackground`

**Gantt:** `gridColor`, `todayLineColor`, `taskTextColor`, `doneTaskBkgColor`, `activeTaskBkgColor`, `critBkgColor`, `taskBorderColor`

---

# Styling

## Class-Based

```mermaid
flowchart LR
    A[Start]:::success --> B[Process]:::info --> C[End]:::warning
    class A,D success
    class B,C info

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

### Style Properties

| Property | Example |
|----------|---------|
| `fill` | `fill:#3b82f6` |
| `stroke` | `stroke:#2563eb` |
| `stroke-width` | `stroke-width:2px` |
| `stroke-dasharray` | `stroke-dasharray:5,5` |
| `color` | `color:white` |
| `font-weight` | `font-weight:bold` |

---

# Layout & Directives

## ELK Renderer (v9.4+)

Better complex layouts, predictable edge routing, improved subgraph positioning.

```mermaid
%%{init: {"flowchart": {"defaultRenderer": "elk"}} }%%
flowchart TB
    A --> B & C & D
    B & C & D --> E
```

## Common Init Options

```javascript
%%{init: {
  'theme': 'default',
  'flowchart': { 'defaultRenderer': 'elk', 'curve': 'basis', 'padding': 15 },
  'sequence': { 'showSequenceNumbers': true, 'actorMargin': 50, 'boxMargin': 10 },
  'gantt': { 'barHeight': 20, 'fontSize': 11, 'sectionFontSize': 14 }
}}%%
```

Directive keys: `flowchart`, `sequenceDiagram`, `classDiagram`, `stateDiagram`, `erDiagram`, `gantt`

---

# Security Levels

| Level | Description |
|-------|-------------|
| `strict` | Most secure, no HTML/JS |
| `loose` | Allows some interaction |
| `antiscript` | Allows HTML, blocks scripts |
| `sandbox` | iframe sandbox |

```mermaid
%%{init: { 'securityLevel': 'loose' }}%%
flowchart LR
    A --> B
    click A href "https://example.com" _blank
```

---

# Troubleshooting

## Special Characters

Escape with HTML entities or use quoted strings:

```mermaid
flowchart LR
    A["Node with #quot;quotes#quot;"]
    B["Arrow -> symbol"]
    C["Hash #35; symbol"]
```

| Char | Entity | Char | Entity |
|------|--------|------|--------|
| `#` | `#35;` | `"` | `#quot;` |
| `<` | `#lt;` | `>` | `#gt;` |
| `&` | `#amp;` | `{` | `#123;` / `}` | `#125;` |

## Long Labels

```mermaid
flowchart LR
    A["`This is a very long
    label that wraps
    across multiple lines`"]
```

## Arrow Syntax by Diagram Type

| Diagram | Sync | Async | Dotted |
|---------|------|-------|--------|
| Flowchart | `-->` | N/A | `-.->` |
| Sequence | `->>` | `-->>` | `-->>` |
| Class | `-->` | N/A | `..>` |
| State | `-->` | N/A | N/A |

## Debugging

- Verify diagram type declaration; check unclosed brackets/quotes; match arrow syntax to type
- Start minimal, add elements one at a time to isolate breaking change
- Live editor: https://mermaid.live — export PNG/SVG for guaranteed rendering across platforms

---

# Accessibility & Performance

**Accessibility:** Provide context text before diagrams for screen readers. HTML: `<div class="mermaid" role="img" aria-label="...">`.

**Performance:** Split large diagrams. Use ELK for complex layouts. Prefer class-based styling over inline. Cache renders; lazy load in documentation.

---

# Export

| Method | Command/Usage |
|--------|--------------|
| Live editor | PNG, SVG, Markdown at https://mermaid.live |
| Programmatic | `const svg = await mermaid.render('id', diagramText)` |
| CLI | `npx @mermaid-js/mermaid-cli -i input.md -o output.svg` |

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mermaid Quick Reference Cheatsheet

Syntax-at-a-glance. For full examples and patterns, see the chapter files linked in each section.

## Diagram Declarations

| Diagram | Declaration | Diagram | Declaration |
|---------|-------------|---------|-------------|
| Flowchart | `flowchart LR` / `TB` | Sequence | `sequenceDiagram` |
| Class | `classDiagram` | ER | `erDiagram` |
| State | `stateDiagram-v2` | User Journey | `journey` |
| Gantt | `gantt` | Pie | `pie` / `pie showData` |
| Mindmap | `mindmap` | Timeline | `timeline` |
| Git Graph | `gitGraph` | C4 Context | `C4Context` |
| C4 Container | `C4Container` | C4 Component | `C4Component` |
| Architecture | `architecture-beta` | Block | `block-beta` |
| Quadrant | `quadrantChart` | XY Chart | `xychart-beta` |
| Sankey | `sankey-beta` | Kanban | `kanban` |
| Packet | `packet-beta` | Requirement | `requirementDiagram` |
| Treemap | `treemap-beta` | | |

## Flowchart (detail: `flowcharts.md`)

**Direction:** `TB`/`TD` `BT` `LR` `RL`

**Nodes:** `A[Rect]` `B(Rounded)` `C([Stadium])` `D[[Subroutine]]` `E[(Database)]` `F((Circle))` `G{Diamond}` `H{{Hexagon}}` `I[/Parallelogram/]` `J(((Double)))`

**Edges:** `-->` solid arrow, `---` line, `-.->` dotted, `==>` thick, `--o` circle end, `--x` cross end, `<-->` bidirectional, `-->\|text\|` labeled

**Subgraph:** `subgraph Name` ... `end` — nestable, linkable

## Sequence Diagram (detail: `sequence.md`)

**Messages:** `->>` sync, `-->>` response, `-x` failed, `-)` async, `->>+`/`-->>-` activate/deactivate

**Control flow:** `alt`/`else`/`end` `opt`/`end` `loop`/`end` `par`/`and`/`end` `critical`/`option`/`end` `break`/`end`

**Notes:** `Note right of A: Text` `Note over A,B: Spanning`

## Class Diagram (detail: `class-er.md`)

**Visibility:** `+` Public `-` Private `#` Protected `~` Package

**Relationships:** `<\|--` inheritance, `*--` composition, `o--` aggregation, `-->` association, `..>` dependency, `..\|>` realization

**Cardinality:** `A "1" --> "*" B : has` | **Annotations:** `<<interface>>` `<<enumeration>>`

## ER Diagram (detail: `class-er.md`)

**Cardinality:** `\|\|--\|\|` one-one, `\|\|--o{` one-many, `}o--o{` many-many (opt), `}\|--\|{` many-many (req)

**Line type:** `--` identifying, `..` non-identifying

**Attributes:** `ENTITY { type name PK` `type name FK` `type name UK` `}`

## State Diagram (detail: `state-journey.md`)

**Transitions:** `[*] --> State1` `State1 --> State2` `State2 --> [*]`

**Composite:** `state Parent { [*] --> Child }` | **Special:** `<<choice>>` `<<fork>>` `<<join>>`

## Gantt Chart (detail: `data-charts.md`)

**Format:** `Task name : [tags], [id], [start], [end/duration]`

**Tags:** `done` `active` `crit` `milestone` | **Dependencies:** `after t1`

## Pie / Timeline (detail: `data-charts.md`)

**Pie:** `pie showData` then `"Label" : value` | **Timeline:** `timeline` then `section Period` then `Date : Event`

## C4 Diagrams (detail: `architecture.md`)

**Elements:** `Person(alias, "Label", "Desc")` `System(...)` `System_Ext(...)` `Container(alias, "Label", "Tech", "Desc")` `ContainerDb(...)` `Component(...)`

**Relations:** `Rel(from, to, "Label")` `BiRel(...)` | **Boundaries:** `System_Boundary(alias, "Label") { ... }`

## Architecture Diagram (detail: `architecture.md`)

**Groups:** `group id(icon)[Title] in parent` | **Services:** `service id(icon)[Title] in group`

**Edges:** `a:R --> L:b` `a:T --> B:b` `<-->` | **Icons:** `cloud` `database` `disk` `internet` `server`

## Styling (detail: `advanced.md`)

**Themes:** `%%{init: {'theme': 'dark'}}%%` — `default` `dark` `forest` `neutral` `base`

**Custom vars:** `%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#3b82f6'}}}%%`

**Node:** `classDef cls fill:#f00,stroke:#333` `A:::cls` `style A fill:#f00` | **Link:** `linkStyle 0 stroke:red`

## Special Characters

| Char | Escape | Char | Escape | Char | Escape |
|------|--------|------|--------|------|--------|
| `"` | `#quot;` | `#` | `#35;` | `<` | `#lt;` |
| `>` | `#gt;` | `{` | `#123;` | `}` | `#125;` |

## Quick Decision Guide

| Need | Use | Need | Use |
|------|-----|------|-----|
| Process flow | Flowchart | API interactions | Sequence |
| OOP design | Class | Database schema | ER |
| State machine | State | UX mapping | User Journey |
| Project timeline | Gantt | Data distribution | Pie |
| Brainstorming | Mindmap | Chronology | Timeline |
| Git branches | Git Graph | System architecture | C4 / Architecture |
| Priority matrix | Quadrant | Data trends | XY Chart |
| Flow allocation | Sankey | Task board | Kanban |
| Protocol structure | Packet | Requirements | Requirement |

**Resources:** [Live Editor](https://mermaid.live) | [Docs](https://mermaid.js.org) | [GitHub](https://github.com/mermaid-js/mermaid)

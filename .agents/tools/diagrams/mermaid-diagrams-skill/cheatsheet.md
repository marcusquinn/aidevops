# Mermaid Quick Reference Cheatsheet

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

## Flowchart

**Direction:** `TB`/`TD` (top-bottom) `BT` `LR` `RL`

**Nodes:** `A[Rect]` `B(Rounded)` `C([Stadium])` `D[[Subroutine]]` `E[(Database)]` `F((Circle))` `G{Diamond}` `H{{Hexagon}}` `I[/Parallelogram/]` `J(((Double)))`

| Edge | Meaning | Edge | Meaning |
|------|---------|------|---------|
| `A --> B` | Solid arrow | `A --- B` | Solid line |
| `A -.-> B` | Dotted arrow | `A ==> B` | Thick arrow |
| `A --o B` | Circle end | `A --x B` | Cross end |
| `A <--> B` | Bidirectional | `A -->\|text\| B` | Labeled |

**Subgraph:** `subgraph Name` ... `end` — nestable, linkable between subgraphs

## Sequence Diagram

| Message | Meaning | Message | Meaning |
|---------|---------|---------|---------|
| `A->>B` | Sync (solid) | `A-->>B` | Response (dotted) |
| `A-xB` | Failed | `A-)B` | Async |
| `A->>+B` | Activate B | `B-->>-A` | Deactivate B |

**Control flow:** `alt`/`else`/`end` `opt`/`end` `loop`/`end` `par`/`and`/`end` `critical`/`option`/`end` `break`/`end`

**Notes:** `Note right of A: Text` `Note over A,B: Spanning`

## Class Diagram

**Visibility:** `+` Public `-` Private `#` Protected `~` Package

| Relationship | Meaning | Relationship | Meaning |
|-------------|---------|-------------|---------|
| `A <\|-- B` | Inheritance | `A *-- B` | Composition |
| `A o-- B` | Aggregation | `A --> B` | Association |
| `A ..> B` | Dependency | `A ..\|> B` | Realization |

**Cardinality:** `A "1" --> "*" B : has` `A "0..1" --> "1..*" B`

**Annotations:** `class A { <<interface>> +method() }` `class B { <<enumeration>> VALUE1 }`

## ER Diagram

| Symbol | Meaning | Symbol | Meaning |
|--------|---------|--------|---------|
| `\|\|--\|\|` | One to one | `\|\|--o{` | One to many |
| `}o--o{` | Many-many (opt) | `}\|--\|{` | Many-many (req) |
| `--` | Identifying | `..` | Non-identifying |

**Attributes:** `ENTITY { type name PK` `type name FK` `type name UK` `type name }`

## State Diagram

**Transitions:** `[*] --> State1` `State1 --> State2` `State2 --> [*]` (self: `S --> S`)

**Composite:** `state Parent { [*] --> Child1` `Child1 --> Child2 }`

**Choice/Fork/Join:** `state check <<choice>>` `state fork <<fork>>` `state join <<join>>`

## Gantt Chart

**Format:** `Task name : [tags], [id], [start], [end/duration]`

**Tags:** `done` `active` `crit` `milestone` | **Dependencies:** `after t1` `after t1 t2`

**Example:** `Completed :done, t1, 2024-01-01, 7d` `Active :active, t2, after t1, 5d` `Milestone :milestone, m1, 2024-01-20, 0d`

## Pie Chart

**Format:** `pie showData` with indented `title Chart Title` and `"Label" : value` entries.

## Timeline

**Format:** `timeline` with indented `title Title`, `section Period`, `Date : Event 1 : Event 2`.

## C4 Diagrams

**Elements:** `Person(alias, "Label", "Desc")` `System(alias, "Label", "Desc")` `System_Ext(...)` `Container(alias, "Label", "Tech", "Desc")` `ContainerDb(...)` `Component(alias, "Label", "Tech", "Desc")`

**Relations:** `Rel(from, to, "Label")` `Rel(from, to, "Label", "Tech")` `BiRel(from, to, "Label")`

**Boundaries:** `System_Boundary(alias, "Label") { Container(...) }`

## Architecture Diagram

**Groups:** `group id(icon)[Title]` `group id(icon)[Title] in parent`

**Services:** `service id(icon)[Title]` `service id(icon)[Title] in group`

**Edges:** `a:R --> L:b` (right→left) `a:T --> B:b` (top→bottom) `<-->` (bidirectional)

**Icons:** `cloud` `database` `disk` `internet` `server`

## Styling

**Themes:** `%%{init: {'theme': 'dark'}}%%` — `default` `dark` `forest` `neutral` `base`

**Custom vars:** `%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#3b82f6', 'lineColor': '#64748b'}}}%%`

**Node styling:** `classDef myClass fill:#f00,stroke:#333,color:#fff` `A:::myClass` `style A fill:#f00`

**Link styling:** `linkStyle 0 stroke:red` `linkStyle default stroke:gray`

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

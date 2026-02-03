# Mermaid Quick Reference Cheatsheet

---

## Diagram Declarations

| Diagram | Declaration |
|---------|-------------|
| Flowchart | `flowchart LR` / `flowchart TB` |
| Sequence | `sequenceDiagram` |
| Class | `classDiagram` |
| ER | `erDiagram` |
| State | `stateDiagram-v2` |
| User Journey | `journey` |
| Gantt | `gantt` |
| Pie | `pie` / `pie showData` |
| Mindmap | `mindmap` |
| Timeline | `timeline` |
| Git Graph | `gitGraph` |
| C4 Context | `C4Context` |
| C4 Container | `C4Container` |
| C4 Component | `C4Component` |
| Architecture | `architecture-beta` |
| Block | `block-beta` |
| Quadrant | `quadrantChart` |
| XY Chart | `xychart-beta` |
| Sankey | `sankey-beta` |
| Kanban | `kanban` |
| Packet | `packet-beta` |
| Requirement | `requirementDiagram` |
| Treemap | `treemap-beta` |

---

## Flowchart

### Direction
```
TB / TD   Top to Bottom
BT        Bottom to Top
LR        Left to Right
RL        Right to Left
```

### Node Shapes
```
A[Rectangle]       B(Rounded)         C([Stadium])
D[[Subroutine]]    E[(Database)]      F((Circle))
G{Diamond}         H{{Hexagon}}       I[/Parallelogram/]
J(((Double)))
```

### Edges
```
A --> B       Solid arrow
A --- B       Solid line
A -.-> B      Dotted arrow
A ==> B       Thick arrow
A --o B       Circle end
A --x B       Cross end
A <--> B      Bidirectional
A -->|text| B Labeled
```

### Subgraph
```mermaid
flowchart TB
    subgraph Name
        A --> B
    end
```

---

## Sequence Diagram

### Messages
```
A->>B     Solid arrow (sync)
A-->>B    Dotted arrow (response)
A-xB      Failed message
A-)B      Async message
```

### Activation
```
A->>+B: Request    Activate B
B-->>-A: Response  Deactivate B
```

### Control Flow
```
alt Condition
    A->>B: If true
else
    A->>B: If false
end

opt Optional
    A->>B: Maybe
end

loop Every 30s
    A->>B: Repeat
end

par Parallel
    A->>B: Task 1
and
    A->>C: Task 2
end
```

### Notes
```
Note right of A: Text
Note over A,B: Spanning note
```

---

## Class Diagram

### Visibility
```
+  Public
-  Private
#  Protected
~  Package
```

### Relationships
```
A <|-- B    Inheritance
A *-- B     Composition
A o-- B     Aggregation
A --> B     Association
A ..> B     Dependency
A ..|> B    Realization
```

### Cardinality
```
A "1" --> "*" B : has
A "0..1" --> "1..*" B
```

### Annotations
```
class A {
    <<interface>>
    +method()
}

class B {
    <<enumeration>>
    VALUE1
    VALUE2
}
```

---

## ER Diagram

### Cardinality
```
||--||    One to one
||--o{    One to many
}o--o{    Many to many (optional)
}|--|{    Many to many (required)
```

### Line Types
```
--    Identifying (solid)
..    Non-identifying (dashed)
```

### Attributes
```
ENTITY {
    type name PK     Primary key
    type name FK     Foreign key
    type name UK     Unique key
    type name        Regular
}
```

---

## State Diagram

### Basic
```
[*] --> State1          Start
State1 --> State2       Transition
State2 --> [*]          End
State1 --> State1       Self-loop
```

### Composite
```
state Parent {
    [*] --> Child1
    Child1 --> Child2
}
```

### Choice
```
state check <<choice>>
A --> check
check --> B : condition1
check --> C : condition2
```

### Fork/Join
```
state fork <<fork>>
state join <<join>>
[*] --> fork
fork --> A
fork --> B
A --> join
B --> join
join --> [*]
```

---

## Gantt Chart

### Task Syntax
```
Task name : [tags], [id], [start], [end/duration]

Completed   :done, t1, 2024-01-01, 7d
Active      :active, t2, after t1, 5d
Critical    :crit, t3, 2024-01-15, 3d
Milestone   :milestone, m1, 2024-01-20, 0d
```

### Dependencies
```
after taskId
after t1 t2    After multiple
```

---

## Pie Chart

```mermaid
pie showData
    title Chart Title
    "Label 1" : 42
    "Label 2" : 28
    "Label 3" : 30
```

---

## Timeline

```
timeline
    title Title
    section Period
        Date : Event 1
             : Event 2
```

---

## C4 Diagrams

### Elements
```
Person(alias, "Label", "Description")
System(alias, "Label", "Description")
System_Ext(alias, "Label", "Description")
Container(alias, "Label", "Tech", "Description")
ContainerDb(alias, "Label", "Tech", "Description")
Component(alias, "Label", "Tech", "Description")
```

### Relationships
```
Rel(from, to, "Label")
Rel(from, to, "Label", "Technology")
BiRel(from, to, "Label")
```

### Boundaries
```
System_Boundary(alias, "Label") {
    Container(...)
}
```

---

## Architecture Diagram

### Groups
```
group id(icon)[Title]
group id(icon)[Title] in parent
```

### Services
```
service id(icon)[Title]
service id(icon)[Title] in group
```

### Edges
```
a:R --> L:b     Right of a to left of b
a:T --> B:b     Top to bottom
<-->            Bidirectional
```

### Icons
`cloud`, `database`, `disk`, `internet`, `server`

---

## Styling

### Theme
```mermaid
%%{init: {'theme': 'dark'}}%%
```
Themes: `default`, `dark`, `forest`, `neutral`, `base`

### Class Definition
```mermaid
flowchart LR
    A:::className --> B
    classDef className fill:#f00,stroke:#333,color:#fff
```

### Individual Style
```mermaid
flowchart LR
    A --> B
    style A fill:#f00
```

### Link Style
```mermaid
flowchart LR
    A --> B --> C
    linkStyle 0 stroke:red
    linkStyle default stroke:gray
```

---

## Special Characters

| Char | Escape |
|------|--------|
| `"` | `#quot;` |
| `#` | `#35;` |
| `<` | `#lt;` |
| `>` | `#gt;` |
| `{` | `#123;` |
| `}` | `#125;` |

---

## Markdown in Labels

```mermaid
flowchart LR
    A["`**Bold** and *italic*`"]
    B["`Line 1
    Line 2`"]
```

---

## Configuration

```mermaid
%%{init: {
  'theme': 'base',
  'themeVariables': {
    'primaryColor': '#3b82f6',
    'lineColor': '#64748b'
  }
}}%%
```

---

## Quick Decision Guide

| Need | Use |
|------|-----|
| Process flow | Flowchart |
| API interactions | Sequence |
| OOP design | Class |
| Database schema | ER |
| State machine | State |
| UX mapping | User Journey |
| Project timeline | Gantt |
| Data distribution | Pie |
| Brainstorming | Mindmap |
| Chronology | Timeline |
| Git branches | Git Graph |
| System architecture | C4 / Architecture |
| Priority matrix | Quadrant |
| Data trends | XY Chart |
| Flow allocation | Sankey |
| Task board | Kanban |
| Protocol structure | Packet |
| Requirements | Requirement |

---

## Platform Support

| Platform | Status |
|----------|--------|
| GitHub | Native |
| GitLab | Native |
| VS Code | Extension |
| Obsidian | Native |
| Notion | Native |
| Confluence | Plugin |
| Docusaurus | Plugin |

---

## Resources

- **Live Editor**: https://mermaid.live
- **Documentation**: https://mermaid.js.org
- **GitHub**: https://github.com/mermaid-js/mermaid

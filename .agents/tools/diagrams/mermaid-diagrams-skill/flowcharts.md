# Flowchart Diagrams

Flowcharts visualize processes, algorithms, and decision flows using nodes and edges.

## Basic Syntax

```mermaid
flowchart LR
    A[Start] --> B{Decision}
    B -->|Yes| C[Action]
    B -->|No| D[End]
```

Direction: `TB`/`TD` (top-bottom), `BT`, `LR`, `RL`

## Node Shapes

### Standard

```
A[Rectangle]         B(Rounded)           C([Stadium])
D[[Subroutine]]      E[(Database)]        F((Circle))
G{Diamond}           H{{Hexagon}}         I[/Parallelogram/]
J[\Parallelogram\]   K[/Trapezoid\]       L[\Trapezoid/]
M(((Double Circle)))
```

### Extended (v11.3+)

Syntax: `node@{ shape: name, label: "Text" }`

| Shape | Description | Shape | Description |
|-------|-------------|-------|-------------|
| `rect` | Rectangle | `rounded` | Rounded rectangle |
| `stadium` | Pill | `subroutine` | Subroutine box |
| `cyl` | Cylinder (DB) | `circle` | Circle |
| `dbl-circ` | Double circle | `diamond` | Diamond |
| `hex` | Hexagon | `lean-r` / `lean-l` | Parallelogram |
| `trap-b` / `trap-t` | Trapezoid | `doc` | Document |
| `bolt` | Lightning bolt | `tri` | Triangle |
| `fork` | Fork | `hourglass` | Hourglass |
| `flag` | Flag | `comment` | Comment |
| `f-circ` | Filled circle | `lin-cyl` | Lined cylinder |
| `brace` / `brace-r` / `braces` | Curly brace(s) | `win-pane` | Window pane |
| `notch-rect` | Notched rect | `bow-rect` | Bow tie rect |
| `div-rect` | Divided rect | `odd` | Odd shape |
| `lin-doc` | Lined document | `tag-doc` / `tag-rect` | Tagged shapes |
| `half-rounded-rect` | Half rounded | `curv-trap` | Curved trapezoid |

```mermaid
flowchart LR
    doc@{ shape: doc, label: "Document" }
    db@{ shape: cyl, label: "Database" }
    proc@{ shape: rect, label: "Process" }
    dec@{ shape: diamond, label: "Decision" }
```

## Edge Types

```
A --> B       Solid arrow        A --- B       Solid line
A -.-> B      Dotted arrow       A -.- B       Dotted line
A ==> B       Thick arrow        A === B       Thick line
A --o B       Circle end         A --x B       Cross end
A o--o B      Circle both ends   A x--x B      Cross both ends
A <--> B      Bidirectional
```

**Length** — extra dashes extend: `-->` (normal), `--->` (longer), `---->` (longest)

**Labels:** `A -->|text| B` or `A -- text --> B` or `A -->|"multi word"| B`

**Animation (v11+):** `A e1@--> B` then `e1@{ animate: true, animation-duration: "0.5s" }`

## Subgraphs

```mermaid
flowchart TB
    subgraph Frontend
        UI[React App]
    end
    subgraph Backend
        API[REST API]
        WS[WebSocket]
    end
    UI --> API
    UI --> WS
```

**Nested subgraphs** supported. **Per-subgraph direction** — add `direction TB` inside to override locally.

## Multi-Target Edges

```mermaid
flowchart LR
    A --> B & C --> D
    E & F --> G
```

## Markdown in Labels

```mermaid
flowchart LR
    A["`**Bold** and *italic*`"]
    B["`Multi
    line
    text`"]
    A --> B
```

## Icons

```mermaid
flowchart LR
    A[fa:fa-user User] --> B[fa:fa-database Database]
```

## Click Events

```mermaid
flowchart LR
    A[GitHub] --> B[Docs]
    click A href "https://github.com" _blank
    click B call callback()
```

## Styling

```mermaid
flowchart LR
    A[Start]:::green --> B[Process]:::blue --> C[End]:::green
    classDef green fill:#10b981,stroke:#059669,color:white
    classDef blue fill:#3b82f6,stroke:#2563eb,color:white
    style A fill:#f9f,stroke:#333,stroke-width:2px
    linkStyle 0 stroke:red,stroke-width:2px
    linkStyle default stroke:gray,stroke-width:1px
```

## Layout Engine

ELK for complex diagrams (v9.4+):

```mermaid
%%{init: {"flowchart": {"defaultRenderer": "elk"}} }%%
flowchart TB
    A --> B & C & D
    B & C & D --> E
```

## Example: CI/CD Pipeline

```mermaid
flowchart LR
    subgraph Build
        Lint[Lint] --> Test[Test] --> Compile[Build]
    end
    subgraph Deploy
        Staging[Staging]
        Prod[Production]
    end
    Git[Git Push] --> Lint
    Compile --> Staging
    Staging -->|approved| Prod
    style Prod fill:#10b981
```

# Flowchart Diagrams

Flowcharts visualize processes, algorithms, and decision flows using nodes and edges.

## Basic Syntax

```mermaid
flowchart LR
    A[Start] --> B{Decision}
    B -->|Yes| C[Action]
    B -->|No| D[End]
```

## Direction

| Declaration | Direction |
|-------------|-----------|
| `TB` / `TD` | Top to Bottom |
| `BT` | Bottom to Top |
| `LR` | Left to Right |
| `RL` | Right to Left |

## Node Shapes

### Standard Shapes

```
A[Rectangle]         Default box
B(Rounded)           Rounded corners
C([Stadium])         Pill shape
D[[Subroutine]]      Double vertical lines
E[(Database)]        Cylinder
F((Circle))          Circle
G{Diamond}           Decision/rhombus
H{{Hexagon}}         Hexagon
I[/Parallelogram/]   Slanted right
J[\Parallelogram\]   Slanted left
K[/Trapezoid\]       Trapezoid
L[\Trapezoid/]       Inverted trapezoid
M(((Double Circle))) Double circle
```

### Extended Shapes (v11.3+)

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
A --> B       Solid arrow
A --- B       Solid line (no arrow)
A -.-> B      Dotted arrow
A -.- B       Dotted line
A ==> B       Thick arrow
A === B       Thick line
A --o B       Circle end
A --x B       Cross end
A o--o B      Circle both ends
A x--x B      Cross both ends
A <--> B      Arrows both ends
```

**Edge length** — extra dashes extend: `A --> B` (normal), `A ---> B` (longer), `A ----> B` (even longer)

**Labels:**

```mermaid
flowchart LR
    A --> |label| B
    C -- text --> D
    E -->|"multi word"| F
```

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

**Nested subgraphs** — subgraphs can contain subgraphs. **Per-subgraph direction** — add `direction TB` inside a subgraph to override flow direction locally.

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
```

**Individual node and link styles:**

```mermaid
flowchart LR
    A --> B --> C
    style A fill:#f9f,stroke:#333,stroke-width:2px
    linkStyle 0 stroke:red,stroke-width:2px
    linkStyle 1 stroke:blue,stroke-dasharray:5
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

## Examples

### Decision Tree

```mermaid
flowchart TD
    Start[User Request] --> Auth{Authenticated?}
    Auth -->|Yes| Perm{Has Permission?}
    Auth -->|No| Login[Redirect to Login]
    Perm -->|Yes| Process[Process Request]
    Perm -->|No| Denied[403 Forbidden]
    Process --> Success[200 OK]
    style Success fill:#10b981
    style Denied fill:#ef4444
    style Login fill:#f59e0b
```

### CI/CD Pipeline

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

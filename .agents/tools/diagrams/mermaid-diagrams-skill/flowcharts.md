# Flowchart Diagrams

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

Nested subgraphs supported. Add `direction TB` inside a subgraph to override direction locally.

## Multi-Target Edges

`A --> B & C --> D` — fan-out; `E & F --> G` — fan-in

## Markdown in Labels

Wrap label in backtick-quotes: `A["`**Bold** and *italic*`"]` — supports bold, italic, multi-line.

## Icons

`A[fa:fa-user User]` — FontAwesome prefix `fa:fa-name`

## Click Events

`click A href "https://url" _blank` — open URL; `click B call callback()` — JS callback

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

## Layout Engine (ELK, v9.4+)

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

# Flowchart Diagrams

Flowcharts visualize processes, algorithms, and decision flows using nodes and edges.

---

## Basic Syntax

```mermaid
flowchart LR
    A[Start] --> B{Decision}
    B -->|Yes| C[Action]
    B -->|No| D[End]
```

---

## Direction

| Declaration | Direction |
|-------------|-----------|
| `TB` / `TD` | Top to Bottom |
| `BT` | Bottom to Top |
| `LR` | Left to Right |
| `RL` | Right to Left |

```mermaid
flowchart TB
    A --> B --> C
```

---

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

New syntax using `@{ shape: name }`:

```mermaid
flowchart LR
    doc@{ shape: doc, label: "Document" }
    db@{ shape: cyl, label: "Database" }
    proc@{ shape: rect, label: "Process" }
    dec@{ shape: diamond, label: "Decision" }
```

**Available extended shapes:**

| Shape | Description |
|-------|-------------|
| `rect` | Rectangle |
| `rounded` | Rounded rectangle |
| `stadium` | Stadium/pill |
| `subroutine` | Subroutine box |
| `cyl` | Cylinder (database) |
| `circle` | Circle |
| `dbl-circ` | Double circle |
| `diamond` | Diamond/rhombus |
| `hex` | Hexagon |
| `lean-r` | Lean right (parallelogram) |
| `lean-l` | Lean left |
| `trap-b` | Trapezoid bottom |
| `trap-t` | Trapezoid top |
| `doc` | Document |
| `notch-rect` | Notched rectangle |
| `brace` | Curly brace left |
| `brace-r` | Curly brace right |
| `braces` | Double braces |
| `comment` | Comment |
| `bolt` | Lightning bolt |
| `lin-cyl` | Lined cylinder |
| `bow-rect` | Bow tie rectangle |
| `div-rect` | Divided rectangle |
| `odd` | Odd shape |
| `win-pane` | Window pane |
| `f-circ` | Filled circle |
| `lin-doc` | Lined document |
| `tri` | Triangle |
| `fork` | Fork |
| `hourglass` | Hourglass |
| `flag` | Flag |
| `tag-doc` | Tagged document |
| `tag-rect` | Tagged rectangle |
| `half-rounded-rect` | Half rounded rectangle |
| `curv-trap` | Curved trapezoid |

---

## Edge Types

### Basic Edges

```
A --> B       Solid arrow
A --- B       Solid line (no arrow)
A -.-> B      Dotted arrow
A -.- B       Dotted line
A ==> B       Thick arrow
A === B       Thick line
```

### Arrow Ends

```
A --o B       Circle end
A --x B       Cross end
A o--o B      Circle both ends
A x--x B      Cross both ends
A <--> B      Arrows both ends
```

### Edge Labels

```mermaid
flowchart LR
    A --> |label| B
    C -- text --> D
    E -->|"multi word"| F
```

### Edge Length

Control edge length with extra dashes:

```
A --> B        Normal
A ---> B       Longer
A ----> B      Even longer
```

### Edge IDs and Animation (v11+)

```mermaid
flowchart LR
    A e1@--> B e2@--> C
    e1@{ animate: true }
    e2@{ animate: true, animation-duration: "0.5s" }
```

---

## Subgraphs

Group related nodes:

```mermaid
flowchart TB
    subgraph Frontend
        UI[React App]
        State[Redux Store]
    end

    subgraph Backend
        API[REST API]
        WS[WebSocket]
    end

    subgraph Data
        DB[(PostgreSQL)]
        Cache[(Redis)]
    end

    UI --> API
    UI --> WS
    API --> DB
    API --> Cache
```

### Nested Subgraphs

```mermaid
flowchart TB
    subgraph Cloud
        subgraph VPC
            subgraph Public
                LB[Load Balancer]
            end
            subgraph Private
                App[App Server]
                DB[(Database)]
            end
        end
    end

    LB --> App --> DB
```

### Subgraph Direction

```mermaid
flowchart LR
    subgraph TOP
        direction TB
        A --> B
    end
    subgraph BOTTOM
        direction TB
        C --> D
    end
    TOP --> BOTTOM
```

---

## Multi-Target Edges

Connect multiple nodes:

```mermaid
flowchart LR
    A --> B & C --> D
    E & F --> G
```

---

## Markdown in Labels

Use backticks for markdown:

```mermaid
flowchart LR
    A["`**Bold** and *italic*`"]
    B["`Multi
    line
    text`"]
    A --> B
```

---

## Icons

FontAwesome icons (when enabled):

```mermaid
flowchart LR
    A[fa:fa-user User] --> B[fa:fa-database Database]
    B --> C[fa:fa-cog Settings]
```

---

## Click Events

### Links

```mermaid
flowchart LR
    A[GitHub] --> B[Docs]
    click A href "https://github.com" _blank
    click B href "https://docs.example.com"
```

### Callbacks

```mermaid
flowchart LR
    A[Click Me] --> B
    click A call callback()
```

---

## Styling

### Inline Styles

```mermaid
flowchart LR
    A[Start]:::green --> B[Process]:::blue --> C[End]:::green

    classDef green fill:#10b981,stroke:#059669,color:white
    classDef blue fill:#3b82f6,stroke:#2563eb,color:white
```

### Individual Node Style

```mermaid
flowchart LR
    A --> B --> C
    style A fill:#f9f,stroke:#333,stroke-width:2px
    style B fill:#bbf,stroke:#333
```

### Link Styles

```mermaid
flowchart LR
    A --> B --> C
    linkStyle 0 stroke:red,stroke-width:2px
    linkStyle 1 stroke:blue,stroke-width:2px,stroke-dasharray:5
```

### Default Styles

```mermaid
flowchart LR
    A --> B --> C
    linkStyle default stroke:gray,stroke-width:1px
```

---

## Layout Engine

Use ELK for complex diagrams (v9.4+):

```mermaid
%%{init: {"flowchart": {"defaultRenderer": "elk"}} }%%
flowchart TB
    A --> B & C & D
    B & C & D --> E
```

---

## Examples

### Microservices Architecture

```mermaid
flowchart LR
    subgraph Client
        Web[Web App]
        Mobile[Mobile App]
    end

    subgraph Gateway
        Kong[API Gateway]
        Auth[Auth Service]
    end

    subgraph Services
        Users[Users Service]
        Orders[Orders Service]
        Products[Products Service]
        Payments[Payments Service]
    end

    subgraph Data
        UsersDB[(Users DB)]
        OrdersDB[(Orders DB)]
        ProductsDB[(Products DB)]
        MQ[Message Queue]
    end

    Web & Mobile --> Kong
    Kong --> Auth
    Auth --> Users
    Kong --> Orders & Products & Payments
    Users --> UsersDB
    Orders --> OrdersDB
    Products --> ProductsDB
    Orders --> MQ
    Payments --> MQ
```

### CI/CD Pipeline

```mermaid
flowchart LR
    subgraph Source
        Git[Git Push]
    end

    subgraph Build
        Lint[Lint]
        Test[Test]
        Build[Build]
    end

    subgraph Deploy
        Staging[Staging]
        Prod[Production]
    end

    Git --> Lint --> Test --> Build
    Build --> Staging
    Staging -->|approved| Prod

    style Prod fill:#10b981
```

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

### Data Flow

```mermaid
flowchart LR
    Input[(Raw Data)] --> Transform[ETL Process]
    Transform --> Validate{Valid?}
    Validate -->|Yes| Store[(Data Warehouse)]
    Validate -->|No| Error[Error Queue]
    Store --> Analytics[Analytics Engine]
    Analytics --> Dashboard[Dashboard]
    Analytics --> Reports[Reports]
```

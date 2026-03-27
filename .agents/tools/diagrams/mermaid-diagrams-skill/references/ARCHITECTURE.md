# Architecture Diagrams

Cloud and CI/CD infrastructure visualization using icons and groups.

### Components

**Groups:** `group {id}({icon})[{title}]` / `group {id}({icon})[{title}] in {parent_id}`

**Services:** `service {id}({icon})[{title}]` / `service {id}({icon})[{title}] in {group_id}`

**Junctions:** `junction {id}` / `junction {id} in {group_id}`

### Edges

`{service}:{direction} {arrow} {direction}:{service}`

| Direction | Code | Arrow Types | Syntax |
|-----------|------|-------------|--------|
| Top | `T` | Undirected | `--` |
| Bottom | `B` | Right | `-->` |
| Left | `L` | Left | `<--` |
| Right | `R` | Bidirectional | `<-->` |

### Icons

Default: `cloud`, `database`, `disk`, `internet`, `server`

Iconify (200,000+ icons): `logos:aws`, `logos:google-cloud`, etc.

### Example

```mermaid
architecture-beta
    group cloud(cloud)[AWS Cloud]
    group public(cloud)[Public] in cloud
    group private(cloud)[Private] in cloud

    service lb(server)[Load Balancer] in public
    service api1(server)[API Server 1] in private
    service db(database)[RDS PostgreSQL] in private
    service cache(database)[ElastiCache] in private
    junction junc in private

    lb:B --> T:junc
    junc:L --> R:api1
    api1:B --> T:db
    api1:R --> L:cache
```

---

## Block Diagrams

System component layouts with flexible positioning.

**Columns:** `columns N` — controls layout width. **Spanning:** `a:1 b:2 c:3`

**Shapes:** `["Rectangle"]` `("Rounded")` `(["Stadium"])` `[("Database")]` `(("Circle"))` `{"Diamond"}` `{{"Hexagon"}}`

**Nested blocks:**

```mermaid
block-beta
    columns 2
    block:frontend
        columns 1
        UI["React App"]
        State["Redux Store"]
    end
    block:backend
        columns 1
        API["REST API"]
        DB[("PostgreSQL")]
    end
    frontend --> backend
```

**Styling:** `classDef name fill:#hex,stroke:#hex` then `class NodeId name`

### Example: Three-Tier Architecture

```mermaid
block-beta
    columns 3
    block:presentation["Presentation Tier"]
        columns 1
        Web["Web App"]
        Mobile["Mobile App"]
    end
    space
    block:application["Application Tier"]
        columns 1
        API["API Gateway"]
        Auth["Auth Service"]
    end
    space
    block:data["Data Tier"]
        columns 1
        DB[("PostgreSQL")]
        Cache[("Redis")]
    end
    presentation --> application
    application --> data
    classDef tier fill:#f0f9ff,stroke:#0284c7
    class presentation,application,data tier
```

---

## C4 Diagrams

Software architecture using the C4 model (Context, Container, Component, Code).

| Type | Declaration | Level |
|------|-------------|-------|
| System Context | `C4Context` | 1 — Highest |
| Container | `C4Container` | 2 |
| Component | `C4Component` | 3 |
| Dynamic | `C4Dynamic` | Interactions |
| Deployment | `C4Deployment` | Infrastructure |

**Context elements:** `Person`, `Person_Ext`, `System`, `System_Ext`, `SystemDb`, `SystemQueue`, `Boundary`, `Enterprise_Boundary`

**Container elements:** `Container(alias, label, tech, desc)`, `Container_Ext`, `ContainerDb`, `ContainerQueue`, `Container_Boundary`

**Relationships:** `Rel(from, to, label[, tech])`, `BiRel()`, `Rel_U/D/L/R()`, `Rel_Back()`

**Styling:** `UpdateElementStyle(alias, $fontColor, $bgColor)`, `UpdateRelStyle(from, to, $textColor, $lineColor)`

### C4Context

```mermaid
C4Context
    title System Context Diagram
    Person(user, "User", "End user")
    System(system, "Our System", "Main application")
    System_Ext(email, "Email Service", "SendGrid")
    Rel(user, system, "Uses")
    Rel(system, email, "Sends emails")
```

### C4Container

```mermaid
C4Container
    title Container Diagram
    Person(user, "User", "End user")
    System_Boundary(system, "Our System") {
        Container(web, "Web App", "React", "User interface")
        Container(api, "API", "Node.js", "Business logic")
        ContainerDb(db, "Database", "PostgreSQL", "Stores data")
        ContainerQueue(queue, "Message Queue", "RabbitMQ", "Async processing")
    }
    Rel(user, web, "Uses", "HTTPS")
    Rel(web, api, "Calls", "REST/JSON")
    Rel(api, db, "Reads/Writes", "SQL")
    Rel(api, queue, "Publishes", "AMQP")
```

### C4Dynamic

Numbered `Rel()` calls show interaction sequence. Same elements as C4Container.

### C4Deployment

`Deployment_Node(alias, label, tech)` nests infrastructure. Contains `Container`/`ContainerDb` elements. Same `Rel()` syntax.

---

## Kanban Diagrams

```mermaid
kanban
    Backlog
        story1[User login]
    Todo
        task1[Design login form]
        @{ ticket: AUTH-123 }
        @{ assigned: alice }
        @{ priority: High }
    In Progress
        task2[Implement login API]
    Done
        task3[Project setup]
```

**Metadata keys:** `ticket`, `assigned`, `priority`

**Config:**

```yaml
---
config:
  kanban:
    ticketBaseUrl: 'https://jira.example.com/browse/#TICKET#'
---
```

---

## Packet Diagrams

Network protocol visualization. Bit ranges: absolute `0-15: "Field"` or relative `+16: "Field"`.

```mermaid
packet-beta
    0-15: "Source Port"
    16-31: "Destination Port"
    32-63: "Sequence Number"
    64-95: "Acknowledgment Number"
    96-111: "Flags/Window"
    112-127: "Checksum"
    128-191: "Options"
    192-255: "Data"
```

---

## Requirement Diagrams

System requirements and traceability.

**Types:** `requirement`, `functionalRequirement`, `interfaceRequirement`, `performanceRequirement`, `physicalRequirement`, `designConstraint`

**Relationships:** `contains`, `copies`, `derives`, `satisfies`, `verifies`, `refines`, `traces`

```mermaid
requirementDiagram

    requirement auth_system {
        id: REQ-100
        text: System shall provide user authentication
        risk: high
        verifymethod: test
    }

    functionalRequirement login {
        id: REQ-101
        text: Users can log in with email/password
        risk: medium
        verifymethod: test
    }

    element auth_service { type: service }
    element auth_tests { type: test_suite }

    auth_system - contains -> login
    auth_service - satisfies -> login
    auth_tests - verifies -> login
```

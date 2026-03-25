# Architecture Diagrams

Mermaid provides several diagram types for system architecture: Architecture diagrams, Block diagrams, C4 diagrams, Kanban boards, Packet diagrams, and Requirement diagrams.

---

## Architecture Diagrams

Cloud and CI/CD infrastructure visualization using icons and groups.

### Basic Syntax

```mermaid
architecture-beta
    group api(cloud)[API]

    service db(database)[Database] in api
    service server(server)[Server] in api

    db:L -- R:server
```

### Components

**Groups** — organize services logically:

```
group {id}({icon})[{title}]
group {id}({icon})[{title}] in {parent_id}
```

**Services** — individual components:

```
service {id}({icon})[{title}]
service {id}({icon})[{title}] in {group_id}
```

**Junctions** — 4-way connection points:

```
junction {id}
junction {id} in {group_id}
```

### Edges

```
{service}:{direction} {arrow} {direction}:{service}
```

| Direction | Code | Arrow Types | Syntax |
|-----------|------|-------------|--------|
| Top | `T` | Undirected | `--` |
| Bottom | `B` | Right | `-->` |
| Left | `L` | Left | `<--` |
| Right | `R` | Bidirectional | `<-->` |

### Icons

Default: `cloud`, `database`, `disk`, `internet`, `server`

Iconify (200,000+ icons): `logos:aws`, `logos:google-cloud`, etc.

### Example: Microservices Architecture

```mermaid
architecture-beta
    group cloud(cloud)[AWS Cloud]

    group public(cloud)[Public] in cloud
    group private(cloud)[Private] in cloud

    service lb(server)[Load Balancer] in public
    service cdn(internet)[CloudFront] in public

    service api1(server)[API Server 1] in private
    service api2(server)[API Server 2] in private
    service db(database)[RDS PostgreSQL] in private
    service cache(database)[ElastiCache] in private
    service queue(server)[SQS] in private
    service worker(server)[Worker] in private

    junction junc in private

    cdn:B --> T:lb
    lb:B --> T:junc
    junc:L --> R:api1
    junc:R --> L:api2
    api1:B --> T:db
    api2:B --> T:db
    api1:R --> L:cache
    api2:L --> R:cache
    api1:B --> T:queue
    queue:R --> L:worker
    worker:B --> T:db
```

---

## Block Diagrams

System component layouts with flexible positioning.

### Syntax

```mermaid
block-beta
    columns 3
    a b c
    d e f
```

**Block width (spanning):** `a:1 b:2 c:3`

**Shapes:**

```mermaid
block-beta
    columns 4
    a["Rectangle"]
    b("Rounded")
    c(["Stadium"])
    d[("Database")]
    e(("Circle"))
    f{"Diamond"}
    g{{"Hexagon"}}
```

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
        WS["WebSocket"]
    end

    DB[("PostgreSQL")]
    Cache[("Redis")]

    frontend --> backend
    backend --> DB
    backend --> Cache
```

**Styling:**

```mermaid
block-beta
    columns 3
    Frontend Backend Database

    classDef front fill:#4ade80,stroke:#166534
    classDef back fill:#60a5fa,stroke:#1d4ed8
    classDef data fill:#f472b6,stroke:#be185d

    class Frontend front
    class Backend back
    class Database data
```

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
        Core["Core Service"]
    end

    space

    block:data["Data Tier"]
        columns 1
        DB[("PostgreSQL")]
        Cache[("Redis")]
        Queue["Message Queue"]
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

### C4Context (Level 1)

```mermaid
C4Context
    title System Context Diagram

    Person(user, "User", "A user of our system")
    Person(admin, "Admin", "System administrator")

    System(system, "Our System", "Main application")

    System_Ext(email, "Email Service", "SendGrid")
    System_Ext(payment, "Payment Gateway", "Stripe")

    Rel(user, system, "Uses")
    Rel(admin, system, "Manages")
    Rel(system, email, "Sends emails")
    Rel(system, payment, "Processes payments")
```

**Elements:** `Person`, `Person_Ext`, `System`, `System_Ext`, `SystemDb`, `SystemQueue`, `Boundary`, `Enterprise_Boundary`

### C4Container (Level 2)

```mermaid
C4Container
    title Container Diagram

    Person(user, "User", "End user")

    System_Boundary(system, "Our System") {
        Container(web, "Web App", "React", "User interface")
        Container(api, "API", "Node.js", "Business logic")
        ContainerDb(db, "Database", "PostgreSQL", "Stores data")
        ContainerQueue(queue, "Message Queue", "RabbitMQ", "Async processing")
        Container(worker, "Worker", "Node.js", "Background jobs")
    }

    System_Ext(email, "Email Service", "SendGrid")

    Rel(user, web, "Uses", "HTTPS")
    Rel(web, api, "Calls", "REST/JSON")
    Rel(api, db, "Reads/Writes", "SQL")
    Rel(api, queue, "Publishes", "AMQP")
    Rel(queue, worker, "Consumes", "AMQP")
    Rel(worker, email, "Sends via", "HTTPS")
```

**Container elements:** `Container`, `Container_Ext`, `ContainerDb`, `ContainerQueue`, `Container_Boundary`

### C4Component (Level 3)

```mermaid
C4Component
    title Component Diagram - API

    Container_Boundary(api, "API Container") {
        Component(auth, "Auth Controller", "Express", "Handles authentication")
        Component(orders, "Orders Controller", "Express", "Order management")
        Component(authSvc, "Auth Service", "TypeScript", "Auth business logic")
        Component(orderSvc, "Order Service", "TypeScript", "Order business logic")
        Component(repo, "Repository", "TypeScript", "Data access")
    }

    ContainerDb(db, "Database", "PostgreSQL")
    Container_Ext(cache, "Cache", "Redis")

    Rel(auth, authSvc, "Uses")
    Rel(orders, orderSvc, "Uses")
    Rel(authSvc, repo, "Uses")
    Rel(orderSvc, repo, "Uses")
    Rel(repo, db, "Reads/Writes")
    Rel(authSvc, cache, "Caches sessions")
```

### C4Dynamic & C4Deployment

```mermaid
C4Dynamic
    title Dynamic Diagram - Order Flow

    Person(user, "User")
    Container(web, "Web App", "React")
    Container(api, "API", "Node.js")
    ContainerDb(db, "Database", "PostgreSQL")
    Container(worker, "Worker", "Node.js")
    System_Ext(email, "Email", "SendGrid")

    Rel(user, web, "1. Places order")
    Rel(web, api, "2. POST /orders")
    Rel(api, db, "3. Insert order")
    Rel(api, web, "4. Order created")
    Rel(api, worker, "5. Queue email job")
    Rel(worker, email, "6. Send confirmation")
```

```mermaid
C4Deployment
    title Deployment Diagram

    Deployment_Node(aws, "AWS", "Cloud") {
        Deployment_Node(vpc, "VPC", "Network") {
            Deployment_Node(eks, "EKS", "Kubernetes") {
                Container(api, "API", "Node.js")
                Container(worker, "Worker", "Node.js")
            }
            Deployment_Node(rds, "RDS", "Database") {
                ContainerDb(db, "PostgreSQL", "Database")
            }
        }
    }

    Rel(api, db, "SQL")
```

**Relationships:** `Rel(from, to, label[, tech])`, `BiRel()`, `Rel_U/D/L/R()`, `Rel_Back()`

**Styling:** `UpdateElementStyle(alias, $fontColor, $bgColor)`, `UpdateRelStyle(from, to, $textColor, $lineColor)`

---

## Kanban Diagrams

```mermaid
kanban
    Backlog
        story1[User login]
        story2[Password reset]
    Todo
        task1[Design login form]
        @{ ticket: AUTH-123 }
        @{ assigned: alice }
        @{ priority: High }
    In Progress
        task2[Implement login API]
        @{ assigned: bob }
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

Network protocol visualization.

```mermaid
packet-beta
    0-15: "Source Port"
    16-31: "Destination Port"
    32-63: "Sequence Number"
    64-95: "Acknowledgment Number"
    96-99: "Data Offset"
    100-105: "Reserved"
    106: "URG"
    107: "ACK"
    108: "PSH"
    109: "RST"
    110: "SYN"
    111: "FIN"
    112-127: "Window"
    128-143: "Checksum"
    144-159: "Urgent Pointer"
    160-191: "(Options)"
    192-255: "Data"
```

**Bit ranges:** Absolute `0-15: "Field"` or relative `+16: "Field"` (16 bits from current position).

---

## Requirement Diagrams

System requirements and traceability.

**Requirement types:** `requirement`, `functionalRequirement`, `interfaceRequirement`, `performanceRequirement`, `physicalRequirement`, `designConstraint`

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

    functionalRequirement mfa {
        id: REQ-102
        text: System shall support MFA
        risk: high
        verifymethod: demonstration
    }

    element auth_service {
        type: service
        docref: SVC-001
    }

    element auth_tests {
        type: test_suite
        docref: TEST-001
    }

    auth_system - contains -> login
    auth_system - contains -> mfa
    auth_service - satisfies -> login
    auth_service - satisfies -> mfa
    auth_tests - verifies -> login
    auth_tests - verifies -> mfa
```

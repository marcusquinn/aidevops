# Architecture Diagrams

Mermaid provides several diagram types for system architecture: Architecture diagrams, Block diagrams, C4 diagrams, and Kanban boards.

---

# Architecture Diagrams

Cloud and CI/CD infrastructure visualization using icons and groups.

## Basic Syntax

```mermaid
architecture-beta
    group api(cloud)[API]

    service db(database)[Database] in api
    service server(server)[Server] in api

    db:L -- R:server
```

---

## Components

### Groups

Organize services logically:

```
group {id}({icon})[{title}]
group {id}({icon})[{title}] in {parent_id}
```

```mermaid
architecture-beta
    group cloud(cloud)[Cloud Infrastructure]
    group vpc(cloud)[VPC] in cloud
    group public(cloud)[Public Subnet] in vpc
    group private(cloud)[Private Subnet] in vpc
```

### Services

Individual components:

```
service {id}({icon})[{title}]
service {id}({icon})[{title}] in {group_id}
```

```mermaid
architecture-beta
    group backend(cloud)[Backend]

    service api(server)[API Server] in backend
    service db(database)[PostgreSQL] in backend
    service cache(database)[Redis] in backend
```

### Junctions

4-way connection points:

```
junction {id}
junction {id} in {group_id}
```

---

## Edges

Connect components with directional flow:

```
{service}:{direction} {arrow} {direction}:{service}
```

### Directions

| Code | Position |
|------|----------|
| `T` | Top |
| `B` | Bottom |
| `L` | Left |
| `R` | Right |

### Arrow Types

| Syntax | Description |
|--------|-------------|
| `--` | Undirected |
| `-->` | Arrow to right |
| `<--` | Arrow to left |
| `<-->` | Bidirectional |

```mermaid
architecture-beta
    service a(server)[A]
    service b(server)[B]
    service c(server)[C]
    service d(server)[D]

    a:R --> L:b
    b:B --> T:c
    c:L <-- R:d
```

---

## Icons

### Default Icons

| Icon | Description |
|------|-------------|
| `cloud` | Cloud |
| `database` | Database |
| `disk` | Disk storage |
| `internet` | Internet/globe |
| `server` | Server |

### Iconify Icons

Access 200,000+ icons from iconify.design:

```mermaid
architecture-beta
    service aws(logos:aws)[AWS]
    service gcp(logos:google-cloud)[GCP]
```

---

## Example: Microservices Architecture

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

# Block Diagrams

System component layouts with flexible positioning.

## Basic Syntax

```mermaid
block-beta
    columns 3
    a b c
    d e f
```

---

## Columns

Control layout width:

```mermaid
block-beta
    columns 4
    a b c d
    e f g h
```

## Block Width (Spanning)

```mermaid
block-beta
    columns 3
    a:1 b:2
    c:3
```

## Block Shapes

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

---

## Nested Blocks

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

---

## Connections

```mermaid
block-beta
    columns 3

    A["Client"] --> B["API Gateway"]
    B --> C["Service A"]
    B --> D["Service B"]
    C --> E[("Database")]
    D --> E
```

---

## Styling

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

---

## Example: Three-Tier Architecture

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

# C4 Diagrams

Software architecture using the C4 model (Context, Container, Component, Code).

## Diagram Types

| Type | Declaration | Level |
|------|-------------|-------|
| System Context | `C4Context` | 1 - Highest |
| Container | `C4Container` | 2 |
| Component | `C4Component` | 3 |
| Dynamic | `C4Dynamic` | Interactions |
| Deployment | `C4Deployment` | Infrastructure |

---

## C4Context (Level 1)

Shows system in context with users and external systems:

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

### Elements

| Function | Description |
|----------|-------------|
| `Person(alias, label, desc)` | User/actor |
| `Person_Ext()` | External person |
| `System(alias, label, desc)` | Software system |
| `System_Ext()` | External system |
| `SystemDb()` | Database system |
| `SystemQueue()` | Queue system |
| `Boundary(alias, label)` | Grouping boundary |
| `Enterprise_Boundary()` | Enterprise scope |

---

## C4Container (Level 2)

Shows containers within the system:

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

### Container Elements

| Function | Description |
|----------|-------------|
| `Container(alias, label, tech, desc)` | Container |
| `Container_Ext()` | External container |
| `ContainerDb()` | Database container |
| `ContainerQueue()` | Queue container |
| `Container_Boundary()` | Container grouping |

---

## C4Component (Level 3)

Shows components within a container:

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

---

## C4Dynamic

Shows runtime interactions:

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

---

## C4Deployment

Shows deployment to infrastructure:

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

---

## Relationships

| Function | Description |
|----------|-------------|
| `Rel(from, to, label)` | Relationship |
| `Rel(from, to, label, tech)` | With technology |
| `BiRel()` | Bidirectional |
| `Rel_U()`, `Rel_D()`, `Rel_L()`, `Rel_R()` | Directional |
| `Rel_Back()` | Reverse direction |

---

## Styling

```mermaid
C4Context
    Person(user, "User")
    System(system, "System")
    Rel(user, system, "Uses")

    UpdateElementStyle(user, $fontColor="blue", $bgColor="lightblue")
    UpdateRelStyle(user, system, $textColor="red", $lineColor="red")
```

---

# Kanban Diagrams

Workflow boards for task management.

## Basic Syntax

```mermaid
kanban
    Todo
        task1[Design API]
        task2[Write tests]
    In Progress
        task3[Implement auth]
    Done
        task4[Setup project]
```

---

## Task Metadata

```mermaid
kanban
    Backlog
        task1[User authentication]
        @{ ticket: AUTH-123 }
        @{ assigned: john }
        @{ priority: High }
```

### Metadata Keys

| Key | Description |
|-----|-------------|
| `ticket` | Issue/ticket number |
| `assigned` | Assignee |
| `priority` | Priority level |

---

## Configuration

```yaml
---
config:
  kanban:
    ticketBaseUrl: 'https://jira.example.com/browse/#TICKET#'
---
```

---

## Example: Sprint Board

```mermaid
kanban
    Backlog
        story1[User login]
        story2[Password reset]
        story3[OAuth integration]

    Todo
        task1[Design login form]
        task2[Setup JWT auth]

    In Progress
        task3[Implement login API]
        @{ assigned: alice }
        task4[Write login tests]
        @{ assigned: bob }

    Review
        task5[Database schema]
        @{ assigned: charlie }

    Done
        task6[Project setup]
        task7[CI/CD pipeline]
```

---

# Packet Diagrams

Network protocol visualization.

## Basic Syntax

```mermaid
packet-beta
    0-15: "Source Port"
    16-31: "Destination Port"
    32-63: "Sequence Number"
```

## Bit Ranges

Two syntaxes:
- Absolute: `0-15: "Field"`
- Relative: `+16: "Field"` (16 bits from current position)

---

## Example: TCP Packet

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

## Example: UDP Packet

```mermaid
packet-beta
    title UDP Packet
    +16: "Source Port"
    +16: "Destination Port"
    +16: "Length"
    +16: "Checksum"
    +64: "Data"
```

---

# Requirement Diagrams

System requirements and traceability.

## Basic Syntax

```mermaid
requirementDiagram

    requirement user_login {
        id: REQ-001
        text: Users must be able to log in
        risk: low
        verifymethod: test
    }

    element login_page {
        type: ui_component
        docref: UI-001
    }

    login_page - satisfies -> user_login
```

## Requirement Types

| Type | Description |
|------|-------------|
| `requirement` | Generic |
| `functionalRequirement` | Functional |
| `interfaceRequirement` | Interface |
| `performanceRequirement` | Performance |
| `physicalRequirement` | Physical |
| `designConstraint` | Constraint |

## Relationships

| Type | Meaning |
|------|---------|
| `contains` | Parent contains child |
| `copies` | Duplicate |
| `derives` | Derives from |
| `satisfies` | Element satisfies requirement |
| `verifies` | Element verifies requirement |
| `refines` | Refines requirement |
| `traces` | Traceability link |

---

## Example: Feature Requirements

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

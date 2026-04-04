<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Introduction

> Sources: [Cockburn 2005](https://alistair.cockburn.us/hexagonal-architecture/) · [Cockburn & Garrido de Paz 2024](https://openlibrary.org/works/OL38388131W) · [AWS](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/hexagonal-architecture.html)

**Goal:** Application equally driveable by users, programs, tests, or batch scripts — developed and tested in isolation from runtime devices and databases.

**Validation:** If you can run the entire application from test fixtures (FIT-style), your hexagonal boundaries are correct.

```mermaid
flowchart TB
    subgraph DriverSide["DRIVER SIDE (Primary / Inbound)"]
        REST["REST API"] --> DriverPorts["DRIVER PORTS\n(Use Case Interfaces)"]
        CLI["CLI"] --> DriverPorts
    end
    subgraph Hexagon["THE HEXAGON"]
        Domain["DOMAIN\n(Business Logic)"]
    end
    subgraph DrivenSide["DRIVEN SIDE (Secondary / Outbound)"]
        DrivenPorts["DRIVEN PORTS\n(Repository Interfaces)"] --> Postgres["Postgres"]
        DrivenPorts --> RabbitMQ["RabbitMQ"]
    end
    DriverPorts --> Domain
    Domain --> DrivenPorts
    style DriverSide fill:#3b82f6,stroke:#2563eb,color:white
    style Hexagon fill:#10b981,stroke:#059669,color:white
    style DrivenSide fill:#f59e0b,stroke:#d97706,color:white
    style Domain fill:#059669,stroke:#047857,color:white
```

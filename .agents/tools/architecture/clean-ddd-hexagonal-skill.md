---
description: Clean Architecture + DDD + Hexagonal patterns for maintainable backend systems
mode: subagent
---
# Clean Architecture + DDD + Hexagonal

DDD tactical patterns, Clean Architecture dependency rules, and Hexagonal ports/adapters. **Start simple. Evolve complexity only when needed.** Decision trees (when-to-use, code placement, entity vs value object): [cheatsheet.md](clean-ddd-hexagonal-skill/cheatsheet.md).

## CRITICAL: The Dependency Rule

Dependencies point **inward only**. Outer layers depend on inner layers, never the reverse.

```text
Infrastructure → Application → Domain
   (adapters)     (use cases)    (core)
```

**Violations to catch:**
- Domain importing database/HTTP libraries
- Controllers calling repositories directly (bypassing use cases)
- Entities depending on application services

**Design validation:** If you can run domain logic from tests with no infrastructure, your boundaries are correct.

## Directory Structure

```text
src/
├── domain/                    # Core business logic (NO external dependencies)
│   ├── {aggregate}/
│   │   ├── entity              # Aggregate root + child entities
│   │   ├── value_objects       # Immutable value types
│   │   ├── events              # Domain events
│   │   ├── repository          # Repository interface (DRIVEN PORT)
│   │   └── services            # Domain services (stateless logic)
│   └── shared/
│       └── errors              # Domain errors
├── application/               # Use cases / Application services
│   ├── {use-case}/
│   │   ├── command             # Command/Query DTOs
│   │   ├── handler             # Use case implementation
│   │   └── port                # Driver port interface
│   └── shared/
│       └── unit_of_work        # Transaction abstraction
├── infrastructure/            # Adapters (external concerns)
│   ├── persistence/           # Database adapters
│   ├── messaging/             # Message broker adapters
│   ├── http/                  # REST/GraphQL adapters (DRIVER)
│   └── config/
│       └── di                  # Dependency injection / composition root
└── main                        # Bootstrap / entry point
```

## DDD Building Blocks

| Pattern | Purpose | Layer | Key Rule |
|---------|---------|-------|----------|
| **Entity** | Identity + behavior | Domain | Equality by ID |
| **Value Object** | Immutable data | Domain | Equality by value, no setters |
| **Aggregate** | Consistency boundary | Domain | Only root is referenced externally |
| **Domain Event** | Record of change | Domain | Past tense naming (`OrderPlaced`) |
| **Repository** | Persistence abstraction | Domain (port) | Per aggregate, not per table |
| **Domain Service** | Stateless logic | Domain | When logic doesn't fit an entity |
| **Application Service** | Orchestration | Application | Coordinates domain + infra |

Anti-patterns (anemic domain, leaking infrastructure, god aggregate): [cheatsheet.md](clean-ddd-hexagonal-skill/cheatsheet.md#common-anti-patterns).

## Implementation Order

1. **Discover the Domain** — Event Storming, domain expert conversations
2. **Model the Domain** — Entities, value objects, aggregates (no infra)
3. **Define Ports** — Repository interfaces, external service interfaces
4. **Implement Use Cases** — Application services coordinating domain
5. **Add Adapters last** — HTTP, database, messaging implementations

## Reference Documentation

| File | Purpose |
|------|---------|
| [clean-ddd-hexagonal-skill/layers.md](clean-ddd-hexagonal-skill/layers.md) | Complete layer specifications |
| [clean-ddd-hexagonal-skill/ddd-strategic.md](clean-ddd-hexagonal-skill/ddd-strategic.md) | Bounded contexts, context mapping |
| [clean-ddd-hexagonal-skill/ddd-tactical.md](clean-ddd-hexagonal-skill/ddd-tactical.md) | Entities, value objects, aggregates (pseudocode) |
| [clean-ddd-hexagonal-skill/hexagonal.md](clean-ddd-hexagonal-skill/hexagonal.md) | Ports, adapters, naming |
| [clean-ddd-hexagonal-skill/cqrs-events.md](clean-ddd-hexagonal-skill/cqrs-events.md) | Command/query separation, events |
| [clean-ddd-hexagonal-skill/testing.md](clean-ddd-hexagonal-skill/testing.md) | Unit, integration, architecture tests |
| [clean-ddd-hexagonal-skill/cheatsheet.md](clean-ddd-hexagonal-skill/cheatsheet.md) | Quick decision guide |

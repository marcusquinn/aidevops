<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Quick Reference Cheatsheet

> See [clean-ddd-hexagonal-skill.md](../clean-ddd-hexagonal-skill.md#sources) for full source list.

## Layer Summary

| Layer | Responsibility | Depends On |
|-------|---------------|------------|
| **Domain** | Business logic, entities, rules | Nothing |
| **Application** | Use cases, orchestration, DTOs, ports | Domain |
| **Infrastructure** | DB repos, API clients, controllers, CLI, messaging | Application, Domain |

*Dependencies point inward. Full layer details: [layers.md](layers.md)*

---

## Quick Decision Trees

### "Where does this code go?"

```text
Is it a business rule or constraint?
├── YES → Domain layer
└── NO ↓

Is it orchestrating a use case?
├── YES → Application layer
└── NO ↓

Is it dealing with external systems (DB, API, UI)?
├── YES → Infrastructure layer
└── NO → Reconsider; probably domain
```

### "Entity or Value Object?"

```text
Does it have a unique identity that persists?
├── YES → Entity
└── NO ↓

Is it defined entirely by its attributes?
├── YES → Value Object
└── NO → Probably an Entity
```

### "Aggregate boundary?"

```text
Must these objects change together atomically?
├── YES → Same aggregate
└── NO ↓

Can one exist without the other?
├── YES → Different aggregates (reference by ID)
└── NO → Probably same aggregate
```

### "Domain Service or Entity method?"

```text
Does it naturally belong to one entity?
├── YES → Entity method
└── NO ↓

Does it require multiple aggregates?
├── YES → Domain Service
└── NO ↓

Is it stateless business logic?
├── YES → Domain Service
└── NO → Reconsider placement
```

---

## Pattern Templates

Compact pseudocode. Full TypeScript examples: [ddd-tactical.md](ddd-tactical.md), [layers.md](layers.md).

### Value Object

```text
class Money (immutable):
  private constructor(amount: number, currency: string)
  static create(amount, currency) → validate → new Money(...)
  add(other: Money) → Money.create(this.amount + other.amount, currency)
  equals(other) → amount == other.amount && currency == other.currency
```

### Entity

```text
class OrderItem extends Entity<OrderItemId>:
  static create(productId, quantity) → new OrderItem(generate_id(), ...)
  increaseQuantity(amount) → mutate internal state
  identity-based equality (same ID = same entity)
```

### Aggregate Root

```text
class Order extends AggregateRoot<OrderId>:
  items: OrderItem[], status: OrderStatus
  static create(customerId) → new Order(...) + emit OrderCreated event
  addItem(productId, quantity, price) → guard state + push item
  confirm() → guard state + require items + emit OrderConfirmed
  private assertCanModify() → throw if cancelled
```

### Repository Interface

```text
interface IOrderRepository:
  findById(id: OrderId) → Order | null
  save(order: Order) → void
  delete(order: Order) → void
```

### Use Case Handler

```text
class PlaceOrderHandler:
  constructor(orderRepo, productRepo, eventPublisher)
  execute(command):
    order = Order.create(command.customerId)
    for item in command.items:
      product = productRepo.findById(item.productId)
      order.addItem(product.id, Quantity(item.quantity), product.price)
    orderRepo.save(order)
    eventPublisher.publishAll(order.domainEvents)
    return order.id
```

---

## Port Naming Conventions

| Type | Pattern | Examples |
|------|---------|----------|
| Driver Port | `I{Action}UseCase` | `IPlaceOrderUseCase`, `IGetOrderUseCase` |
| Driven Port | `I{Resource}Repository` | `IOrderRepository`, `IProductRepository` |
| Driven Port | `I{Action}Service` | `IPaymentService`, `INotificationService` |
| Driven Port | `I{Resource}Gateway` | `IPaymentGateway`, `IShippingGateway` |

---

## Common Anti-Patterns

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Anemic Domain | Entities are just data bags | Put behavior in entities |
| Repository per table | One repo per DB table | One repo per aggregate |
| Fat Use Cases | Business logic in handlers | Move to domain |
| Leaky Abstraction | Domain depends on ORM | Keep domain pure |
| God Aggregate | One massive aggregate | Split into smaller ones |
| Cross-Aggregate TX | Modifying multiple in one TX | Use domain events |
| Direct Layer Skip | Controller → Repository | Go through application layer |
| Premature CQRS | Adding complexity early | Start simple, evolve |
| Event Proliferation | Too many fine-grained events | May signal context boundary |

---

## Dependency Rules Matrix

|  | Domain | Application | Infrastructure |
|--|--------|-------------|----------------|
| **Domain** | ✅ | ❌ | ❌ |
| **Application** | ✅ | ✅ | ❌ |
| **Infrastructure** | ✅ | ✅ | ✅ |

✅ = Can depend on | ❌ = Cannot depend on

---

## Hexagonal Architecture

Driver (inbound) adapters → **Driver Ports** (use case interfaces) → Application Core → **Driven Ports** (repository/service interfaces) → Driven (outbound) adapters.

- **Driver side:** REST controllers, gRPC services, CLI commands, message consumers call ports
- **Driven side:** Database repos, message publishers, external API clients, cache adapters implement ports

Full diagram and patterns: [hexagonal.md](hexagonal.md)

---

## When to Use / Skip

**Use Clean + DDD + Hexagonal when:** complex business domain with many rules, long-lived system (years), large team (5+), need to swap infrastructure, high test coverage required, multiple entry points (API, CLI, events, jobs).

**Skip when:** simple CRUD, prototype/MVP/throwaway, small team (1-2), short-lived project, trivial business logic.

### Complexity Ladder (Start Simple)

```text
Level 1: Simple layered (Controller → Service → Repository)
   ↓ When business rules grow complex
Level 2: Domain model (Entities with behavior)
   ↓ When need multiple entry points
Level 3: Hexagonal (Ports & Adapters)
   ↓ When read/write patterns diverge significantly
Level 4: CQRS (Separate read/write models)
   ↓ When need complete audit trail / temporal queries
Level 5: Event Sourcing (Store events, derive state)
```

**Don't skip levels.** Each adds complexity. Move up only when current level is proven insufficient.

---

## File Naming Conventions

See [layers.md](layers.md) "Domain Layer" section for the canonical directory structure (`domain/`, `application/`, `infrastructure/`).

---

## Resources

### Books

- Clean Architecture (Martin, 2017) · Domain-Driven Design (Evans, 2003)
- Implementing DDD (Vernon, 2013) · Hexagonal Architecture Explained (Cockburn, 2024)
- Get Your Hands Dirty on Clean Architecture (Hombergs, 2019)

### Reference Implementations

- [Go](https://github.com/bxcodec/go-clean-arch) · [Rust](https://github.com/flosse/clean-architecture-with-rust) · [Python](https://github.com/cdddg/py-clean-arch)
- [TypeScript](https://github.com/jbuget/nodejs-clean-architecture-app) · [.NET](https://github.com/jasontaylordev/CleanArchitecture) · [Java](https://github.com/thombergs/buckpal)

### Official Documentation

- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html) · [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
- [DDD Reference](https://www.domainlanguage.com/ddd/) · [Fowler on DDD](https://martinfowler.com/tags/domain%20driven%20design.html)

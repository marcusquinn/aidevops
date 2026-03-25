# CQRS & Domain Events

> Sources: [CQRS](https://martinfowler.com/bliki/CQRS.html) — Fowler | [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) — Fowler | [CQRS Pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/cqrs) — Microsoft | [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html) — microservices.io | [Domain Events – Salvation](https://udidahan.com/2009/06/14/domain-events-salvation/) — Dahan | [Domain Events: Design and Implementation](https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/domain-events-design-implementation) — Microsoft

## CQRS Overview

**Command Query Responsibility Segregation** separates read and write operations into different models.

```mermaid
flowchart TB
    API["API Layer"]
    API --> Commands
    API --> Queries

    subgraph WriteSide["Write Side"]
        Commands --> CmdHandler["Command Handler\n(Use Case)"]
        CmdHandler --> DomainModel["Domain Model\n(Aggregates)"]
        DomainModel --> WriteDB[("Write Database")]
    end

    subgraph ReadSide["Read Side"]
        Queries --> QryHandler["Query Handler\n(Read Model)"]
        QryHandler --> ReadDB[("Read Database\n(Optimized)")]
    end

    WriteDB -->|Domain Events| EventHandler["Event Handler"]
    EventHandler -->|Updates| ReadDB

    style WriteSide fill:#3b82f6,stroke:#2563eb,color:white
    style ReadSide fill:#10b981,stroke:#059669,color:white
    style EventHandler fill:#f59e0b,stroke:#d97706,color:white
```

## Commands vs Queries

### Commands (Write Side)

Commands represent intent to change state. They **mutate** data.

```typescript
// application/commands/place_order_command.ts
export interface PlaceOrderCommand {
  type: 'PlaceOrder';
  customerId: string;
  items: Array<{ productId: string; quantity: number }>;
}

export class PlaceOrderHandler {
  async handle(command: PlaceOrderCommand): Promise<OrderId> {
    const order = Order.create(CustomerId.from(command.customerId));
    for (const item of command.items) {
      const product = await this.productRepo.findById(item.productId);
      order.addItem(product.id, item.quantity, product.price);
    }
    await this.orderRepo.save(order);
    await this.eventPublisher.publishAll(order.domainEvents);
    return order.id;
  }
}
```

### Queries (Read Side)

Queries retrieve data without side effects. They **never mutate** state.

```typescript
// application/queries/get_order_query.ts
export interface OrderDTO {
  id: string;
  customerId: string;
  customerName: string;
  status: string;
  items: Array<{ productId: string; productName: string; quantity: number; unitPrice: number; subtotal: number }>;
  total: number;
  createdAt: string;
  confirmedAt?: string;
}

export class GetOrderHandler {
  constructor(private readonly readDb: IOrderReadModel) {}
  async handle(query: { orderId: string }): Promise<OrderDTO | null> {
    return this.readDb.findById(query.orderId);
  }
}

export class GetOrdersByCustomerHandler {
  constructor(private readonly readDb: IOrderReadModel) {}
  async handle(query: { customerId: string; status?: OrderStatus; page?: number; pageSize?: number }): Promise<PaginatedResult<OrderDTO>> {
    return this.readDb.findByCustomer(query.customerId, query.status, query.page ?? 1, query.pageSize ?? 20);
  }
}
```

## Read Model (Projection)

Optimized database structure for queries. Can denormalize data for performance. Separate write and read databases are optional — write is normalized for transactions, read is denormalized for queries.

```
interface IOrderReadModel:
    findById(orderId: string) -> OrderDTO | null
    findByCustomer(customerId, status?, page?, pageSize?) -> PaginatedResult<OrderDTO>
    search(criteria: OrderSearchCriteria) -> List<OrderDTO>
```

## Domain Events

Notifications that something happened in the domain. Used for updating read models, cross-aggregate communication, and integration with other bounded contexts.

```typescript
// domain/shared/domain_event.ts
export abstract class DomainEvent {
  readonly eventId: string = crypto.randomUUID();
  readonly occurredAt: Date = new Date();
  abstract readonly eventType: string;
  constructor(readonly aggregateId: string) {}
  abstract toPayload(): Record<string, unknown>;
}

// domain/order/events.ts
export class OrderCreated extends DomainEvent {
  readonly eventType = 'order.created';
  constructor(readonly orderId: OrderId, readonly customerId: CustomerId) {
    super(orderId.value);
  }
  toPayload() { return { orderId: this.orderId.value, customerId: this.customerId.value }; }
}

export class OrderConfirmed extends DomainEvent {
  readonly eventType = 'order.confirmed';
  constructor(readonly orderId: OrderId, readonly total: Money, readonly items: ReadonlyArray<{ productId: string; quantity: number }>) {
    super(orderId.value);
  }
  toPayload() { return { orderId: this.orderId.value, total: { amount: this.total.amount, currency: this.total.currency }, items: this.items }; }
}

export class OrderShipped extends DomainEvent {
  readonly eventType = 'order.shipped';
  constructor(readonly orderId: OrderId, readonly trackingNumber: string, readonly carrier: string) {
    super(orderId.value);
  }
  toPayload() { return { orderId: this.orderId.value, trackingNumber: this.trackingNumber, carrier: this.carrier }; }
}
```

### Event Handlers

```
class OrderCreatedHandler:
    handle(event: OrderCreated):
        db.ordersRead.insert({ id: event.orderId.value, customerId: event.customerId.value, status: "draft", createdAt: event.occurredAt })

class OrderConfirmedHandler:
    handle(event: OrderConfirmed):
        db.ordersRead.where(id: event.orderId.value).update({ status: "confirmed", total: event.total.amount, confirmedAt: event.occurredAt })

class SendShippingNotificationHandler:
    async handle(event: OrderShipped):
        order = await orderRepo.findById(OrderId.from(event.orderId.value))
        if !order: return
        await notifier.sendEmail(order.customerEmail, { template: 'order-shipped', data: { orderId: event.orderId.value, trackingNumber: event.trackingNumber, carrier: event.carrier } })
```

## Domain Events vs Integration Events

| | Domain Events | Integration Events |
|--|--------------|-------------------|
| Scope | Within bounded context | Cross bounded context |
| Granularity | Fine-grained, low-level | Coarser-grained |
| Transport | In-process | Message broker |
| Schema | Internal | Versioned |

```typescript
// Domain event — internal, fine-grained
class OrderItemQuantityIncreased extends DomainEvent {
  constructor(readonly orderId: OrderId, readonly productId: ProductId, readonly oldQuantity: number, readonly newQuantity: number) { super(orderId.value); }
}

// Integration event — external, versioned
interface OrderConfirmedIntegrationEvent {
  eventType: 'sales.order.confirmed';
  eventId: string;
  version: '1.0';
  occurredAt: string;
  payload: {
    orderId: string;
    customerId: string;
    total: { amount: number; currency: string };
    items: Array<{ productId: string; quantity: number; unitPrice: number }>;
    shippingAddress: { street: string; city: string; postalCode: string; country: string };
  };
}
```

Publishing integration events from domain events:

```typescript
export class PublishOrderConfirmedIntegrationEvent {
  async handle(domainEvent: OrderConfirmed): Promise<void> {
    const order = await this.orderRepo.findById(domainEvent.orderId);
    if (!order) return;
    await this.messageBroker.publish('order-events', {
      eventType: 'sales.order.confirmed',
      eventId: crypto.randomUUID(),
      version: '1.0',
      occurredAt: new Date().toISOString(),
      payload: {
        orderId: order.id.value,
        customerId: order.customerId.value,
        total: { amount: order.total.amount, currency: order.total.currency },
        items: order.items.map(i => ({ productId: i.productId.value, quantity: i.quantity.value, unitPrice: i.unitPrice.amount })),
        shippingAddress: order.shippingAddress ?? null,
      },
    });
  }
}
```

## Event Dispatcher Pattern

```typescript
// infrastructure/events/event_dispatcher.ts
export class EventDispatcher {
  private handlers: Map<string, IEventHandler<any>[]> = new Map();

  register<T extends DomainEvent>(eventType: string, handler: IEventHandler<T>): void {
    const existing = this.handlers.get(eventType) ?? [];
    this.handlers.set(eventType, [...existing, handler]);
  }

  async dispatch(event: DomainEvent): Promise<void> {
    const handlers = this.handlers.get(event.eventType) ?? [];
    await Promise.all(handlers.map(h => h.handle(event)));
  }

  async dispatchAll(events: DomainEvent[]): Promise<void> {
    for (const event of events) await this.dispatch(event);
  }
}

// Registration
dispatcher.register('order.created', new OrderCreatedHandler(readDb));
dispatcher.register('order.confirmed', new OrderConfirmedHandler(readDb));
dispatcher.register('order.confirmed', new PublishOrderConfirmedIntegrationEvent(broker, orderRepo));
dispatcher.register('order.shipped', new SendShippingNotificationHandler(orderRepo, notifier));
```

## Outbox Pattern

Ensures events are published reliably (exactly-once semantics).

```
class PlaceOrderHandler:
    handle(command: PlaceOrderCommand) -> OrderId:
        order = Order.create(CustomerId.from(command.customerId))
        db.transaction((tx) => {
            orderRepo.save(order, tx)
            for event in order.domainEvents:
                tx.outbox.insert({ id: event.eventId, eventType: event.eventType, payload: serialize(event.toPayload()), createdAt: event.occurredAt })
        })
        return order.id

class OutboxProcessor:
    process():
        messages = db.outbox.where(processedAt: null).orderBy("createdAt").limit(100).lockForUpdate()
        for message in messages:
            try:
                messageBroker.publish(message.eventType, message.payload)
                db.outbox.where(id: message.id).update({processedAt: now()})
            catch error:
                log.error("Failed to process outbox message", message.id)
```

## When to Use CQRS

> **Warning:** "You should be very cautious about using CQRS... the majority of cases I've run into have not been so good." — Martin Fowler

**Use CQRS when:**
- Read and write workloads have dramatically different scaling requirements
- Complex queries that genuinely don't map well to domain model
- Event sourcing is used (CQRS pairs naturally with ES)
- You've proven simpler approaches are insufficient

**Skip CQRS when:**
- Simple CRUD application (most applications)
- Read/write patterns are similar
- Small team, simple domain
- Adding it "just in case"

**CQRS applies to specific bounded contexts, never entire systems.**

**Start simple** — same database, different query paths:

```typescript
class OrderService {
  async placeOrder(cmd: PlaceOrderCommand): Promise<OrderId> {
    const order = Order.create(...);
    await this.orderRepo.save(order);
    return order.id;
  }
  async getOrder(id: string): Promise<OrderDTO | null> {
    return this.readModel.findById(id);
  }
}
```

Evolve to separate databases only when needed.

## Event Sourcing: Critical Considerations

> **Warning:** "Extremely difficult to add Event Sourcing to systems not originally designed for it." — Martin Fowler

**Use when:** Complete audit trail is a business requirement; need to reconstruct state at any point in time; domain is inherently event-driven (financial transactions, workflows).

**Avoid when:** Simple CRUD with no audit requirements; team unfamiliar with event-driven patterns; adding retroactively; no clear business need for temporal queries.

**Requirements:**
1. **Events must store deltas** — not final state, but what changed (enables reversal)
2. **Snapshots for performance** — rebuild from snapshots, not from event 0
3. **External system handling** — disable notifications during replays; cache external query results with timestamps
4. **Schema evolution strategy** — events are forever; plan for versioning

## Saga Pattern (Cross-Aggregate Workflows)

For workflows spanning multiple aggregates, use sagas instead of coordinating via raw domain events.

```
Saga: PlaceOrderSaga
├── Step 1: Reserve inventory (Inventory aggregate)
├── Step 2: Process payment (Payment aggregate)
├── Step 3: Confirm order (Order aggregate)
└── Compensating actions if any step fails
```

- **Choreography:** Each service listens/publishes events (simpler, harder to trace)
- **Orchestration:** Central coordinator manages steps (explicit, easier to debug)

## Idempotent Consumer Pattern

**Required for reliable event processing.** Messages may be delivered more than once.

```
class OrderConfirmedHandler:
    processedIds: Set<string>

    handle(event: OrderConfirmed):
        if event.eventId in processedIds: return
        doWork(event)
        processedIds.add(event.eventId)
```

**Implementation options:** Store processed message IDs in database; use message broker's deduplication features; design handlers to be naturally idempotent.

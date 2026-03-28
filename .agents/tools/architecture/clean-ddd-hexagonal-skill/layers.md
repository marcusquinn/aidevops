# Layer Structure - Complete Reference

> Sources: [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html) (Martin) · [DDD Microservice](https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/ddd-oriented-microservice) (Microsoft) · [Standing on Giants](https://herbertograca.com/2017/09/28/clean-architecture-standing-on-the-shoulders-of-giants/) (Graça)

## The Four Layers

| Layer | Responsibility | Dependencies |
|-------|---------------|--------------|
| **Domain** | Business logic, entities, rules | None (pure) |
| **Application** | Use cases, orchestration | Domain |
| **Infrastructure** | External systems, frameworks | Application, Domain |
| **Presentation** | API/UI entry points | Application |

---

## Domain Layer (Innermost)

Zero external dependencies. Pure business logic only.

**Rules:** No framework imports · No ORM decorators · No infrastructure concerns · Rich behaviour methods

```
domain/
├── order/
│   ├── order.ts                # Aggregate root entity
│   ├── order_item.ts           # Child entity
│   ├── value_objects.ts        # Money, Address, OrderStatus
│   ├── events.ts               # OrderPlaced, OrderShipped
│   ├── repository.ts           # IOrderRepository interface
│   ├── services.ts             # PricingService, DiscountService
│   └── errors.ts               # InsufficientStockError
└── shared/
    ├── entity.ts / aggregate_root.ts / value_object.ts / domain_event.ts
    └── errors.ts               # DomainError base
```

```typescript
// domain/order/order.ts
export class Order extends AggregateRoot<OrderId> {
  private items: OrderItem[] = [];
  private status: OrderStatus = OrderStatus.Draft;

  static create(id: OrderId, customerId: CustomerId): Order {
    const order = new Order(id, customerId);
    order.addDomainEvent(new OrderPlaced(id, customerId));
    return order;
  }

  addItem(product: Product, quantity: number): void {
    if (quantity <= 0) throw new InvalidQuantityError(quantity);
    if (!product.hasStock(quantity)) throw new InsufficientStockError(product.id, quantity);
    const existing = this.items.find(i => i.productId.equals(product.id));
    existing ? existing.increaseQuantity(quantity) : this.items.push(OrderItem.create(product.id, product.price, quantity));
  }

  ship(): void {
    if (this.status !== OrderStatus.Confirmed) throw new InvalidOrderStateError('Cannot ship unconfirmed order');
    this.status = OrderStatus.Shipped;
    this.addDomainEvent(new OrderShipped(this.id));
  }

  get total(): Money { return this.items.reduce((sum, i) => sum.add(i.subtotal), Money.zero()); }
}
```

---

## Application Layer

Orchestrates use cases. Defines ports (interfaces) for infrastructure.

**Rules:** Depends only on Domain · Defines ports · Orchestrates, doesn't implement · Manages transaction boundary

```
application/
├── orders/
│   ├── place_order/
│   │   ├── command.ts          # PlaceOrderCommand DTO
│   │   ├── handler.ts          # PlaceOrderHandler
│   │   └── port.ts             # IPlaceOrderUseCase interface
│   └── get_order/
│       ├── query.ts / handler.ts / result.ts
└── shared/
    ├── unit_of_work.ts / event_publisher.ts / errors.ts
```

```typescript
// application/orders/place_order/handler.ts
export class PlaceOrderHandler implements IPlaceOrderUseCase {
  constructor(
    private readonly orderRepo: IOrderRepository,
    private readonly productRepo: IProductRepository,
    private readonly uow: IUnitOfWork,
    private readonly eventPublisher: IEventPublisher,
  ) {}

  async execute(command: PlaceOrderCommand): Promise<OrderId> {
    await this.uow.begin();
    try {
      const order = Order.create(OrderId.generate(), command.customerId);
      for (const { productId, quantity } of command.items) {
        const product = await this.productRepo.findById(productId);
        if (!product) throw new ProductNotFoundError(productId);
        order.addItem(product, quantity);
      }
      await this.orderRepo.save(order);
      await this.uow.commit();
      await this.eventPublisher.publishAll(order.domainEvents);
      return order.id;
    } catch (error) { await this.uow.rollback(); throw error; }
  }
}
```

---

## Infrastructure Layer

Implements ports. Contains all external concerns (ORM, HTTP, messaging, external APIs).

**Rules:** Implements ports · Contains framework code · Maps Domain ↔ DB/DTO · Easily replaceable

```
infrastructure/
├── persistence/postgres/       # PostgresOrderRepository, migrations/, mappers/
├── persistence/in_memory/      # InMemoryOrderRepository (tests)
├── messaging/rabbitmq/         # RabbitMQEventPublisher
├── external/payment/           # StripePaymentGateway
├── external/shipping/          # FedExShippingService
└── config/
    ├── container.ts            # DI container setup
    └── env.ts
```

```
class PostgresOrderRepository implements IOrderRepository:
    findById(id): row = db.orders.where(id).withRelated("items").first()
                  return row ? OrderMapper.toDomain(row) : null
    save(order):   db.orders.upsert(OrderMapper.toPersistence(order))
    delete(order): db.orders.where(id: order.id.value).delete()
```

---

## Presentation Layer

Entry points. Adapts external requests to application commands/queries. Structure: `rest/controllers/`, `rest/middleware/`, `rest/dto/`, `grpc/`, `graphql/`, `cli/`.

```typescript
// presentation/rest/controllers/order_controller.ts
export class OrderController {
  constructor(
    private readonly placeOrder: IPlaceOrderUseCase,
    private readonly getOrder: IGetOrderUseCase,
  ) {}

  async create(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
      const orderId = await this.placeOrder.execute({
        customerId: req.user.id,
        items: req.body.items.map((i: any) => ({ productId: i.product_id, quantity: i.quantity })),
      });
      res.status(201).json({ id: orderId.value });
    } catch (error) { next(error); }
  }
  // show(): getOrder.execute({ orderId: req.params.id }) → 200/404
}
```

---

## Dependency Flow

```
Presentation ──calls──▶ Application ──uses──▶ Domain (interfaces)
                              ▲                      ▲
Infrastructure ──────implements──────────────────────┘
```

---

## Composition Root

Wire all dependencies at the application entry point (e.g. `infrastructure/config/container.ts`).

| Interface | Implementation |
|-----------|---------------|
| `IOrderRepository` | `PostgresOrderRepository` |
| `IProductRepository` | `PostgresProductRepository` |
| `IUnitOfWork` | `PostgresUnitOfWork` |
| `IEventPublisher` | `RabbitMQEventPublisher` |
| `IPlaceOrderUseCase` | `PlaceOrderHandler` |

---

## Language-Agnostic Structure

| Language | Root | Presentation alias |
|----------|------|--------------------|
| Go | `internal/` | `interfaces/` |
| Rust | `src/` | `presentation/` |
| Python | `src/` | `presentation/` |

All share the same inner folders: `domain/`, `application/`, `infrastructure/`.

# Testing Patterns

> Sources: [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html) · [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/) · [Unit Testing](https://martinfowler.com/bliki/UnitTest.html) · [Test Pyramid](https://martinfowler.com/bliki/TestPyramid.html)

Testing strategies for Clean Architecture + DDD + Hexagonal systems.

**Key principles:**
1. Test behavior, not implementation — focus on what, not how
2. Domain tests need no mocks — domain layer is pure
3. Mock at port boundaries — application tests mock driven ports
4. Integration tests use real infra — test actual database, message broker
5. Fast unit tests, slower integration — run unit tests frequently
6. Test business rules in domain — not in application or infrastructure

## Testing Pyramid

```
E2E Tests          — Few, slow, expensive
Integration Tests  — Some, moderate speed
Unit Tests         — Many, fast, cheap (Domain & Application)
```

---

## Unit Tests

### Domain Layer Tests

Test business logic in isolation. **No mocks needed** — domain has no dependencies.

```typescript
// tests/domain/order/order.test.ts
describe('Order', () => {
  describe('create', () => {
    it('creates order with draft status', () => {
      const order = Order.create(CustomerId.from('cust-123'));
      expect(order.status).toBe(OrderStatus.Draft);
      expect(order.items).toHaveLength(0);
    });

    it('emits OrderCreated event', () => {
      const order = Order.create(CustomerId.from('cust-123'));
      expect(order.domainEvents[0]).toBeInstanceOf(OrderCreated);
    });
  });

  describe('addItem', () => {
    it('adds item to order', () => {
      const order = createDraftOrder();
      order.addItem(ProductId.from('prod-123'), Quantity.create(2), Money.create(10.00, 'USD'));
      expect(order.items).toHaveLength(1);
    });

    it('increases quantity for existing product', () => {
      const order = createDraftOrder();
      order.addItem(ProductId.from('prod-123'), Quantity.create(2), Money.create(10.00, 'USD'));
      order.addItem(ProductId.from('prod-123'), Quantity.create(3), Money.create(10.00, 'USD'));
      expect(order.items[0].quantity.value).toBe(5);
    });

    it('throws when order is cancelled', () => {
      expect(() => {
        createCancelledOrder().addItem(ProductId.from('prod-123'), Quantity.create(1), Money.create(10, 'USD'));
      }).toThrow(InvalidOrderStateError);
    });

    it('throws when quantity is zero', () => {
      expect(() => {
        createDraftOrder().addItem(ProductId.from('prod-123'), Quantity.create(0), Money.create(10, 'USD'));
      }).toThrow(InvalidQuantityError);
    });
  });

  describe('confirm', () => {
    it('changes status to confirmed', () => {
      const order = createOrderWithItems();
      order.confirm();
      expect(order.status).toBe(OrderStatus.Confirmed);
    });

    it('emits OrderConfirmed event', () => {
      const order = createOrderWithItems();
      order.confirm();
      expect(order.domainEvents.filter(e => e instanceof OrderConfirmed)).toHaveLength(1);
    });

    it('throws when order is empty', () => {
      expect(() => createDraftOrder().confirm()).toThrow(EmptyOrderError);
    });

    it('throws when already confirmed', () => {
      expect(() => createConfirmedOrder().confirm()).toThrow(InvalidOrderStateError);
    });
  });

  describe('total', () => {
    it('calculates total from all items', () => {
      const order = createDraftOrder();
      order.addItem(ProductId.from('p1'), Quantity.create(2), Money.create(10, 'USD'));
      order.addItem(ProductId.from('p2'), Quantity.create(1), Money.create(25, 'USD'));
      expect(order.total.amount).toBe(45);
    });

    it('returns zero for empty order', () => {
      expect(createDraftOrder().total.amount).toBe(0);
    });
  });
});

// Test helpers
function createDraftOrder(): Order { return Order.create(CustomerId.from('cust-123')); }
function createOrderWithItems(): Order {
  const order = createDraftOrder();
  order.addItem(ProductId.from('prod-123'), Quantity.create(1), Money.create(10, 'USD'));
  return order;
}
function createConfirmedOrder(): Order {
  const order = createOrderWithItems();
  order.setShippingAddress(createTestAddress());
  order.confirm();
  return order;
}
function createCancelledOrder(): Order {
  const order = createOrderWithItems();
  order.cancel('Test cancellation');
  return order;
}
```

### Value Object Tests

```typescript
// tests/domain/shared/money.test.ts
describe('Money', () => {
  it('creates money with valid amount', () => {
    const money = Money.create(10.50, 'USD');
    expect(money.amount).toBe(10.50);
    expect(money.currency).toBe('USD');
  });

  it('throws for negative amount', () => {
    expect(() => Money.create(-1, 'USD')).toThrow(InvalidMoneyError);
  });

  it('adds two money values with same currency', () => {
    expect(Money.create(10, 'USD').add(Money.create(20, 'USD')).amount).toBe(30);
  });

  it('throws for different currencies', () => {
    expect(() => Money.create(10, 'USD').add(Money.create(10, 'EUR'))).toThrow(CurrencyMismatchError);
  });

  it('equals money with same amount and currency', () => {
    expect(Money.create(10, 'USD').equals(Money.create(10, 'USD'))).toBe(true);
  });
});
```

### Application Layer Tests

Test use cases with mocked ports.

```typescript
// tests/application/place_order/handler.test.ts
describe('PlaceOrderHandler', () => {
  let handler: PlaceOrderHandler;
  let orderRepo: MockOrderRepository;
  let productRepo: MockProductRepository;
  let eventPublisher: MockEventPublisher;

  beforeEach(() => {
    orderRepo = new MockOrderRepository();
    productRepo = new MockProductRepository();
    eventPublisher = new MockEventPublisher();
    handler = new PlaceOrderHandler(orderRepo, productRepo, eventPublisher);
  });

  it('creates order with items and saves', async () => {
    productRepo.addProduct(createTestProduct('prod-1', 10.00));
    productRepo.addProduct(createTestProduct('prod-2', 20.00));

    const orderId = await handler.handle({
      customerId: 'cust-123',
      items: [{ productId: 'prod-1', quantity: 2 }, { productId: 'prod-2', quantity: 1 }],
    });

    const savedOrder = await orderRepo.findById(OrderId.from(orderId));
    expect(savedOrder!.items).toHaveLength(2);
    expect(savedOrder!.total.amount).toBe(40);
  });

  it('publishes domain events', async () => {
    productRepo.addProduct(createTestProduct('prod-1', 10.00));
    await handler.handle({ customerId: 'cust-123', items: [{ productId: 'prod-1', quantity: 1 }] });
    expect(eventPublisher.publishedEvents[0]).toBeInstanceOf(OrderCreated);
  });

  it('throws when product not found', async () => {
    await expect(handler.handle({
      customerId: 'cust-123',
      items: [{ productId: 'nonexistent', quantity: 1 }],
    })).rejects.toThrow(ProductNotFoundError);
  });

  it('rolls back on error', async () => {
    productRepo.addProduct(createTestProduct('prod-1', 10.00));
    orderRepo.simulateErrorOnSave();
    await expect(handler.handle({
      customerId: 'cust-123',
      items: [{ productId: 'prod-1', quantity: 1 }],
    })).rejects.toThrow();
    expect(orderRepo.savedOrders).toHaveLength(0);
  });
});

// Mock implementations
class MockOrderRepository implements IOrderRepository {
  savedOrders: Order[] = [];
  private shouldError = false;

  async findById(id: OrderId): Promise<Order | null> {
    return this.savedOrders.find(o => o.id.equals(id)) ?? null;
  }

  async save(order: Order): Promise<void> {
    if (this.shouldError) throw new Error('Simulated save error');
    this.savedOrders.push(order);
  }

  async delete(order: Order): Promise<void> {
    const index = this.savedOrders.findIndex(o => o.id.equals(order.id));
    if (index >= 0) this.savedOrders.splice(index, 1);
  }

  simulateErrorOnSave(): void { this.shouldError = true; }
}

class MockEventPublisher implements IEventPublisher {
  publishedEvents: DomainEvent[] = [];
  async publish(event: DomainEvent): Promise<void> { this.publishedEvents.push(event); }
  async publishAll(events: DomainEvent[]): Promise<void> { this.publishedEvents.push(...events); }
}
```

---

## Integration Tests

Test adapters with real infrastructure (databases, message brokers).

```typescript
// tests/integration/postgres/order_repository.test.ts
describe('PostgresOrderRepository', () => {
  let pool: Pool;
  let repository: PostgresOrderRepository;

  beforeAll(async () => {
    pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL });
    repository = new PostgresOrderRepository(pool);
  });

  beforeEach(async () => { await pool.query('TRUNCATE orders, order_items CASCADE'); });
  afterAll(async () => { await pool.end(); });

  it('persists and retrieves order', async () => {
    const order = Order.create(CustomerId.from('cust-123'));
    order.addItem(ProductId.from('prod-1'), Quantity.create(2), Money.create(10, 'USD'));
    await repository.save(order);
    const retrieved = await repository.findById(order.id);
    expect(retrieved!.items[0].quantity.value).toBe(2);
  });

  it('updates existing order', async () => {
    const order = Order.create(CustomerId.from('cust-123'));
    order.addItem(ProductId.from('prod-1'), Quantity.create(1), Money.create(10, 'USD'));
    await repository.save(order);
    order.addItem(ProductId.from('prod-2'), Quantity.create(3), Money.create(20, 'USD'));
    await repository.save(order);
    expect((await repository.findById(order.id))!.items).toHaveLength(2);
  });

  it('returns null for nonexistent order', async () => {
    expect(await repository.findById(OrderId.from('nonexistent'))).toBeNull();
  });

  it('removes order from database', async () => {
    const order = Order.create(CustomerId.from('cust-123'));
    await repository.save(order);
    await repository.delete(order);
    expect(await repository.findById(order.id)).toBeNull();
  });
});
```

### API Integration Tests

```typescript
// tests/integration/http/orders_api.test.ts
describe('Orders API', () => {
  let app: Express;
  let pool: Pool;

  beforeAll(async () => {
    pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL });
    app = createApp(pool);
  });

  beforeEach(async () => {
    await db.truncate("orders", "order_items", "products");
    await db.products.insertMany([
      { id: "prod-1", name: "Product 1", price: 1000 },
      { id: "prod-2", name: "Product 2", price: 2000 },
    ]);
  });

  afterAll(async () => { await pool.end(); });

  it('creates order and returns 201', async () => {
    const response = await request(app).post('/orders').send({
      customer_id: 'cust-123',
      items: [{ product_id: 'prod-1', quantity: 2 }, { product_id: 'prod-2', quantity: 1 }],
    });
    expect(response.status).toBe(201);
    expect(response.body.id).toBeDefined();
  });

  it('returns 400 for invalid product', async () => {
    const response = await request(app).post('/orders').send({
      customer_id: 'cust-123',
      items: [{ product_id: 'nonexistent', quantity: 1 }],
    });
    expect(response.status).toBe(400);
    expect(response.body.error).toContain('Product not found');
  });

  it('returns order details', async () => {
    const { body: { id } } = await request(app).post('/orders').send({
      customer_id: 'cust-123',
      items: [{ product_id: 'prod-1', quantity: 2 }],
    });
    const response = await request(app).get(`/orders/${id}`);
    expect(response.status).toBe(200);
    expect(response.body.items).toHaveLength(1);
  });

  it('returns 404 for nonexistent order', async () => {
    expect((await request(app).get('/orders/nonexistent')).status).toBe(404);
  });
});
```

---

## Architecture Tests

Verify architectural rules are followed.

```typescript
// tests/architecture/dependency_rules.test.ts
import { filesOfProject } from 'ts-arch';

describe('Architecture', () => {
  it('domain should not depend on application', async () => {
    await expect(filesOfProject().inFolder('domain').shouldNot().dependOnFiles().inFolder('application')).toPassAsync();
  });

  it('domain should not depend on infrastructure', async () => {
    await expect(filesOfProject().inFolder('domain').shouldNot().dependOnFiles().inFolder('infrastructure')).toPassAsync();
  });

  it('application should not depend on infrastructure', async () => {
    await expect(filesOfProject().inFolder('application').shouldNot().dependOnFiles().inFolder('infrastructure')).toPassAsync();
  });

  it('domain should have no external framework dependencies', async () => {
    await expect(
      filesOfProject().inFolder('domain').shouldNot().dependOnFiles().matchingPattern('node_modules/(express|pg|axios|typeorm)/')
    ).toPassAsync();
  });

  it('repositories should be named *Repository', async () => {
    await expect(filesOfProject().inFolder('domain/**/repository').should().matchPattern('.*Repository\\.ts$')).toPassAsync();
  });

  it('domain events should be named in past tense', async () => {
    await expect(
      filesOfProject().inFolder('domain/**/events').should().matchPattern('.*(Created|Updated|Deleted|Confirmed|Shipped|Cancelled)\\.ts$')
    ).toPassAsync();
  });
});
```

---

## Test Organization

```
tests/
├── unit/
│   ├── domain/
│   │   ├── order/         (order.test.ts, order_item.test.ts, value_objects.test.ts)
│   │   └── shared/        (money.test.ts, email.test.ts)
│   └── application/
│       ├── place_order/   (handler.test.ts)
│       └── confirm_order/ (handler.test.ts)
├── integration/
│   ├── persistence/       (postgres_order_repository.test.ts)
│   ├── messaging/         (rabbitmq_event_publisher.test.ts)
│   └── http/              (orders_api.test.ts)
├── e2e/                   (order_workflow.test.ts)
├── architecture/          (dependency_rules.test.ts)
├── fixtures/              (order_fixtures.ts, product_fixtures.ts)
└── helpers/               (test_database.ts, mock_factories.ts)
```

---

## Test Fixtures & Builders

```typescript
// tests/fixtures/order_fixtures.ts
export class OrderBuilder {
  private customerId: CustomerId = CustomerId.from('default-customer');
  private items: Array<{ productId: ProductId; quantity: Quantity; price: Money }> = [];
  private status: 'draft' | 'confirmed' | 'shipped' | 'cancelled' = 'draft';

  withCustomer(id: string): this { this.customerId = CustomerId.from(id); return this; }

  withItem(productId: string, quantity: number, price: number): this {
    this.items.push({
      productId: ProductId.from(productId),
      quantity: Quantity.create(quantity),
      price: Money.create(price, 'USD'),
    });
    return this;
  }

  confirmed(): this { this.status = 'confirmed'; return this; }

  build(): Order {
    const order = Order.create(this.customerId);
    for (const item of this.items) order.addItem(item.productId, item.quantity, item.price);
    if (this.status === 'confirmed') {
      order.setShippingAddress(new AddressBuilder().build());
      order.confirm();
    }
    order.clearEvents();
    return order;
  }
}

// Usage
const order = new OrderBuilder()
  .withCustomer('cust-123')
  .withItem('prod-1', 2, 10.00)
  .withItem('prod-2', 1, 25.00)
  .confirmed()
  .build();
```

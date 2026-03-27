# Testing Patterns

> Sources: [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html) · [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/) · [Test Pyramid](https://martinfowler.com/bliki/TestPyramid.html)

Testing strategies for Clean Architecture + DDD + Hexagonal systems.

**Key principles:**
1. Test behavior, not implementation
2. Domain tests need no mocks — domain layer is pure
3. Mock at port boundaries — application tests mock driven ports
4. Integration tests use real infra — actual database, message broker
5. Test business rules in domain, not application or infrastructure

## Testing Pyramid

```
E2E Tests          — Few, slow, expensive
Integration Tests  — Some, moderate speed
Unit Tests         — Many, fast, cheap (Domain & Application)
```

---

## Unit Tests

### Domain Layer

No mocks needed — domain has no dependencies.

```typescript
// tests/domain/order/order.test.ts
describe('Order', () => {
  it('creates with draft status and emits OrderCreated', () => {
    const order = Order.create(CustomerId.from('cust-123'));
    expect(order.status).toBe(OrderStatus.Draft);
    expect(order.domainEvents[0]).toBeInstanceOf(OrderCreated);
  });

  it('merges quantity for duplicate product', () => {
    const order = draft();
    order.addItem(ProductId.from('p1'), Quantity.create(2), Money.create(10, 'USD'));
    order.addItem(ProductId.from('p1'), Quantity.create(3), Money.create(10, 'USD'));
    expect(order.items[0].quantity.value).toBe(5);
  });

  it('throws on invalid state transitions', () => {
    expect(() => cancelled().addItem(ProductId.from('p1'), Quantity.create(1), Money.create(10, 'USD'))).toThrow(InvalidOrderStateError);
    expect(() => draft().confirm()).toThrow(EmptyOrderError);
    expect(() => confirmed().confirm()).toThrow(InvalidOrderStateError);
  });

  it('confirms and emits OrderConfirmed', () => {
    const order = withItems();
    order.confirm();
    expect(order.status).toBe(OrderStatus.Confirmed);
    expect(order.domainEvents.filter(e => e instanceof OrderConfirmed)).toHaveLength(1);
  });

  it('calculates total', () => {
    const order = draft();
    order.addItem(ProductId.from('p1'), Quantity.create(2), Money.create(10, 'USD'));
    order.addItem(ProductId.from('p2'), Quantity.create(1), Money.create(25, 'USD'));
    expect(order.total.amount).toBe(45);
  });
});

const draft = () => Order.create(CustomerId.from('cust-123'));

const testAddress = () =>
  new Address({ street: '1 Main St', city: 'Springfield', country: 'US', postcode: '12345' });

const withItems = () => {
  const o = draft();
  o.addItem(ProductId.from('p1'), Quantity.create(1), Money.create(10, 'USD'));
  return o;
};

const confirmed = () => {
  const o = withItems();
  o.setShippingAddress(testAddress());
  o.confirm();
  return o;
};

const cancelled = () => {
  const o = withItems();
  o.cancel('test');
  return o;
};
```

### Value Objects

```typescript
describe('Money', () => {
  it('creates with valid amount', () => { expect(Money.create(10.50, 'USD').amount).toBe(10.50); });
  it('throws for negative amount', () => { expect(() => Money.create(-1, 'USD')).toThrow(InvalidMoneyError); });
  it('adds same-currency values', () => { expect(Money.create(10, 'USD').add(Money.create(20, 'USD')).amount).toBe(30); });
  it('throws for currency mismatch', () => { expect(() => Money.create(10, 'USD').add(Money.create(10, 'EUR'))).toThrow(CurrencyMismatchError); });
});
```

### Application Layer

Test use cases with mocked ports.

```typescript
// tests/application/place_order/handler.test.ts
describe('PlaceOrderHandler', () => {
  let orderRepo: MockOrderRepository;
  let eventPublisher: MockEventPublisher;
  let handler: PlaceOrderHandler;

  beforeEach(() => {
    orderRepo = new MockOrderRepository();
    eventPublisher = new MockEventPublisher();
    const productRepo = new MockProductRepository([new Product(ProductId.from('prod-1'), Money.create(10, 'USD'))]);
    handler = new PlaceOrderHandler(orderRepo, productRepo, eventPublisher);
  });

  it('saves order and publishes OrderCreated', async () => {
    const id = await handler.handle({ customerId: 'cust-123', items: [{ productId: 'prod-1', quantity: 2 }] });
    expect((await orderRepo.findById(OrderId.from(id)))!.items).toHaveLength(1);
    expect(eventPublisher.publishedEvents[0]).toBeInstanceOf(OrderCreated);
  });

  it('throws ProductNotFoundError for unknown product', async () => {
    await expect(handler.handle({ customerId: 'cust-123', items: [{ productId: 'x', quantity: 1 }] })).rejects.toThrow(ProductNotFoundError);
  });

  it('rolls back on save error', async () => {
    orderRepo.simulateErrorOnSave();
    await expect(handler.handle({ customerId: 'cust-123', items: [{ productId: 'prod-1', quantity: 1 }] })).rejects.toThrow();
    expect(orderRepo.savedOrders).toHaveLength(0);
  });
});

// Mock implementations — implement port interfaces, no framework dependencies
class MockOrderRepository implements IOrderRepository {
  savedOrders: Order[] = [];
  private fail = false;
  async findById(id: OrderId): Promise<Order | null> { return this.savedOrders.find(o => o.id.equals(id)) ?? null; }
  async save(order: Order): Promise<void> { if (this.fail) throw new Error('Simulated'); this.savedOrders.push(order); }
  async delete(order: Order): Promise<void> { this.savedOrders.splice(this.savedOrders.findIndex(o => o.id.equals(order.id)), 1); }
  simulateErrorOnSave(): void { this.fail = true; }
}
class MockEventPublisher implements IEventPublisher {
  publishedEvents: DomainEvent[] = [];
  async publish(e: DomainEvent): Promise<void> { this.publishedEvents.push(e); }
  async publishAll(es: DomainEvent[]): Promise<void> { this.publishedEvents.push(...es); }
}
```

---

## Integration Tests

Test adapters with real infrastructure.

```typescript
// tests/integration/postgres/order_repository.test.ts
describe('PostgresOrderRepository', () => {
  let pool: Pool;
  let repo: PostgresOrderRepository;

  beforeAll(async () => { pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL }); repo = new PostgresOrderRepository(pool); });
  beforeEach(async () => { await pool.query('TRUNCATE orders, order_items CASCADE'); });
  afterAll(async () => { await pool.end(); });

  it('persists, retrieves, updates, and deletes', async () => {
    const order = Order.create(CustomerId.from('cust-123'));
    order.addItem(ProductId.from('prod-1'), Quantity.create(2), Money.create(10, 'USD'));
    await repo.save(order);
    expect((await repo.findById(order.id))!.items[0].quantity.value).toBe(2);

    order.addItem(ProductId.from('prod-2'), Quantity.create(1), Money.create(20, 'USD'));
    await repo.save(order);
    expect((await repo.findById(order.id))!.items).toHaveLength(2);

    await repo.delete(order);
    expect(await repo.findById(order.id)).toBeNull();
  });

  it('returns null for nonexistent', async () => { expect(await repo.findById(OrderId.from('x'))).toBeNull(); });
});
```

### API Integration Tests

```typescript
// tests/integration/http/orders_api.test.ts
describe('Orders API', () => {
  let pool: Pool;
  let app: Express;

  beforeAll(async () => { pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL }); app = createApp(pool); });
  beforeEach(async () => {
    await pool.query('TRUNCATE orders, order_items, products CASCADE');
    await pool.query("INSERT INTO products VALUES ('prod-1', 1000)");
  });
  afterAll(async () => { await pool.end(); });

  it('POST /orders → 201 with id', async () => {
    const res = await request(app).post('/orders').send({ customer_id: 'cust-123', items: [{ product_id: 'prod-1', quantity: 2 }] });
    expect(res.status).toBe(201);
    expect(res.body.id).toBeDefined();
  });

  it('POST /orders → 400 for unknown product', async () => {
    expect((await request(app).post('/orders').send({ customer_id: 'cust-123', items: [{ product_id: 'x', quantity: 1 }] })).status).toBe(400);
  });

  it('GET /orders/:id → 200 or 404', async () => {
    const { body: { id } } = await request(app).post('/orders').send({ customer_id: 'cust-123', items: [{ product_id: 'prod-1', quantity: 1 }] });
    expect((await request(app).get(`/orders/${id}`)).status).toBe(200);
    expect((await request(app).get('/orders/nonexistent')).status).toBe(404);
  });
});
```

---

## Architecture Tests

```typescript
// tests/architecture/dependency_rules.test.ts
import { filesOfProject } from 'ts-arch';

describe('Architecture', () => {
  it('domain has no outward dependencies', async () => {
    await expect(filesOfProject().inFolder('domain').shouldNot().dependOnFiles().inFolder('application')).toPassAsync();
    await expect(filesOfProject().inFolder('domain').shouldNot().dependOnFiles().inFolder('infrastructure')).toPassAsync();
    await expect(filesOfProject().inFolder('domain').shouldNot().dependOnFiles().matchingPattern('node_modules/(express|pg|axios|typeorm)/')).toPassAsync();
  });

  it('application has no infrastructure dependency', async () => {
    await expect(filesOfProject().inFolder('application').shouldNot().dependOnFiles().inFolder('infrastructure')).toPassAsync();
  });

  it('naming conventions', async () => {
    await expect(filesOfProject().inFolder('domain/**/repository').should().matchPattern('.*Repository\\.ts$')).toPassAsync();
    await expect(filesOfProject().inFolder('domain/**/events').should().matchPattern('.*(Created|Updated|Deleted|Confirmed|Shipped|Cancelled)\\.ts$')).toPassAsync();
  });
});
```

---

## Test Organization

```
tests/
├── unit/
│   ├── domain/        (order/, shared/)
│   └── application/   (place_order/, confirm_order/)
├── integration/
│   ├── persistence/   (postgres_order_repository.test.ts)
│   ├── messaging/     (rabbitmq_event_publisher.test.ts)
│   └── http/          (orders_api.test.ts)
├── e2e/               (order_workflow.test.ts)
├── architecture/      (dependency_rules.test.ts)
├── fixtures/          (order_fixtures.ts, product_fixtures.ts)
└── helpers/           (test_database.ts, mock_factories.ts)
```

---

## Test Fixtures & Builders

Builder pattern — fluent API, `clearEvents()` after construction so tests start with clean event state.

```typescript
// tests/fixtures/order_fixtures.ts
export class OrderBuilder {
  private customerId = CustomerId.from('default-customer');
  private items: Array<{ productId: ProductId; quantity: Quantity; price: Money }> = [];
  private confirmed = false;  // Builder flag — actual Order uses OrderStatus enum

  withCustomer(id: string): this { this.customerId = CustomerId.from(id); return this; }
  withItem(productId: string, qty: number, price: number): this {
    this.items.push({ productId: ProductId.from(productId), quantity: Quantity.create(qty), price: Money.create(price, 'USD') });
    return this;
  }
  asConfirmed(): this { this.confirmed = true; return this; }

  build(): Order {
    const order = Order.create(this.customerId);
    for (const item of this.items) order.addItem(item.productId, item.quantity, item.price);
    if (this.confirmed) { order.setShippingAddress(new AddressBuilder().build()); order.confirm(); }
    order.clearEvents();
    return order;
  }
}

// new OrderBuilder().withCustomer('cust-123').withItem('prod-1', 2, 10).asConfirmed().build()
```

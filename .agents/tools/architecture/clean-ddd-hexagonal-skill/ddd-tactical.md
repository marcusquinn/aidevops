<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DDD Tactical Patterns

> Sources: [Blue Book](https://www.domainlanguage.com/ddd/blue-book/) (Evans 2003) · [IDDD](https://openlibrary.org/works/OL17392277W) (Vernon 2013) · [Effective Aggregate Design](https://www.dddcommunity.org/library/vernon_2011/) · [Repository Pattern](https://martinfowler.com/eaaCatalog/repository.html) (Fowler)

```mermaid
flowchart TB
    subgraph Aggregate["Aggregate"]
        subgraph AggRoot["Aggregate Root (Entity)"]
            E1["Entity"] E2["Entity"] VO1["Value Object"] VO2["Value Object"] DE["Domain Event"]
        end
    end
    Aggregate -->|Repository| Persistence[("Persistence")]
    style Aggregate fill:#3b82f6,stroke:#2563eb,color:white
    style AggRoot fill:#10b981,stroke:#059669,color:white
    style Persistence fill:#6b7280,stroke:#4b5563,color:white
```

## Entity

Identity-based object. Equal if same ID regardless of attributes.

```
abstract class Entity<ID>:
    id: ID
    equals(other: Entity<ID>) -> bool: return this.id == other.id

class OrderItem extends Entity<OrderItemId>:
    productId: ProductId
    quantity: Quantity
    unitPrice: Money

    static create(productId, quantity, unitPrice) -> OrderItem:
        return new OrderItem(id: OrderItemId.generate(), productId, quantity, unitPrice)

    increaseQuantity(amount: int): this.quantity = this.quantity.add(amount)
    subtotal() -> Money: return this.unitPrice.multiply(this.quantity.value)
```

## Value Object

Attribute-defined, immutable, no identity. Self-validating.

| Value Object | Attributes | Validation |
|--------------|-----------|------------|
| Money | amount, currency | amount >= 0 |
| Email | address | valid format |
| Address | street, city, zip, country | required fields |
| DateRange | start, end | start <= end |
| Quantity | value | value > 0 |

```
abstract class ValueObject<Props>:
    props: Props
    equals(other: ValueObject<Props>) -> bool: return deepEqual(this.props, other.props)

class Money extends ValueObject<{amount, currency}>:
    static create(amount, currency) -> Money:
        guard: amount >= 0
        guard: currency in SUPPORTED_CURRENCIES
        return new Money({amount, currency})

    static zero(currency = "USD") -> Money: return Money.create(0, currency)
    add(other: Money) -> Money:
        guard: this.currency == other.currency
        return Money.create(this.amount + other.amount, this.currency)
    subtract(other: Money) -> Money:
        guard: this.currency == other.currency
        return Money.create(this.amount - other.amount, this.currency)
    multiply(factor: number) -> Money: return Money.create(this.amount * factor, this.currency)

class Email extends ValueObject<{value}>:
    static create(email: string) -> Email:
        normalized = email.lowercase().trim()
        guard: isValidEmailFormat(normalized)
        return new Email({value: normalized})
    domain() -> string: return this.value.split("@")[1]

class OrderId extends ValueObject<{value}>:
    static generate() -> OrderId: return new OrderId({value: generateUUID()})
    static from(value: string) -> OrderId:
        guard: value is not empty
        return new OrderId({value})
```

## Aggregate

Consistency boundary with a single root entry point.

**Rules:** (1) One aggregate root — single entry point. (2) Reference by ID only. (3) One transaction per aggregate — eventual consistency between aggregates. (4) Aggregate enforces its own invariants. (5) Prefer smaller aggregates.

**Sizing heuristics:**

| Metric | Healthy | Warning | Action |
|--------|---------|---------|--------|
| Entities per aggregate | 1-5 | 6-10 | >10: Split |
| Lines of code (root) | <500 | 500-1000 | >1000: Split |
| Transaction lock time | <100ms | 100-500ms | >500ms: Split |
| Concurrent conflicts | Rare | Occasional | Frequent: Split |

```
abstract class AggregateRoot<ID> extends Entity<ID>:
    domainEvents: List<DomainEvent> = []
    version: int = 0
    addDomainEvent(event: DomainEvent): this.domainEvents.append(event)
    clearDomainEvents(): this.domainEvents = []

class Order extends AggregateRoot<OrderId>:
    customerId: CustomerId
    items: List<OrderItem> = []
    status: OrderStatus
    shippingAddress: Address | null
    createdAt: DateTime

    static create(customerId: CustomerId) -> Order:
        order = new Order(id: OrderId.generate(), customerId, status: DRAFT, createdAt: now())
        order.addDomainEvent(OrderCreated{orderId, customerId})
        return order

    static reconstitute(id, customerId, items, status, ...) -> Order:
        return new Order(...)

    addItem(productId, quantity, unitPrice):
        guard: status not in [CANCELLED, SHIPPED]
        guard: quantity > 0
        existingItem = this.items.find(i => i.productId == productId)
        if existingItem: existingItem.increaseQuantity(quantity)
        else: this.items.append(OrderItem.create(productId, quantity, unitPrice))
        this.addDomainEvent(OrderItemAdded{orderId, productId, quantity})

    removeItem(productId):
        guard: status not in [CANCELLED, SHIPPED]
        guard: item exists
        this.items.remove(productId)
        this.addDomainEvent(OrderItemRemoved{orderId, productId})

    confirm():
        guard: status == DRAFT
        guard: items.length > 0
        guard: shippingAddress != null
        this.status = CONFIRMED
        this.addDomainEvent(OrderConfirmed{orderId, total})

    ship(trackingNumber):
        guard: status == CONFIRMED
        this.status = SHIPPED
        this.addDomainEvent(OrderShipped{orderId, trackingNumber})

    cancel(reason: string):
        guard: status not in [SHIPPED, DELIVERED]
        this.status = CANCELLED
        this.addDomainEvent(OrderCancelled{orderId, reason})

    total() -> Money: return this.items.reduce((sum, item) => sum.add(item.subtotal()), Money.zero())
    itemCount() -> int: return this.items.reduce((sum, item) => sum + item.quantity.value, 0)
```

## Repository

Collection-like access to aggregates. Interface in domain, implementation in infrastructure. One repository per aggregate (not per entity/table). Complex queries belong in separate read models.

```
interface OrderRepository:
    findById(id: OrderId) -> Order | null
    findByCustomerId(customerId: CustomerId) -> List<Order>
    save(order: Order)
    delete(order: Order)
    nextId() -> OrderId

interface OrderReadModel:
    findByStatus(status) -> List<OrderSummaryDTO>
    findByDateRange(start, end) -> List<OrderSummaryDTO>
    countByCustomer(customerId) -> int
```

## Domain Event

Immutable record of something significant. Past-tense naming. Contains data needed by consumers.

```
abstract class DomainEvent:
    eventId: string = generateUUID()
    occurredAt: DateTime = now()
    abstract eventType: string
    abstract toPayload() -> Map

class OrderCreated extends DomainEvent:
    eventType = "order.created"
    orderId: OrderId
    customerId: CustomerId
    toPayload(): return {orderId: orderId.value, customerId: customerId.value}

class OrderConfirmed extends DomainEvent:
    eventType = "order.confirmed"
    orderId: OrderId
    total: Money
    toPayload(): return {orderId: orderId.value, total: {amount, currency}}

class OrderShipped extends DomainEvent:
    eventType = "order.shipped"
    orderId: OrderId
    trackingNumber: TrackingNumber
```

## Domain Service

Stateless operations spanning multiple aggregates or requiring external information.

```
interface PricingService:
    calculateDiscount(order: Order, customer: Customer) -> Money

class PricingServiceImpl implements PricingService:
    calculateDiscount(order, customer) -> Money:
        discount = Money.zero()
        if order.itemCount() > 10: discount = discount.add(order.total().multiply(0.05))
        if customer.isVIP: discount = discount.add(order.total().multiply(0.10))
        return min(discount, order.total().multiply(0.20))

interface ShippingCostCalculator:
    calculate(items: List<OrderItem>, destination: Address) -> Money

class ShippingCostCalculatorImpl implements ShippingCostCalculator:
    calculate(items, destination) -> Money:
        total = Money.create(5.99, "USD").add(Money.create(1.50, "USD").multiply(items.length))
        if destination.country != "US": total = total.add(Money.create(15.00, "USD"))
        return total
```

## Factory

Encapsulates complex aggregate creation when invariants must be enforced or object graphs are needed.

```
interface OrderFactory:
    createFromCart(cart: Cart, customer: Customer) -> Order

class OrderFactoryImpl implements OrderFactory:
    pricingService: PricingService

    createFromCart(cart, customer) -> Order:
        guard: not cart.isEmpty
        order = Order.create(customer.id)
        for cartItem in cart.items:
            order.addItem(cartItem.productId, Quantity.create(cartItem.quantity), cartItem.unitPrice)
        if customer.defaultAddress: order.setShippingAddress(customer.defaultAddress)
        return order
```

## Specification Pattern

Encapsulates composable business rules for querying or validation.

```
interface Specification<T>:
    isSatisfiedBy(candidate: T) -> bool
    and(other: Specification<T>) -> Specification<T>
    or(other: Specification<T>) -> Specification<T>
    not() -> Specification<T>

class OrderOverValueSpec implements Specification<Order>:
    minValue: Money
    isSatisfiedBy(order) -> bool: return order.total().amount >= minValue.amount

class OrderHasItemsSpec implements Specification<Order>:
    isSatisfiedBy(order) -> bool: return order.items.length > 0

canShipFree = OrderOverValueSpec(Money.create(100, "USD")).and(OrderHasItemsSpec())
if canShipFree.isSatisfiedBy(order): applyFreeShipping()
```

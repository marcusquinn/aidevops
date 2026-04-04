<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Adapters

**Driver adapter** — converts external input → port call:

```typescript
// infrastructure/adapters/driver/rest/order_controller.ts
export class OrderController {
  constructor(private readonly placeOrder: IPlaceOrderPort, private readonly getOrder: IGetOrderPort) {}
  async create(req: Request, res: Response): Promise<void> {
    const orderId = await this.placeOrder.execute({
      customerId: req.user.id,
      items: req.body.items.map((i: any) => ({ productId: i.product_id, quantity: i.quantity })),
    });
    res.status(201).json({ id: orderId.value });
  }
}
```

**Driven adapters** — implement port interface using specific technology:

```
class PostgresOrderRepository implements IOrderRepositoryPort:
    findById(id) -> Order | null:
        row = db.orders.where(id: id.value).first()
        return row ? OrderMapper.toDomain(row) : null
    save(order): db.orders.upsert(OrderMapper.toPersistence(order))
    delete(order): db.orders.where(id: order.id.value).delete()

class InMemoryOrderRepository implements IOrderRepositoryPort:  # for tests
    orders: Map<string, Order> = {}
    findById(id): return orders.get(id.value) or null
    save(order): orders.set(order.id.value, order)
    delete(order): orders.delete(order.id.value)

class StripePaymentGateway implements IPaymentGatewayPort:
    charge(amount, method) -> PaymentResult:
        intent = stripe.paymentIntents.create({amount: amount.cents, ...})
        return PaymentResult.success(PaymentId.from(intent.id))
    refund(paymentId, amount): stripe.refunds.create({paymentIntent: paymentId.value, ...})

class RabbitMQEventPublisher implements IEventPublisherPort:
    publish(event): channel.publish("domain_events", event.eventType, serialize(event))
    publishAll(events): for event in events: publish(event)
```

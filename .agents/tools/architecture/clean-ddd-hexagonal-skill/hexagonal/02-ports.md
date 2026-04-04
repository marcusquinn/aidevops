<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Ports

| Type | Direction | Defined by | Purpose | Asymmetry |
|------|-----------|------------|---------|-----------|
| **Driver** (Primary / Inbound) | → App | Application | How the world uses your app (use cases) | Adapter *calls* port — app defines what it **offers** |
| **Driven** (Secondary / Outbound) | App → | Application | What your app needs from external systems | Adapter *implements* port — app defines what it **needs** |

```typescript
// Driver ports — called by adapters, represent use cases
export interface IPlaceOrderPort { execute(command: PlaceOrderCommand): Promise<OrderId>; }
export interface IGetOrderPort { execute(query: GetOrderQuery): Promise<OrderDTO | null>; }
export interface ICancelOrderPort { execute(command: CancelOrderCommand): Promise<void>; }

// Driven ports — implemented by adapters, called by the application
export interface IOrderRepositoryPort {
  findById(id: OrderId): Promise<Order | null>;
  save(order: Order): Promise<void>;
  delete(order: Order): Promise<void>;
}
export interface IEventPublisherPort {
  publish(event: DomainEvent): Promise<void>;
  publishAll(events: DomainEvent[]): Promise<void>;
}
export interface IPaymentGatewayPort {
  charge(amount: Money, method: PaymentMethod): Promise<PaymentResult>;
  refund(paymentId: PaymentId, amount: Money): Promise<RefundResult>;
}
```

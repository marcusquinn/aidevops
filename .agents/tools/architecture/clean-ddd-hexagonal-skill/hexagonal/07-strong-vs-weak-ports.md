<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Strong vs Weak Ports

```typescript
// ❌ Weak: leaks SQL concepts into the port
interface IOrderRepository {
  findByQuery(sql: string, params: any[]): Promise<Order[]>;
}

// ✅ Strong: pure domain concepts only
interface IOrderRepository {
  findById(id: OrderId): Promise<Order | null>;
  findByCustomer(customerId: CustomerId): Promise<Order[]>;
  save(order: Order): Promise<void>;
}
```

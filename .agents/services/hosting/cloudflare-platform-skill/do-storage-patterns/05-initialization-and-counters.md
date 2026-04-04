<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Initialization and Counters

## Initialization Pattern

```typescript
export class Counter extends DurableObject {
  value: number;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => { this.value = (await ctx.storage.get("value")) || 0; });
  }
  async increment() {
    this.value++;
    this.ctx.storage.put("value", this.value); // Don't await (output gate protects)
    return this.value;
  }
}
```

## Safe Counter / Optimized Write

```typescript
// Input gate blocks other requests
async getUniqueNumber(): Promise<number> {
  let val = await this.ctx.storage.get("counter");
  await this.ctx.storage.put("counter", val + 1);
  return val;
}

// No await on write - output gate delays response until write confirms
async increment(): Promise<Response> {
  let val = await this.ctx.storage.get("counter");
  this.ctx.storage.put("counter", val + 1);
  return new Response(String(val));
}
```

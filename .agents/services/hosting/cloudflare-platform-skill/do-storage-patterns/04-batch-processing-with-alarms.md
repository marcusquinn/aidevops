# Batch Processing with Alarms

```typescript
export class BatchProcessor extends DurableObject {
  pending: string[] = [];
  async addItem(item: string) {
    this.pending.push(item);
    if (!await this.ctx.storage.getAlarm()) await this.ctx.storage.setAlarm(Date.now() + 5000);
  }
  async alarm() {
    const items = [...this.pending];
    this.pending = [];
    this.sql.exec(`INSERT INTO processed_items (item, timestamp) VALUES ${items.map(() => "(?, ?)").join(", ")}`, ...items.flatMap(item => [item, Date.now()]));
  }
}
```

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Rate Limiting

```typescript
export class RateLimiter extends DurableObject {
  async checkLimit(key: string, limit: number, window: number): Promise<boolean> {
    const now = Date.now();
    this.sql.exec('DELETE FROM requests WHERE key = ? AND timestamp < ?', key, now - window);
    const count = this.sql.exec('SELECT COUNT(*) as count FROM requests WHERE key = ?', key).one().count;
    if (count >= limit) return false;
    this.sql.exec('INSERT INTO requests (key, timestamp) VALUES (?, ?)', key, now);
    return true;
  }
}
```

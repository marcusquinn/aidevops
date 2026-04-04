<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cleanup

```typescript
async cleanup() {
  await this.ctx.storage.deleteAlarm(); // Separate from deleteAll
  await this.ctx.storage.deleteAll();
}
```

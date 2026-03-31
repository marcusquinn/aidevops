# Schema Migration

```typescript
export class MyDurableObject extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS _meta(key TEXT PRIMARY KEY, value TEXT)`);
    const ver = this.sql.exec("SELECT value FROM _meta WHERE key = 'schema_version'").toArray()[0]?.value || "0";
    if (ver === "0") this.sql.exec(`CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT); INSERT OR REPLACE INTO _meta VALUES ('schema_version', '1')`);
    if (ver === "1") this.sql.exec(`ALTER TABLE users ADD COLUMN email TEXT; UPDATE _meta SET value = '2' WHERE key = 'schema_version'`);
  }
}
```

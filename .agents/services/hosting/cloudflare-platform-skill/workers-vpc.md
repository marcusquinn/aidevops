# Cloudflare Workers VPC Skill

Expert guidance for connecting Cloudflare Workers to private networks (AWS/Azure/GCP/on-prem) using TCP Sockets, Cloudflare Tunnel, and related technologies.

## What is Workers VPC Connectivity?

Workers VPC connectivity enables Workers to communicate with resources in private networks through:

1. **TCP Sockets API** (`connect()`) - Direct outbound TCP connections from Workers
2. **Cloudflare Tunnel** - Secure connections to private networks without exposing public IPs
3. **Hyperdrive** - Optimized connections to external databases with pooling
4. **Smart Placement** - Automatic Worker placement near backend services

## Core APIs

### TCP Sockets (`connect()`)

```typescript
import { connect } from 'cloudflare:sockets';

export default {
  async fetch(req: Request): Promise<Response> {
    const socket = connect({
      hostname: "internal-db.private.com",
      port: 5432
    }, {
      secureTransport: "starttls" // or "on" for immediate TLS
    });

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();

    await writer.write(new TextEncoder().encode("QUERY\r\n"));
    await writer.close();

    const { value } = await reader.read();
    await socket.close();
    return new Response(value);
  }
};
```

### Type Reference

```typescript
interface SocketOptions {
  secureTransport?: "off" | "on" | "starttls"; // Default: "off"
  allowHalfOpen?: boolean; // Default: false
}

interface SocketAddress {
  hostname: string;
  port: number;
}

interface Socket {
  readable: ReadableStream<Uint8Array>;
  writable: WritableStream<Uint8Array>;
  opened: Promise<SocketInfo>;
  closed: Promise<void>;
  close(): Promise<void>;
  startTls(): Socket; // Upgrade to TLS
}
```

## Common Use Cases

### Connect to Internal Database

```typescript
import { connect } from 'cloudflare:sockets';

export default {
  async fetch(req: Request) {
    const socket = connect(
      { hostname: "10.0.1.50", port: 5432 },
      { secureTransport: "on" }
    );

    try {
      await socket.opened;
      const writer = socket.writable.getWriter();
      await writer.write(new TextEncoder().encode("SELECT 1\n"));
      await writer.close();
      return new Response(socket.readable);
    } catch (error) {
      return new Response(`Connection failed: ${error}`, { status: 500 });
    } finally {
      await socket.close();
    }
  }
};
```

### StartTLS Pattern (Opportunistic TLS)

Many databases start insecure then upgrade:

```typescript
const socket = connect(
  { hostname: "postgres.internal", port: 5432 },
  { secureTransport: "starttls" }
);

const writer = socket.writable.getWriter();
await writer.write(new TextEncoder().encode("STARTTLS\n"));

// Upgrade to TLS
const secureSocket = socket.startTls();
const secureWriter = secureSocket.writable.getWriter();
await secureWriter.write(new TextEncoder().encode("AUTH\n"));
```

### Error Handling Pattern

```typescript
async function connectToPrivateService(host: string, port: number, data: string): Promise<string> {
  let socket: ReturnType<typeof connect> | null = null;

  try {
    socket = connect({ hostname: host, port }, { secureTransport: "on" });
    await socket.opened;

    const writer = socket.writable.getWriter();
    await writer.write(new TextEncoder().encode(data));
    await writer.close();

    const reader = socket.readable.getReader();
    const chunks: Uint8Array[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
    }

    const combined = new Uint8Array(chunks.reduce((acc, c) => acc + c.length, 0));
    let offset = 0;
    chunks.forEach(c => { combined.set(c, offset); offset += c.length; });
    return new TextDecoder().decode(combined);
  } catch (error) {
    throw new Error(`Socket error: ${error}`);
  } finally {
    if (socket) await socket.close();
  }
}
```

## Integration with Cloudflare Tunnel

```
Worker → TCP Socket → Cloudflare Tunnel → Private Network
```

**Setup:**

```bash
# On private network server
cloudflared tunnel create my-private-network
cloudflared tunnel route ip add 10.0.0.0/24 my-private-network
```

```yaml
# config.yml
tunnel: <TUNNEL_ID>
credentials-file: /path/to/credentials.json

ingress:
  - hostname: db.internal.example.com
    service: tcp://10.0.1.50:5432
  - hostname: api.internal.example.com
    service: http://10.0.1.100:8080
  - service: http_status:404
```

```typescript
// Connect from Worker through Tunnel
const socket = connect({
  hostname: "db.internal.example.com",
  port: 5432
}, { secureTransport: "on" });
```

## Wrangler Configuration

```toml
# wrangler.toml
name = "private-network-worker"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[vars]
DB_HOST = "10.0.1.50"
DB_PORT = "5432"

[placement]
mode = "smart"  # Auto-locate Worker near backend services
```

```typescript
interface Env { DB_HOST: string; DB_PORT: string; }

export default {
  async fetch(req: Request, env: Env) {
    const socket = connect({
      hostname: env.DB_HOST,
      port: parseInt(env.DB_PORT)
    });
    // ...
  }
};
```

## Hyperdrive for Databases

For PostgreSQL/MySQL, prefer Hyperdrive over raw TCP sockets (better performance, connection pooling):

```toml
[[hyperdrive]]
binding = "DB"
id = "<HYPERDRIVE_ID>"
```

```typescript
import { Client } from 'pg';

export default {
  async fetch(req: Request, env: { DB: Hyperdrive }) {
    const client = new Client({ connectionString: env.DB.connectionString });
    await client.connect();
    const result = await client.query('SELECT * FROM users');
    await client.end();
    return Response.json(result.rows);
  }
};
```

## Limits and Considerations

### TCP Socket Limits

- **Max simultaneous connections:** 6 per Worker execution
- **Blocked destinations:** Cloudflare IPs, `localhost`/`127.0.0.1`, port 25 (SMTP), Worker's own URL
- **Scope:** Sockets must be created in handlers (fetch/scheduled/queue), not global scope

```typescript
// ❌ BAD: Creating socket in global scope
// const globalSocket = connect({ hostname: "db", port: 5432 }); // ERROR

// ✅ GOOD: Create in handler
export default {
  async fetch(req: Request) {
    const socket = connect({ hostname: "db", port: 5432 });
    await socket.close();
  }
};
```

### Security — Validate Destinations

```typescript
function isAllowedHost(hostname: string): boolean {
  const allowed = [
    'internal-db.company.com',
    'api.private.net',
    /^10\.0\.1\.\d+$/
  ];
  return allowed.some(p => p instanceof RegExp ? p.test(hostname) : p === hostname);
}
```

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `proxy request failed, cannot connect to the specified address` | Disallowed address (Cloudflare IPs, localhost) | Use public addresses or Tunnel endpoints |
| `TCP Loop detected` | Worker connecting back to itself | Ensure destination is external |
| `Connections to port 25 are prohibited` | SMTP on port 25 | Use [Email Workers](https://developers.cloudflare.com/email-routing/email-workers/) |
| `socket is not open` | Read/write after socket closed | Use try/finally with close() |

## Best Practices

1. **Always close sockets** in a `finally` block
2. **Use Hyperdrive for databases** — better performance, connection pooling
3. **Validate destinations** — prevent connections to unintended hosts
4. **Handle errors gracefully** — catch on `socket.opened`, return 503 on failure
5. **Use Smart Placement** for latency-sensitive applications
6. **Prefer `fetch()` for HTTP** — use TCP sockets only when necessary

## Reference

- [TCP Sockets Documentation](https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Hyperdrive](https://developers.cloudflare.com/hyperdrive/)
- [Smart Placement](https://developers.cloudflare.com/workers/configuration/smart-placement/)
- [Email Workers](https://developers.cloudflare.com/email-routing/email-workers/)

---

This skill focuses exclusively on connecting Workers to private networks and VPCs. For general Workers development, see the `cloudflare-workers` skill.

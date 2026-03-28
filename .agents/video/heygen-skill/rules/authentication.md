---
name: authentication
description: API key setup, X-Api-Key header, and authentication patterns for HeyGen
metadata:
  tags: authentication, api-key, headers, security
---

# HeyGen Authentication

All requests require an API key in the `X-Api-Key` header.

## Setup

1. Log in at https://app.heygen.com → Settings > API → copy your key
2. Store as environment variable:

```bash
export HEYGEN_API_KEY="your-api-key-here"   # shell
# or in .env: HEYGEN_API_KEY=your-api-key-here
```

## Making Authenticated Requests

### curl

```bash
curl -X GET "https://api.heygen.com/v2/avatars" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

### TypeScript (fetch)

```typescript
const response = await fetch("https://api.heygen.com/v2/avatars", {
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
});
const { data } = await response.json();
```

### Python

```python
import os, requests

response = requests.get(
    "https://api.heygen.com/v2/avatars",
    headers={"X-Api-Key": os.environ["HEYGEN_API_KEY"]}
)
data = response.json()
```

The pattern is identical for any HTTP client — set `X-Api-Key` header to your key.

## Reusable API Client

```typescript
class HeyGenClient {
  constructor(private apiKey: string, private baseUrl = "https://api.heygen.com") {}

  async request<T>(endpoint: string, options: RequestInit = {}): Promise<T> {
    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      ...options,
      headers: { "X-Api-Key": this.apiKey, "Content-Type": "application/json", ...options.headers },
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || `HTTP ${response.status}`);
    }
    return response.json();
  }

  get<T>(endpoint: string) { return this.request<T>(endpoint); }
  post<T>(endpoint: string, body: unknown) {
    return this.request<T>(endpoint, { method: "POST", body: JSON.stringify(body) });
  }
}

// Usage
const client = new HeyGenClient(process.env.HEYGEN_API_KEY!);
const avatars = await client.get("/v2/avatars");
```

## API Response Format

```typescript
interface ApiResponse<T> {
  error: null | string;  // null on success, message on failure
  data: T;               // payload on success, null on failure
}
```

Example error: `{ "error": "Invalid API key", "data": null }`

## Error Handling

| Status | Error | Cause |
|--------|-------|-------|
| 401 | Invalid API key | Key missing or incorrect |
| 403 | Forbidden | Insufficient permissions |
| 429 | Rate limit exceeded | Too many requests — use exponential backoff |

## Rate Limiting

Standard limits per API key; video generation endpoints are stricter. Retry 429s with exponential backoff:

```typescript
async function requestWithRetry(fn: () => Promise<Response>, maxRetries = 3): Promise<Response> {
  for (let i = 0; i < maxRetries; i++) {
    const response = await fn();
    if (response.status !== 429) return response;
    await new Promise((r) => setTimeout(r, Math.pow(2, i) * 1000));
  }
  throw new Error("Max retries exceeded");
}
```

## Security Best Practices

1. **Never expose API keys in client-side code** — always call from a backend server
2. **Use environment variables** — never hardcode keys in source code
3. **Rotate keys periodically** — generate new keys on a regular schedule
4. **Monitor usage** — check your HeyGen dashboard for unusual activity

---
name: authentication
description: API key setup, X-Api-Key header, and authentication patterns for HeyGen
metadata:
  tags: authentication, api-key, headers, security
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# HeyGen Authentication

All requests require an API key in the `X-Api-Key` header. Keep it server-side, load it from an environment variable, never expose it in client code.

## Security Rules

1. **Keep keys server-side** — route requests through a backend service
2. **Use environment variables** — never hardcode keys in source
3. **Rotate keys periodically** — replace old keys on a regular schedule
4. **Monitor usage** — review the HeyGen dashboard for unusual activity

## Setup

1. Log in at https://app.heygen.com → Settings > API and copy the key.
2. Store as an environment variable:

```bash
export HEYGEN_API_KEY="your-api-key-here"   # shell
# or in .env: HEYGEN_API_KEY=your-api-key-here
```

## Request Pattern

Send `X-Api-Key` on every request (curl / TypeScript / Python):

```bash
curl -X GET "https://api.heygen.com/v2/avatars" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

```typescript
const response = await fetch("https://api.heygen.com/v2/avatars", {
  headers: { "X-Api-Key": process.env.HEYGEN_API_KEY! },
});
const { data } = await response.json();
```

```python
import os, requests

response = requests.get(
    "https://api.heygen.com/v2/avatars",
    headers={"X-Api-Key": os.environ["HEYGEN_API_KEY"]}
)
data = response.json()
```

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

const client = new HeyGenClient(process.env.HEYGEN_API_KEY!);
const avatars = await client.get("/v2/avatars");
```

## Response Shape

`{ error: null, data: ... }` on success; `{ error: "Invalid API key", data: null }` on auth failure.

```typescript
interface ApiResponse<T> {
  error: null | string;  // null on success, message on failure
  data: T;               // payload on success, null on failure
}
```

## Errors & Rate Limits

| Status | Error | Cause |
|--------|-------|-------|
| 401 | Invalid API key | Key missing or incorrect |
| 403 | Forbidden | Insufficient permissions |
| 429 | Rate limit exceeded | Too many requests — use exponential backoff |

Video generation endpoints have stricter rate limits. Retry 429 with exponential backoff:

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

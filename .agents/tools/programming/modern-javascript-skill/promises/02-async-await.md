<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Async/Await

```javascript
async function getUserData(userId) {
  try {
    const user = await fetchUser(userId);
    const posts = await fetchPosts(user.id);
    return { user, posts };
  } catch (error) {
    throw error;
  }
}
```

## Error Handling Patterns

```javascript
// try/catch
try { return await riskyOp(); } catch { return defaultValue; }

// Error-first return (Go-style)
async function safe() {
  try { return [null, await riskyOp()]; }
  catch (e) { return [e, null]; }
}
const [err, data] = await safe();

// Wrapper utility
const to = p => p.then(d => [null, d]).catch(e => [e, null]);
const [err, user] = await to(fetchUser(id));
```

## Top-Level Await (ES2022, ES modules only)

```javascript
const config = await loadConfig();
export const db = await connectDatabase(config);
```

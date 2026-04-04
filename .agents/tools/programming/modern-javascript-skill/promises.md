<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Promises and Async/Await

Reference index for Promise fundamentals, `async`/`await`, combinators, and common traps.

## Contents

| File | Focus |
|------|-------|
| [modern-javascript-skill/promises/01-promise-creation.md](promises/01-promise-creation.md) | Creating promises with constructors, shortcuts, and `Promise.withResolvers()` |
| [modern-javascript-skill/promises/02-async-await.md](promises/02-async-await.md) | `async`/`await`, error handling patterns, top-level await |
| [modern-javascript-skill/promises/03-promise-combinators.md](promises/03-promise-combinators.md) | `Promise.all`, `allSettled`, `race`, and `any` |
| [modern-javascript-skill/promises/04-anti-patterns.md](promises/04-anti-patterns.md) | Common mistakes and the preferred fixes |

## When to read what

- Need to create or expose a promise? Start with `promises/01-promise-creation.md`.
- Need sequential async flow or module-level `await`? Start with `promises/02-async-await.md`.
- Need parallelism, timeouts, or fallback sources? Start with `promises/03-promise-combinators.md`.
- Debugging awkward async code? Check `promises/04-anti-patterns.md`.

## Scope

This index keeps the Promise material discoverable without compressing the reference examples.

# Immutability and Pure Functions

Copy instead of mutating. Keep transforms pure, push I/O to the edge.

## Quick Reference

| Need | Prefer |
|------|--------|
| Append/prepend array items | `[...arr, item]`, `[item, ...arr]` |
| Remove/update array items | `.filter()`, `.toSpliced()`, `.with()` |
| Sort/reverse without mutation | `.toSorted()`, `.toReversed()` |
| Update object fields | `{ ...obj, key: value }` |
| Update nested objects | nested spread (`{ ...obj, nested: { ...obj.nested, key: value } }`) |
| Deep clone | `structuredClone(obj)` |
| Make functions testable | inject time, randomness, and I/O dependencies |
| Update UI state | `.map()`, `.filter()`, small helpers like `setIn()` |

## Non-Mutating Array Updates

```javascript
const nums = [1, 2, 3, 4, 5];

const withSix      = [...nums, 6];                   // append
const withZero     = [0, ...nums];                   // prepend
const withoutThree = nums.filter(n => n !== 3);      // remove by value
const withoutSecond = nums.toSpliced(1, 1);          // remove by index (ES2023)
const updated      = nums.with(2, 99);               // replace at index (ES2023)
const doubled      = nums.with(2, nums.at(2) * 2);   // transform at index
const sorted       = nums.toSorted((a, b) => b - a); // sort (ES2023)
const reversed     = nums.toReversed();              // reverse (ES2023)
```

## Non-Mutating Object Updates

```javascript
const user = { name: 'Alice', age: 30, address: { city: 'NYC' } };

const older      = { ...user, age: 31 };                                      // update property
const withZip    = { ...user, address: { ...user.address, zip: '10001' } };   // update nested
const { age, ...userWithoutAge } = user;                                      // remove property
const { name: fullName, ...rest } = user;                                     // rename property
const renamed    = { fullName, ...rest };
const maybeAdmin = { ...user, ...(isAdmin && { role: 'admin' }) };            // conditional property

const clone = structuredClone(obj); // deep clone (handles circular refs, preserves types)
```

## Pure Functions

```javascript
// ✅ Pure: deterministic, no side effects
const formatUser = (user) => ({
  displayName: `${user.firstName} ${user.lastName}`,
  initials: `${user.firstName[0]}${user.lastName[0]}`
});

// ❌ Impure: external state, non-determinism, side effects
let counter = 0;
function increment() { return ++counter; }            // mutates external state
function rand(arr) { return arr[Math.floor(Math.random() * arr.length)]; } // non-deterministic
function save(u) { localStorage.setItem('u', JSON.stringify(u)); }         // side effect

// Inject dependencies to make impure functions testable
const isExpired = (token, now) => token.expiresAt < now;
isExpired(token, Date.now());

const shuffle = (array, random = Math.random) =>
  array.toSorted(() => random() - 0.5);   // ES2023 non-mutating
shuffle(items);           // random in production
shuffle(items, () => 0.5); // deterministic in tests
```

## State Updates (React/Redux)

```javascript
const addTodo    = (todos, todo) => [...todos, todo];
const removeTodo = (todos, id)  => todos.filter(t => t.id !== id);
const updateTodo = (todos, id, updates) =>
  todos.map(t => t.id === id ? { ...t, ...updates } : t);
const toggleTodo = (todos, id) =>
  todos.map(t => t.id === id ? { ...t, done: !t.done } : t);
const moveTodo   = (todos, from, to) => {
  const result = todos.toSpliced(from, 1);
  return result.toSpliced(to, 0, todos[from]);
};

// Deep nested state update helper
const setIn = (obj, path, value) => {
  const [head, ...rest] = path;
  if (rest.length === 0) return { ...obj, [head]: value };
  return { ...obj, [head]: setIn(obj[head] ?? {}, rest, value) };
};

const newState = setIn(state, ['users', 'u1', 'profile', 'name'], 'Alice');
```

## Best Practices

- **`const` by default** — prevent accidental reassignment
- **Never mutate parameters** — always return new objects
- **Separate pure logic from I/O** — extract side effects to boundaries
- **Inject non-determinism** — pass `Date.now`, `Math.random` as params for testability
- **Optional chaining** — `obj?.nested?.value` instead of manual guards

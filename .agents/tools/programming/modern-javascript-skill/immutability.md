# Immutability and Pure Functions

Never modify data in place. Same input → same output, no side effects. Prefer declarative style.

## Immutable Array Operations

```javascript
const nums = [1, 2, 3, 4, 5];

const withSix = [...nums, 6];                          // Append
const withZero = [0, ...nums];                         // Prepend
const withoutThree = nums.filter(n => n !== 3);        // Remove by value
const withoutSecond = nums.toSpliced(1, 1);            // Remove by index (ES2023)
const updated = nums.with(2, 99);                      // Replace at index (ES2023)
const doubled = nums.with(2, nums.at(2) * 2);         // Transform at index
const sorted = nums.toSorted((a, b) => b - a);        // Non-mutating sort (ES2023)
const reversed = nums.toReversed();                    // Non-mutating reverse (ES2023)
```

## Immutable Object Operations

```javascript
const user = { name: 'Alice', age: 30, address: { city: 'NYC' } };

const older = { ...user, age: 31 };                                    // Update property
const withZip = { ...user, address: { ...user.address, zip: '10001' } }; // Update nested
const { age, ...userWithoutAge } = user;                               // Remove property
const { name: fullName, ...rest } = user;                              // Rename property
const renamed = { fullName, ...rest };
const maybeAdmin = { ...user, ...(isAdmin && { role: 'admin' }) };     // Conditional property

// Deep clone (handles circular refs, preserves types)
const clone = structuredClone(obj);
```

## Pure Functions

```javascript
// ✅ Pure: deterministic, no side effects
const formatUser = (user) => ({
  displayName: `${user.firstName} ${user.lastName}`,
  initials: `${user.firstName[0]}${user.lastName[0]}`
});

// ❌ Impure: external state | non-deterministic | side effects
let counter = 0;
function increment() { return ++counter; }           // Mutates external state
function rand(arr) { return arr[Math.floor(Math.random() * arr.length)]; } // Non-deterministic
function save(u) { localStorage.setItem('u', JSON.stringify(u)); }         // Side effect
```

### Purifying Impure Functions

```javascript
// Inject dependencies to make functions pure and testable
const isExpired = (token, now) => token.expiresAt < now;
isExpired(token, Date.now());

const shuffle = (array, random = Math.random) =>
  array.toSorted(() => random() - 0.5);             // ES2023 non-mutating
shuffle(items);                                       // Random in production
shuffle(items, () => 0.5);                            // Deterministic in tests
```

## State Updates (React/Redux)

```javascript
// Array state operations
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

1. **`const` by default** — prevent accidental reassignment
2. **ES2023 methods** — `.toSorted()`, `.toReversed()`, `.toSpliced()`, `.with()`
3. **Spread for shallow** — `{ ...obj }`, `[...arr]`; `structuredClone()` for deep
4. **Never mutate parameters** — always return new objects
5. **Separate pure logic from I/O** — extract side effects to boundaries
6. **Inject non-determinism** — pass `Date.now`, `Math.random` as params for testability
7. **Optional chaining** — `obj?.nested?.value` instead of manual guards

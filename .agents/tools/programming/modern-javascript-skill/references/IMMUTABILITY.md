# Immutability and Pure Functions

Immutable array operations (spread, toSorted, toReversed, toSpliced, with), immutable object operations (spread, destructuring, structuredClone), pure function patterns, state update patterns for React/Redux.

## Core Principles

1. **Immutability**: Never modify data in place
2. **Pure functions**: Same input → same output, no side effects
3. **First-class functions**: Functions as values, passed around and composed
4. **Declarative style**: Describe what, not how

## Immutable Array Patterns

```javascript
const numbers = [1, 2, 3, 4, 5];

const withSix = [...numbers, 6];                        // append
const withZero = [0, ...numbers];                       // prepend
const withoutThree = numbers.filter(n => n !== 3);      // remove by value
const withoutSecond = numbers.toSpliced(1, 1);          // remove by index (ES2023)
const updated = numbers.with(2, 99);                    // update by index (ES2023)
const doubledAtTwo = numbers.with(2, numbers.at(2) * 2); // transform at index
const sorted = numbers.toSorted((a, b) => b - a);      // non-mutating sort (ES2023)
const reversed = numbers.toReversed();                  // non-mutating reverse (ES2023)
```

## Immutable Object Patterns

```javascript
const user = { name: 'Alice', age: 30 };

const updated = { ...user, age: 31 };                              // update property
const withAddress = { ...user, address: { city: 'NYC' } };         // add nested
const withNewCity = { ...user, address: { ...user.address, city: 'LA' } }; // update nested
const { age, ...userWithoutAge } = user;                           // remove property
const { name: fullName, ...rest } = user;                          // rename property
const renamed = { fullName, ...rest };
const maybeAdmin = { ...user, ...(isAdmin && { role: 'admin' }) }; // conditional property
```

## Deep Operations

```javascript
// Deep clone — preserves types, handles circular refs
const clone = structuredClone(obj);

// Deep update helper (recursive path-based)
const setIn = (obj, path, value) => {
  const [head, ...rest] = path;
  if (rest.length === 0) return { ...obj, [head]: value };
  return { ...obj, [head]: setIn(obj[head] ?? {}, rest, value) };
};

const newState = setIn(state, ['users', 'u1', 'profile', 'name'], 'Alice');
```

## Pure Functions

```javascript
// ✅ Pure: deterministic, no side effects
function add(a, b) { return a + b; }

function formatUser(user) {
  return {
    displayName: `${user.firstName} ${user.lastName}`,
    initials: `${user.firstName[0]}${user.lastName[0]}`
  };
}

// ❌ Impure examples
let counter = 0;
function incrementCounter() { counter++; return counter; }       // mutates external state
function getRandomUser(users) {                                   // non-deterministic
  return users[Math.floor(Math.random() * users.length)];
}
function saveUser(user) {                                         // side effect (I/O)
  localStorage.setItem('user', JSON.stringify(user));
  return user;
}
```

### Purifying Impure Functions

```javascript
// Inject current time instead of calling Date.now() internally
function isExpired(token, now) { return token.expiresAt < now; }
isExpired(token, Date.now());

// Inject randomness + use non-mutating sort (ES2023)
function shuffle(array, random = Math.random) {
  return array.toSorted(() => random() - 0.5);
}
shuffle(items);              // random
shuffle(items, () => 0.5);   // deterministic for tests
```

## State Updates (React/Redux Style)

```javascript
// Array state operations
const addTodo = (todos, newTodo) => [...todos, newTodo];
const removeTodo = (todos, id) => todos.filter(t => t.id !== id);
const updateTodo = (todos, id, updates) =>
  todos.map(t => t.id === id ? { ...t, ...updates } : t);
const toggleTodo = (todos, id) =>
  todos.map(t => t.id === id ? { ...t, done: !t.done } : t);
const moveTodo = (todos, fromIndex, toIndex) => {
  const result = todos.toSpliced(fromIndex, 1);
  return result.toSpliced(toIndex, 0, todos[fromIndex]);
};

// Nested state update
const updateNestedState = (state, userId, field, value) => ({
  ...state,
  users: {
    ...state.users,
    [userId]: {
      ...state.users[userId],
      profile: { ...state.users[userId].profile, [field]: value }
    }
  }
});
```

## Best Practices

1. **Use const by default** — prevent accidental reassignment
2. **Prefer ES2023 methods** — `.toSorted()`, `.toReversed()`, `.with()`
3. **Use spread for shallow copies** — `{ ...obj }`, `[...arr]`
4. **Use structuredClone for deep copies** — handles circular refs
5. **Return new objects** — never mutate parameters
6. **Extract side effects** — keep pure logic separate from I/O
7. **Inject dependencies** — pass `Date.now`, `Math.random` as params for testing
8. **Use optional chaining** — `obj?.nested?.value` instead of guards

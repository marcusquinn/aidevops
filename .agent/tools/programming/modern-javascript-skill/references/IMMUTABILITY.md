# Immutability and Pure Functions

Immutable array operations (spread, toSorted, toReversed, toSpliced, with), immutable object operations (spread, destructuring, structuredClone), pure function patterns, state update patterns for React/Redux.

## Core Principles

1. **Immutability**: Never modify data in place
2. **Pure functions**: Same input always produces same output, no side effects
3. **First-class functions**: Functions as values, passed around and composed
4. **Declarative style**: Describe what, not how

## Immutable Array Patterns

### Array Operations

```javascript
const numbers = [1, 2, 3, 4, 5];

// Add element
const withSix = [...numbers, 6];

// Prepend element
const withZero = [0, ...numbers];

// Remove element (by value)
const withoutThree = numbers.filter(n => n !== 3);

// Remove element (by index) - ES2023
const withoutSecond = numbers.toSpliced(1, 1);

// Update element (by index) - ES2023
const updated = numbers.with(2, 99);

// Transform element at index
const doubledAtTwo = numbers.with(2, numbers.at(2) * 2);

// ES2023: Non-mutating methods
const sorted = numbers.toSorted((a, b) => b - a);
const reversed = numbers.toReversed();
```

## Immutable Object Patterns

### Object Operations

```javascript
const user = { name: 'Alice', age: 30 };

// Add/update property
const updated = { ...user, age: 31 };

// Add nested property
const withAddress = {
  ...user,
  address: { city: 'NYC' }
};

// Update nested property
const withNewCity = {
  ...user,
  address: { ...user.address, city: 'LA' }
};

// Remove property
const { age, ...userWithoutAge } = user;

// Rename property
const { name: fullName, ...rest } = user;
const renamed = { fullName, ...rest };

// Conditional property
const maybeAdmin = {
  ...user,
  ...(isAdmin && { role: 'admin' })
};
```

## Deep Operations

```javascript
// Deep clone (modern - preserves types, handles circular refs)
const clone = structuredClone(obj);

// Deep clone (legacy - loses functions, Dates become strings)
// const clone = JSON.parse(JSON.stringify(obj));

// Deep update helper
function updatePath(obj, path, value) {
  const keys = path.split('.');
  if (keys.length === 1) {
    return { ...obj, [keys[0]]: value };
  }
  return {
    ...obj,
    [keys[0]]: updatePath(obj[keys[0]], keys.slice(1).join('.'), value)
  };
}

const updated = updatePath(state, 'user.profile.name', 'Bob');
```

## Pure Functions

### Characteristics

```javascript
// ✅ Pure: Deterministic, no side effects
function add(a, b) {
  return a + b;
}

function formatUser(user) {
  return {
    displayName: `${user.firstName} ${user.lastName}`,
    initials: `${user.firstName[0]}${user.lastName[0]}`
  };
}

// ❌ Impure: Uses external state
let counter = 0;
function incrementCounter() {
  counter++;  // Side effect: modifies external state
  return counter;
}

// ❌ Impure: Non-deterministic
function getRandomUser(users) {
  return users[Math.floor(Math.random() * users.length)];
}

// ❌ Impure: Side effect
function saveUser(user) {
  localStorage.setItem('user', JSON.stringify(user));  // Side effect
  return user;
}
```

### Purifying Impure Functions

```javascript
// Impure: Depends on Date
function isExpired(token) {
  return token.expiresAt < Date.now();  // Non-deterministic
}

// Pure: Inject current time
function isExpired(token, now) {
  return token.expiresAt < now;
}
isExpired(token, Date.now());

// Impure: Random + mutates
function shuffle(array) {
  return array.sort(() => Math.random() - 0.5);  // Mutates!
}

// Pure: Inject randomness + non-mutating (ES2023)
function shuffle(array, random = Math.random) {
  return array.toSorted(() => random() - 0.5);
}
shuffle(items);  // Random
shuffle(items, () => 0.5);  // Deterministic for tests
```

## State Updates (React/Redux style)

### Updating Arrays in State

```javascript
// Add item
const addTodo = (todos, newTodo) => [...todos, newTodo];

// Remove item
const removeTodo = (todos, id) => todos.filter(t => t.id !== id);

// Update item
const updateTodo = (todos, id, updates) =>
  todos.map(t => t.id === id ? { ...t, ...updates } : t);

// Toggle item
const toggleTodo = (todos, id) =>
  todos.map(t => t.id === id ? { ...t, done: !t.done } : t);

// Reorder items
const moveTodo = (todos, fromIndex, toIndex) => {
  const result = todos.toSpliced(fromIndex, 1);
  return result.toSpliced(toIndex, 0, todos[fromIndex]);
};
```

### Updating Nested State

```javascript
// Update deeply nested property
const updateNestedState = (state, userId, field, value) => ({
  ...state,
  users: {
    ...state.users,
    [userId]: {
      ...state.users[userId],
      profile: {
        ...state.users[userId].profile,
        [field]: value
      }
    }
  }
});

// With helper function
const setIn = (obj, path, value) => {
  const [head, ...rest] = path;
  if (rest.length === 0) {
    return { ...obj, [head]: value };
  }
  return {
    ...obj,
    [head]: setIn(obj[head] ?? {}, rest, value)
  };
};

const newState = setIn(state, ['users', 'u1', 'profile', 'name'], 'Alice');
```

## Best Practices

1. **Use const by default** — Prevent accidental reassignment
2. **Prefer ES2023 methods** — `.toSorted()`, `.toReversed()`, `.with()`
3. **Use spread for shallow copies** — `{ ...obj }`, `[...arr]`
4. **Use structuredClone for deep copies** — Handles circular refs
5. **Return new objects** — Never mutate parameters
6. **Extract side effects** — Keep pure logic separate from I/O
7. **Inject dependencies** — Pass Date.now, Math.random as params for testing
8. **Use optional chaining** — `obj?.nested?.value` instead of guards

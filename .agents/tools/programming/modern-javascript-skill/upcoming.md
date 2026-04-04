<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Upcoming JavaScript Features

Temporal API, Decorators, Decorator Metadata — all TC39 Stage 3.

## Temporal API (Stage 3 — Polyfill Required)

Modern replacement for the broken `Date` object. Immutable, timezone-aware, calendar-correct.

### Date vs Temporal

```javascript
// Date problems
const date = new Date('2024-03-10');  // Parsed as UTC? Local? Depends!
date.setMonth(1);                      // Mutates original
date.getMonth();                       // 0-indexed (January = 0)

// Temporal — immutable, explicit, correct
const date = Temporal.PlainDate.from('2024-03-10');
const nextMonth = date.add({ months: 1 });  // Returns new instance
date.month;  // 3 (March, 1-indexed)
```

### Types

```javascript
// PlainDate — date only, no time or timezone
const birthday = Temporal.PlainDate.from('1990-05-15');
const today = Temporal.Now.plainDateISO();

// PlainTime — time only
const meeting = Temporal.PlainTime.from('14:30:00');

// PlainDateTime — date + time, no timezone
const appointment = Temporal.PlainDateTime.from('2024-03-15T14:30:00');

// ZonedDateTime — full date/time with timezone (DST-aware)
const flight = Temporal.ZonedDateTime.from(
  '2024-03-15T14:30:00[America/New_York]'
);

// Instant — exact moment in time (like Unix timestamp)
const now = Temporal.Now.instant();

// Duration — length of time
const duration = Temporal.Duration.from({ hours: 2, minutes: 30 });
```

### Arithmetic and Comparison

```javascript
const date = Temporal.PlainDate.from('2024-01-31');

date.add({ months: 1 });              // 2024-02-29 (leap year aware)
date.subtract({ days: 15 });

date1.equals(date2);
Temporal.PlainDate.compare(date1, date2);  // -1, 0, or 1

const diff = date1.until(date2);
diff.days;  // Number of days between
```

### Timezone Handling

```javascript
const nyTime = Temporal.ZonedDateTime.from(
  '2024-03-15T14:30:00[America/New_York]'
);
const londonTime = nyTime.withTimeZone('Europe/London');

// DST transitions handled correctly
const beforeDST = Temporal.ZonedDateTime.from(
  '2024-03-10T01:30:00[America/New_York]'
);
beforeDST.add({ hours: 2 });  // Correctly handles "spring forward"
```

### Migration Guide

| Use Case | Date | Temporal |
|----------|------|----------|
| Store timestamps | `Date.now()` | `Temporal.Now.instant()` |
| Display dates | `new Date()` | `Temporal.Now.zonedDateTimeISO()` |
| Birthdays, holidays | `new Date(y, m-1, d)` | `Temporal.PlainDate.from()` |
| Meeting times | Manual TZ conversion, DST bugs | `Temporal.ZonedDateTime` |
| Duration math | Manual calculation | `Temporal.Duration` |

---

## Decorators (Stage 3 — Transpiler Required)

Annotate and modify classes/methods with `@decorator` syntax. Babel or TypeScript 5.0+.

```javascript
// Method decorator
function logged(target, context) {
  return function (...args) {
    console.log(`Calling ${context.name} with`, args);
    return target.apply(this, args);
  };
}

class Calculator {
  @logged
  add(a, b) {
    return a + b;
  }
}

// Class decorator
function singleton(Class, context) {
  let instance;
  return function (...args) {
    if (!instance) {
      instance = new Class(...args);
    }
    return instance;
  };
}

@singleton
class Database {
  constructor(url) {
    this.url = url;
  }
}
```

**Key points:**

- `@decorator` syntax before classes, methods, fields, accessors
- Receives `(value, context)` — value being decorated + metadata
- Must return the decorated value (or replacement)
- No parameter decorators (unlike TypeScript legacy decorators)
- TypeScript 5.0+ supports TC39 decorators with `experimentalDecorators: false`

### Decorator Metadata

Store metadata on decorated elements via `Symbol.metadata`.

```javascript
function meta(value) {
  return function (target, context) {
    context.metadata[context.name] = value;
    return target;
  };
}

class User {
  @meta('string')
  name;

  @meta('number')
  age;
}

User[Symbol.metadata];
// { name: 'string', age: 'number' }
```

---

## Feature Support Summary

| Feature | Status | Tooling |
|---------|--------|---------|
| Temporal | Stage 3 | Polyfill required |
| Decorators | Stage 3 | Babel, TypeScript 5.0+ |
| Decorator Metadata | Stage 3 | Babel, TypeScript 5.0+ |

## Resources

- **TC39 Proposals**: https://github.com/tc39/proposals
- **Can I Use**: https://caniuse.com (browser support tables)

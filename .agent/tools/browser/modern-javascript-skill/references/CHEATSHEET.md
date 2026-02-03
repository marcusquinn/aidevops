# Modern JavaScript Cheatsheet

Variables, arrow functions, destructuring, spread/rest, template literals, optional chaining, nullish coalescing, array methods, string methods, object methods, promises, async/await, classes, modules, Set/Map, iterators, generators, RegExp, BigInt, Temporal, resource management.

## Variables & Scope

```javascript
const x = 1;        // Block-scoped, cannot reassign
let y = 2;          // Block-scoped, can reassign
// var z = 3;       // Function-scoped, avoid
```

## Arrow Functions

```javascript
const add = (a, b) => a + b;            // Expression body
const greet = name => `Hello ${name}`;  // Single param, no parens
const getObj = () => ({ key: 'value' }); // Return object literal
const multi = (a, b) => {               // Block body
  const sum = a + b;
  return sum * 2;
};
```

## Destructuring

```javascript
// Object
const { name, age = 18 } = user;
const { name: n, address: { city } } = user;
const { id, ...rest } = user;

// Array
const [first, second] = arr;
const [head, ...tail] = arr;
const [, , third] = arr;
[a, b] = [b, a];  // Swap
```

## Spread & Rest

```javascript
// Spread
const merged = [...arr1, ...arr2];
const clone = { ...obj };
const updated = { ...obj, key: 'new' };
Math.max(...numbers);

// Rest
const sum = (...nums) => nums.reduce((a, b) => a + b);
const { id, ...userData } = user;
```

## Template Literals

```javascript
const str = `Hello ${name}!`;
const multi = `Line 1
Line 2`;
const html = `<div class="${cls}">${content}</div>`;
```

## Object Shorthand

```javascript
const name = 'Alice';
const obj = {
  name,                    // Property shorthand
  greet() { },             // Method shorthand
  [`key_${id}`]: value,    // Computed property
};
```

## Optional Chaining & Nullish Coalescing

```javascript
obj?.prop              // Property access
obj?.[key]             // Dynamic property
obj?.method?.()        // Method call
arr?.[0]               // Array access

value ?? 'default'     // Nullish coalescing (null/undefined only)
value || 'default'     // Falsy coalescing (0, '', false, null, undefined)

obj.prop ??= 'default' // Assign if nullish
obj.prop ||= 'default' // Assign if falsy
obj.prop &&= newValue  // Assign if truthy
```

## Array Methods

```javascript
// Transform
arr.map(x => x * 2)
arr.filter(x => x > 0)
arr.reduce((acc, x) => acc + x, 0)
arr.flatMap(x => [x, x * 2])
arr.flat(2)

// Search
arr.find(x => x.id === 1)
arr.findIndex(x => x.id === 1)
arr.findLast(x => x > 5)           // ES2023
arr.findLastIndex(x => x > 5)      // ES2023
arr.includes(value)
arr.indexOf(value)

// Check
arr.some(x => x > 0)
arr.every(x => x > 0)

// Access
arr.at(-1)                         // ES2022 - last element
arr.at(-2)                         // second to last

// Non-mutating (ES2023)
arr.toSorted((a, b) => a - b)
arr.toReversed()
arr.toSpliced(1, 1)
arr.with(0, 'new')

// Group (ES2024)
Object.groupBy(arr, x => x.type)
Map.groupBy(arr, x => x.type)

// Create
Array.from({ length: 5 }, (_, i) => i)
Array.of(1, 2, 3)
await Array.fromAsync(asyncIterable)  // ES2025
```

## String Methods

```javascript
str.includes('sub')
str.startsWith('pre')
str.endsWith('suf')
str.padStart(10, '0')          // ES2017
str.padEnd(10, '-')            // ES2017
str.repeat(3)
str.trim()
str.trimStart()                // ES2019
str.trimEnd()                  // ES2019
str.matchAll(/pattern/g)       // ES2020 - iterator of matches
str.replaceAll('a', 'b')       // ES2021
str.at(-1)                     // ES2022 - last char
str.isWellFormed()             // ES2024
str.toWellFormed()             // ES2024
```

## Object Methods

```javascript
Object.keys(obj)
Object.values(obj)
Object.entries(obj)
Object.fromEntries(entries)
Object.assign({}, obj, updates)
Object.hasOwn(obj, 'key')      // ES2022
Object.groupBy(arr, fn)        // ES2024
```

## Promises

```javascript
// Create
new Promise((resolve, reject) => { })
Promise.resolve(value)
Promise.reject(error)
Promise.withResolvers()        // ES2024
Promise.try(() => fn())        // ES2025

// Combinators
Promise.all([p1, p2, p3])
Promise.allSettled([p1, p2])   // ES2020
Promise.race([p1, p2])
Promise.any([p1, p2])          // ES2021

// Instance methods
promise.then(onFulfilled, onRejected)
promise.catch(onRejected)
promise.finally(onFinally)     // ES2018
```

## Async/Await

```javascript
async function fn() {
  try {
    const result = await promise;
    return result;
  } catch (error) {
    handleError(error);
  }
}

// Parallel
const [a, b] = await Promise.all([fetchA(), fetchB()]);

// Sequential
for (const item of items) {
  await process(item);
}
```

## Classes

```javascript
class Animal {
  #privateField = 0;           // Private field
  static count = 0;            // Static field

  constructor(name) {
    this.name = name;
    Animal.count++;
  }

  speak() {                    // Method
    return `${this.name} speaks`;
  }

  #privateMethod() { }         // Private method

  get displayName() {          // Getter
    return this.name.toUpperCase();
  }

  set displayName(value) {     // Setter
    this.name = value.toLowerCase();
  }

  static create(name) {        // Static method
    return new Animal(name);
  }
}

class Dog extends Animal {
  constructor(name, breed) {
    super(name);
    this.breed = breed;
  }

  speak() {
    return `${super.speak()}: Woof!`;
  }
}
```

## Modules

```javascript
// Export
export const x = 1;
export function fn() { }
export default class { }
export { a, b as c };

// Import
import Default from './module';
import { x, fn } from './module';
import { x as y } from './module';
import * as mod from './module';
import './module';  // Side effects only

// Dynamic
const mod = await import('./module');
```

## Set & Map

```javascript
// Set
const set = new Set([1, 2, 3]);
set.add(4);
set.has(1);
set.delete(1);
set.size;
set.clear();

// ES2025 Set methods
setA.union(setB)
setA.intersection(setB)
setA.difference(setB)
setA.symmetricDifference(setB)
setA.isSubsetOf(setB)
setA.isSupersetOf(setB)
setA.isDisjointFrom(setB)

// Map
const map = new Map([['a', 1], ['b', 2]]);
map.set('c', 3);
map.get('a');
map.has('a');
map.delete('a');
map.size;
```

## Iterators & Generators

```javascript
// Generator
function* gen() {
  yield 1;
  yield 2;
  yield 3;
}

// Async generator
async function* asyncGen() {
  yield await fetch(url1);
  yield await fetch(url2);
}

// for...of
for (const x of iterable) { }
for await (const x of asyncIterable) { }  // ES2018

// Iterator helpers (ES2025)
iter.map(fn)
iter.filter(fn)
iter.take(n)
iter.drop(n)
iter.toArray()
Iterator.from(iterable)
```

## Regular Expressions

```javascript
// Named capture groups (ES2018)
const pattern = /(?<year>\d{4})-(?<month>\d{2})/;
const { year, month } = str.match(pattern).groups;

// Lookbehind assertions (ES2018)
/(?<=\$)\d+/        // Positive lookbehind
/(?<!\$)\d+/        // Negative lookbehind

// Flags
/pattern/g          // Global
/pattern/i          // Case-insensitive
/pattern/m          // Multiline
/pattern/s          // dotAll - . matches newlines (ES2018)
/pattern/u          // Unicode
/pattern/d          // Match indices (ES2022)
/pattern/v          // Unicode sets (ES2024)

// Unicode property escapes (ES2018)
/\p{Letter}/u       // Any letter
/\p{Emoji}/u        // Emoji
/\p{Script=Greek}/u // Greek script

// Unicode set operations (ES2024 /v flag)
/[\p{Emoji}--\p{ASCII}]/v  // Emoji minus ASCII
/[[a-z]&&[^aeiou]]/v       // Consonants only

// Match indices (ES2022)
const match = /(?<g>\w+)/.exec('hello');
match.indices.groups.g  // [0, 5]

// RegExp.escape (ES2025)
RegExp.escape('$100')   // '\\$100'
```

## Primitives, Errors, Cloning, Resource Management

```javascript
// BigInt (ES2020)
const big = 9007199254740991n;
BigInt(123);

// Numeric separators (ES2021)
const million = 1_000_000;

// globalThis (ES2020)
globalThis.setTimeout

// Error cause (ES2022)
throw new Error('msg', { cause: originalError });

// structuredClone
const deep = structuredClone(obj);

// String well-formed (ES2024)
str.isWellFormed()    // Check for lone surrogates
str.toWellFormed()    // Fix lone surrogates

// Private slot check (ES2022)
#field in obj         // true if obj has #field

// Static initialization blocks (ES2022)
class C {
  static {
    // Runs when class is defined
  }
}

// Promise.finally (ES2018)
promise.finally(() => cleanup())

// Promise.try (ES2025)
Promise.try(() => mayThrow())

// Float16 (ES2025)
new Float16Array([1.5, 2.5])
Math.f16round(1.337)

// Import attributes (ES2025)
import data from './data.json' with { type: 'json' }

// WeakRef & FinalizationRegistry (ES2021)
const ref = new WeakRef(obj);
ref.deref()  // obj or undefined

// Symbol.description (ES2019)
Symbol('name').description  // 'name'

// Optional catch binding (ES2019)
try { } catch { }  // No parameter needed

// Hashbang (ES2023)
#!/usr/bin/env node  // At file start

// Explicit Resource Management (ES2025)
using file = openFile('data.txt');  // Auto-disposed
await using db = await connect();   // Async disposal
Symbol.dispose                      // Cleanup method
Symbol.asyncDispose                 // Async cleanup
new DisposableStack()               // Aggregate disposables

// Array.fromAsync (ES2025)
await Array.fromAsync(asyncIterable)
await Array.fromAsync(generator(), mapFn)

// Error.isError (ES2025)
Error.isError(err)  // true for any Error, cross-realm safe

// Intl.DurationFormat (ES2025)
new Intl.DurationFormat('en', { style: 'long' })
  .format({ hours: 1, minutes: 30 })  // "1 hour, 30 minutes"

// Temporal API (Stage 3 - requires polyfill)
Temporal.PlainDate.from('2024-03-15')     // Date only
Temporal.PlainTime.from('14:30:00')       // Time only
Temporal.PlainDateTime.from('...')         // Date + time
Temporal.ZonedDateTime.from('...[TZ]')    // With timezone
Temporal.Now.instant()                     // Current moment
Temporal.Duration.from({ hours: 2 })       // Duration
date.add({ months: 1 })                    // Immutable arithmetic
```

## Stage 3 Proposals (Decorators, Decorator Metadata)

```javascript
// Decorators (Stage 3 - requires Babel or TypeScript 5.0+)
@logged
class User {
  @validate name;
  @memoize getData() { }
}

// Decorator Metadata (Stage 3)
User[Symbol.metadata]  // { name: 'string', ... }
```

## Quick Migration Guide

| Legacy | Modern |
|--------|--------|
| `var x = 1` | `const x = 1` or `let x = 1` |
| `function(x) { return x * 2 }` | `x => x * 2` |
| `arr[arr.length - 1]` | `arr.at(-1)` |
| `arr.sort()` | `arr.toSorted()` |
| `arr.reverse()` | `arr.toReversed()` |
| `arr.splice(i, 1)` | `arr.toSpliced(i, 1)` |
| `arr[i] = val` | `arr.with(i, val)` |
| `str.replace(/a/g, 'b')` | `str.replaceAll('a', 'b')` |
| `obj.hasOwnProperty('k')` | `Object.hasOwn(obj, 'k')` |
| `a && a.b && a.b.c` | `a?.b?.c` |
| `x \|\| 'default'` | `x ?? 'default'` |
| `Object.assign({}, a, b)` | `{ ...a, ...b }` |
| `[].concat(a, b)` | `[...a, ...b]` |
| `.then().catch()` | `async/await + try/catch` |
| `let resolve; new Promise(r => resolve = r)` | `Promise.withResolvers()` |
| `new Date()` | `Temporal.Now.*` (polyfill) |
| Manual grouping with reduce | `Object.groupBy()` |

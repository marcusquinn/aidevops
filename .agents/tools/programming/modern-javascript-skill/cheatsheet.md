# Modern JavaScript Cheatsheet

Syntax-only quick reference (ES6-ES2025). For decision trees and migration patterns, see `modern-javascript-skill.md`.

## Variables & Scope

```javascript
const x = 1;        // Block-scoped, cannot reassign
let y = 2;          // Block-scoped, can reassign
// var z = 3;       // Function-scoped, avoid
```

## Arrow Functions

```javascript
const add = (a, b) => a + b;
const greet = name => `Hello ${name}`;
const getObj = () => ({ key: 'value' });
const multi = (a, b) => { const sum = a + b; return sum * 2; };
```

## Destructuring

```javascript
const { name, age = 18 } = user;
const { name: n, address: { city } } = user;
const { id, ...rest } = user;
const [first, second] = arr;
const [head, ...tail] = arr;
const [, , third] = arr;
[a, b] = [b, a];  // Swap
```

## Spread & Rest

```javascript
const merged = [...arr1, ...arr2];
const clone = { ...obj };
const updated = { ...obj, key: 'new' };
Math.max(...numbers);
const sum = (...nums) => nums.reduce((a, b) => a + b);
```

## Template Literals

```javascript
const str = `Hello ${name}!`;
const multi = `Line 1\nLine 2`;
const html = `<div class="${cls}">${content}</div>`;
```

## Object Shorthand

```javascript
const obj = {
  name,                    // Property shorthand
  greet() { },             // Method shorthand
  [`key_${id}`]: value,    // Computed property
};
```

## Optional Chaining & Nullish Coalescing

```javascript
obj?.prop; obj?.[key]; obj?.method?.(); arr?.[0]
value ?? 'default'     // null/undefined only
value || 'default'     // falsy (0, '', false, null, undefined)
obj.prop ??= 'default'; obj.prop ||= 'default'; obj.prop &&= newValue
```

## Array Methods

```javascript
arr.map(x => x * 2); arr.filter(x => x > 0); arr.reduce((acc, x) => acc + x, 0)
arr.flatMap(x => [x, x * 2]); arr.flat(2)
arr.find(x => x.id === 1); arr.findIndex(x => x.id === 1)
arr.findLast(x => x > 5); arr.findLastIndex(x => x > 5)  // ES2023
arr.includes(value); arr.indexOf(value)
arr.some(x => x > 0); arr.every(x => x > 0)
arr.at(-1)                         // ES2022 - last element
arr.toSorted((a, b) => a - b); arr.toReversed(); arr.toSpliced(1, 1); arr.with(0, 'new')  // ES2023
Object.groupBy(arr, x => x.type); Map.groupBy(arr, x => x.type)  // ES2024
Array.from({ length: 5 }, (_, i) => i); Array.of(1, 2, 3)
await Array.fromAsync(asyncIterable)  // ES2025
```

## String Methods

```javascript
str.includes('sub'); str.startsWith('pre'); str.endsWith('suf')
str.padStart(10, '0'); str.padEnd(10, '-')  // ES2017
str.repeat(3); str.trim(); str.trimStart(); str.trimEnd()  // ES2019
str.matchAll(/pattern/g)       // ES2020 - iterator of matches
str.replaceAll('a', 'b')       // ES2021
str.at(-1)                     // ES2022 - last char
str.isWellFormed(); str.toWellFormed()  // ES2024
```

## Object Methods

```javascript
Object.keys(obj); Object.values(obj); Object.entries(obj)
Object.fromEntries(entries); Object.assign({}, obj, updates)
Object.hasOwn(obj, 'key')  // ES2022
Object.groupBy(arr, fn)    // ES2024
```

## Promises

```javascript
new Promise((resolve, reject) => { })
Promise.resolve(value); Promise.reject(error)
Promise.withResolvers()        // ES2024
Promise.try(() => fn())        // ES2025
Promise.all([p1, p2, p3]); Promise.allSettled([p1, p2])  // ES2020
Promise.race([p1, p2]); Promise.any([p1, p2])             // ES2021
promise.then(onFulfilled, onRejected).catch(onRejected).finally(onFinally)  // ES2018
```

## Async/Await

```javascript
async function fn() {
  try {
    const result = await promise;
    return result;
  } catch (error) { handleError(error); }
}
const [a, b] = await Promise.all([fetchA(), fetchB()]);  // Parallel
for (const item of items) { await process(item); }       // Sequential
```

## Classes

```javascript
class Animal {
  #privateField = 0;
  static count = 0;
  constructor(name) { this.name = name; Animal.count++; }
  speak() { return `${this.name} speaks`; }
  #privateMethod() { }
  get displayName() { return this.name.toUpperCase(); }
  set displayName(v) { this.name = v.toLowerCase(); }
  static create(name) { return new Animal(name); }
  static { /* runs when class is defined */ }  // ES2022
}
class Dog extends Animal {
  constructor(name, breed) { super(name); this.breed = breed; }
  speak() { return `${super.speak()}: Woof!`; }
}
#field in obj  // Private slot check (ES2022)
```

## Modules

```javascript
export const x = 1; export function fn() { } export default class { }
export { a, b as c };
import Default from './module'; import { x, fn } from './module';
import { x as y } from './module'; import * as mod from './module';
import './module';  // Side effects only
const mod = await import('./module');  // Dynamic
import data from './data.json' with { type: 'json' }  // ES2025
```

## Set & Map

```javascript
const set = new Set([1, 2, 3]);
set.add(4); set.has(1); set.delete(1); set.size; set.clear()
setA.union(setB); setA.intersection(setB); setA.difference(setB)  // ES2025
setA.symmetricDifference(setB); setA.isSubsetOf(setB); setA.isSupersetOf(setB); setA.isDisjointFrom(setB)
const map = new Map([['a', 1], ['b', 2]]);
map.set('c', 3); map.get('a'); map.has('a'); map.delete('a'); map.size
```

## Iterators & Generators

```javascript
function* gen() { yield 1; yield 2; yield 3; }
async function* asyncGen() { yield await fetch(url1); yield await fetch(url2); }
for (const x of iterable) { }
for await (const x of asyncIterable) { }  // ES2018
iter.map(fn); iter.filter(fn); iter.take(n); iter.drop(n); iter.toArray()  // ES2025
Iterator.from(iterable)
```

## Regular Expressions

```javascript
const { year, month } = str.match(/(?<year>\d{4})-(?<month>\d{2})/).groups  // Named groups ES2018
/(?<=\$)\d+/; /(?<!\$)\d+/  // Lookbehind (ES2018)
// Flags: g global, i case-insensitive, m multiline, s dotAll (ES2018), u unicode, d indices (ES2022), v unicode sets (ES2024)
/\p{Letter}/u; /\p{Emoji}/u; /\p{Script=Greek}/u  // Unicode property escapes (ES2018)
/[\p{Emoji}--\p{ASCII}]/v; /[[a-z]&&[^aeiou]]/v   // Set operations (ES2024)
/(?<g>\w+)/.exec('hello').indices.groups.g          // Match indices (ES2022)
RegExp.escape('$100')  // '\\$100' (ES2025)
```

## Miscellaneous

```javascript
// BigInt (ES2020)
const big = 9007199254740991n; BigInt(123)
const million = 1_000_000  // Numeric separators (ES2021)
globalThis.setTimeout      // globalThis (ES2020)

// Errors & cloning
throw new Error('msg', { cause: originalError })  // Error cause (ES2022)
const deep = structuredClone(obj)
Error.isError(err)  // Cross-realm safe (ES2025)

// WeakRef & FinalizationRegistry (ES2021)
const ref = new WeakRef(obj); ref.deref()  // obj or undefined

// Symbols (ES2019)
Symbol('name').description  // 'name'
try { } catch { }  // Optional catch binding (ES2019)

// Float16 (ES2025)
new Float16Array([1.5, 2.5]); Math.f16round(1.337)

// Explicit Resource Management (ES2025)
using file = openFile('data.txt');   // Auto-disposed
await using db = await connect();    // Async disposal
Symbol.dispose; Symbol.asyncDispose; new DisposableStack()

// Intl.DurationFormat (ES2025)
new Intl.DurationFormat('en', { style: 'long' }).format({ hours: 1, minutes: 30 })

// Temporal API (Stage 3 — requires polyfill)
Temporal.PlainDate.from('2024-03-15'); Temporal.PlainTime.from('14:30:00')
Temporal.ZonedDateTime.from('...[TZ]'); Temporal.Now.instant()
Temporal.Duration.from({ hours: 2 }); date.add({ months: 1 })  // Immutable

// Decorators (Stage 3 — requires Babel or TypeScript 5.0+)
@logged class User { @validate name; @memoize getData() { } }
User[Symbol.metadata]  // Decorator Metadata
```

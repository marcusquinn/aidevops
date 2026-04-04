<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Modern JavaScript Decision Trees

Quick decision trees for common JavaScript tasks.

## "Which array method should I use?"

```text
What do I need?
├─ Transform each element           → .map()
├─ Keep some elements               → .filter()
├─ Find one element                 → .find() / .findLast()
├─ Check if condition met           → .some() / .every()
├─ Reduce to single value           → .reduce()
├─ Get last element                 → .at(-1)
├─ Sort without mutating            → .toSorted()
├─ Reverse without mutating         → .toReversed()
├─ Group by property                → Object.groupBy()
└─ Flatten nested arrays            → .flat() / .flatMap()
```

## "How do I handle nullish values?"

```text
Nullish handling?
├─ Safe property access              → obj?.prop / obj?.[key]
├─ Safe method call                  → obj?.method?.()
├─ Default for null/undefined only   → value ?? 'default'
├─ Default for any falsy             → value || 'default'
├─ Assign if null/undefined          → obj.prop ??= 'default'
└─ Check property exists             → Object.hasOwn(obj, 'key')
```

## "Should I mutate or copy?"

```text
Always prefer non-mutating methods:
├─ Sort array      → .toSorted()    (not .sort())
├─ Reverse array   → .toReversed()  (not .reverse())
├─ Splice array    → .toSpliced()   (not .splice())
├─ Update element  → .with(i, val)  (not arr[i] = val)
├─ Add to array    → [...arr, item] (not .push())
└─ Merge objects   → {...obj, key}  (not Object.assign())
```

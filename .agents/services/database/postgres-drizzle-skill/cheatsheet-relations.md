<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Relations

```typescript
import { relations } from 'drizzle-orm';

// One-to-Many
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, {
    fields: [posts.authorId],
    references: [users.id],
  }),
}));

// Many-to-Many (via junction table)
export const usersToGroupsRelations = relations(usersToGroups, ({ one }) => ({
  user: one(users, { fields: [usersToGroups.userId], references: [users.id] }),
  group: one(groups, { fields: [usersToGroups.groupId], references: [groups.id] }),
}));
```

## Type Inference

```typescript
import type { InferSelectModel, InferInsertModel } from 'drizzle-orm';

type User = InferSelectModel<typeof users>;
type NewUser = InferInsertModel<typeof users>;
```

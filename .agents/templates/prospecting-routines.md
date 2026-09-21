# Prospecting routines (disabled by default)

Prospecting routines are local, opt-in plans. They do not install schedules, send messages, contact prospects, or spend money.

```json
{
  "project_id": "example-project",
  "jobs": [
    {"id": "community-scan", "cadence": "daily", "enabled": false,
     "budget": {"requests": 10, "rows": 100, "tokens": 0, "wall_seconds": 60, "dollars": null}}
  ],
  "leads": [], "delivered": [], "hidden": []
}
```

Use `prospecting-routine-helper.py plan --input FILE --dry-run` before enabling any operator-owned integration. Digest destinations must be explicitly configured internal Slack, Discord, email, or approved HTTPS webhook targets; unknown delivery is reconciled rather than retried.

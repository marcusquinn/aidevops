.entries = (.entries // {})
| .entries[$key] = ($metadata + {label_at: $label_at, status: $status, checked_at: now})
| .updated_at = now

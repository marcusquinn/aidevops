def run_key: [(.name // ""), (.app.slug // .app.name // "")];

def run_time:
  .completed_at // .started_at // .created_at // .updated_at // "";

[
  .check_runs[]
  | select(.status == "completed")
  | select(.name != $self_name)
]
| sort_by(run_key)
| group_by(run_key)
| map(max_by([run_time, (.id // 0)]))

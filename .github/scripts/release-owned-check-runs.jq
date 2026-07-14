def run_key: [(.name // ""), (.app.slug // .app.name // "")];

def run_time:
  .completed_at // .started_at // .created_at // .updated_at // "";

def latest_by_key:
  sort_by(run_key)
  | group_by(run_key)
  | map(max_by([run_time, (.id // 0)]));

($release_run_documents
 | flatten
 | map(.workflow_runs // [])
 | add
 | map(
     select(.head_sha == $release_sha)
     | select(.event == "push" or .event == "release" or .event == "workflow_dispatch")
     | .check_suite_id
   )
 | map(select(. != null))
 | unique) as $release_suite_ids
|
{
  check_runs: (
    [
      .check_runs[]?
      | select(.name != $self_name)
      | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id))
    ]
    | latest_by_key
  ),
  advisory_check_runs: (
    [
      .check_runs[]?
      | select(.name != $self_name)
      | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id) | not)
      | select((.app.slug // "") != "github-actions")
    ]
    | latest_by_key
  )
}

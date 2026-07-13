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
  check_runs: [
    .check_runs[]?
    | select(.name != $self_name)
    | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id))
  ]
}

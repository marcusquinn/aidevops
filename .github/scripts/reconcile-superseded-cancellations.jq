def run_key: [(.name // ""), (.app.slug // .app.name // "")];

def successful_descendant($key):
  [
    $descendant_runs[]
    | select(run_key == $key)
    | select(.status == "completed" and .conclusion == "success")
  ]
  | last // null;

[
  $current_runs[]
  | if .conclusion == "cancelled" then
      run_key as $key
      | successful_descendant($key) as $replacement
      | if $replacement == null then .
        else .
          | .status = "completed"
          | .conclusion = "success"
          | .superseded_by_check_run_id = ($replacement.id // null)
        end
    else .
    end
]

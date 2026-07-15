{
  check_runs: [
    (if type == "array" then . else [] end)[]?
    | .check_runs[]?
  ]
}

{
  check_runs: [
    if type == "array" then .[] | .check_runs[]? else empty end
  ]
}

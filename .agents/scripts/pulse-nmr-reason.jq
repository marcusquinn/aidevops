def metadata($code; $class; $source): {
  code: $code,
  class: $class,
  source: $source,
  revalidate_after_seconds: (if $class == "temporary" then $revalidate else null end),
  requires_crypto: ($class == "genuine-authority")
};
(if type == "array" and (.[0]? | type) == "array" then [.[][]]
 else if type == "array" then . else [] end end) as $comments
| ([$comments[].body // "" | try capture("nmr-reason code=(?<code>[a-z_-]+) class=(?<class>genuine-authority|temporary)") catch empty] | last) as $explicit
| ($comments | map(.body // "") | join("\n") | ascii_downcase) as $text
| if $explicit != null then metadata($explicit.code; $explicit.class; "structured-marker")
  elif ($text | test("secret|required credential|credential access")) then metadata("secret"; "genuine-authority"; "legacy-marker")
  elif ($text | test("destructive|data deletion|irreversible")) then metadata("destructive"; "genuine-authority"; "legacy-marker")
  elif ($text | test("billing|cost-circuit-breaker|spend approval")) then metadata("billing"; "genuine-authority"; "legacy-marker")
  elif ($text | test("security-sensitive|supply.chain|auth boundary")) then metadata("security"; "genuine-authority"; "legacy-marker")
  elif ($text | test("rate_limit_nmr|dispatch-infrastructure-failure|local runtime|launch failure")) then metadata("transient_infrastructure"; "temporary"; "legacy-marker")
  elif ($text | test("missing implementation context|missing context")) then metadata("missing_context"; "temporary"; "legacy-marker")
  elif ($text | test("stale-recovery|worker_recovery_loop|diagnostic ambiguity")) then metadata("diagnostic_ambiguity"; "temporary"; "legacy-marker")
  else metadata("authority"; "genuine-authority"; "default") end

(if type == "array" and (.[0]? | type) == "array" then [.[][]]
 else if type == "array" then . else [] end end)
| [.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")]
| last
| {actor: (.actor.login // ""), at: (.created_at // "")}

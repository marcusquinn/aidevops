(if type == "array" and (.[0]? | type) == "array" then [.[][]]
 else if type == "array" then . else [] end end)
| any(.[];
    ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
    and ((.body // "") | contains("<!-- nmr-revalidation resolved=true"))
  )

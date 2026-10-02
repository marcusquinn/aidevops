def task_id_pattern:
  "(?:t[1-9][0-9]{0,17}(?:\\.[1-9][0-9]{0,17}){0,8}|to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(?:\\.[1-9][0-9]{0,17}){0,8})";

def text_value:
  if . == null then "" elif type == "string" then . else tostring end;

def valid_task_id:
  type == "string" and test("^" + task_id_pattern + "$");

def task_id_from_title:
  text_value
  | ((try capture("^(?<id>" + task_id_pattern + "):"; "").id catch "") // "");

def without_task_brief_paths:
  gsub("(^|[^[:alnum:]./])todo/tasks/" + task_id_pattern + "-brief\\.md(?=$|[^[:alnum:].])"; " ");

def malformed_task_candidate:
  without_task_brief_paths
  | [scan("(^|[^[:alnum:].])([tT][0-9][[:alnum:].-]*|t[A-Z][[:alnum:].-]*|[tT][oO][[:alnum:]]{26}-[[:alnum:].-]+)(?=$|[^[:alnum:].])") | .[1]]
  | any(.[]; (valid_task_id | not));

def extracted_task_ids:
  [scan("(^|[^[:alnum:].])(" + task_id_pattern + ")(?=$|[^[:alnum:].])") | .[1]];

# Keep the same unfenced -> visible order as _blocked_by_structured_lines.
# A closing fence must use the opener's character and at least its length.
def unfenced_text:
  reduce (split("\n")[]) as $line (
    {fence: "", size: 0, lines: []};
    ($line | ((try capture("^[[:space:]]*(?<marker>`{3,}|~{3,})(?<rest>.*)$") catch null) // null)) as $match
    | if .fence == "" then
        if $match != null then
          .fence = $match.marker[0:1] | .size = ($match.marker | length)
        else .lines += [$line] end
      elif $match != null and $match.marker[0:1] == .fence
        and ($match.marker | length) >= .size and ($match.rest | test("^[[:space:]]*$")) then
        .fence = "" | .size = 0
      else . end
  ) | .lines | join("\n");

def visible_text:
  unfenced_text
  # Preserve line boundaries for multiline comments, as the AWK parser does.
  | gsub("<!--(?<text>.*?)-->"; if (.text | contains("\n")) then "\n" else "" end; "ms")
  | sub("<!--.*$"; ""; "ms");

def blocker_text:
  visible_text | gsub("\r"; "") | split("\n")
  | map(select(test("^[[:space:]]*([-*+][[:space:]]+)?(\\*\\*)?blocked[- ]by(\\*\\*)?[[:space:]]*:"; "i")))
  | join("\n");

def defer_marker:
  test("defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]"; "i");

def issue_number:
  if type == "number" and . >= 0 and floor == . then .
  elif type == "string" and test("^[0-9]+$") then tonumber
  else null
  end;

def label_names:
  [(.labels // [])[]? | .name? // empty | strings];

# Only generated consolidation children have this label/title pair. The parent
# is context to consolidate, never a prerequisite for completing the child.
def consolidation_parent:
  if (label_names | index("consolidation-task")) != null then
    (.title | text_value | ((try capture("^consolidation-task: merge thread on #(?<number>[0-9]+) into single spec$").number catch null) // null))
  else null end;

def parsed_issue:
  (.number | issue_number) as $number
  | if $number == null then null else
      (.title | task_id_from_title) as $task_id
      | (.body | text_value) as $body
      | ($body | blocker_text) as $blocker_text
      | ($blocker_text | if malformed_task_candidate then ["__malformed__"] else extracted_task_ids end) as $body_task_ids
      | (label_names) as $labels
      | ([$labels[] | select(startswith("blocked-by:")) | ltrimstr("blocked-by:")
          | if valid_task_id then . elif malformed_task_candidate then "__malformed__" else empty end]) as $label_task_ids
      | (($body_task_ids + $label_task_ids) | unique | map(select(. != $task_id))) as $task_ids
      | ([$blocker_text | scan("#[0-9]+") | ltrimstr("#")]) as $body_issue_nums
      | ([$labels[] | select(test("^blocked-by:#[0-9]+$")) | ltrimstr("blocked-by:#")]) as $label_issue_nums
      | (($body_issue_nums + $label_issue_nums) | unique | map(select(. != ($number | tostring)))) as $issue_nums
      | ($body | defer_marker) as $defer
      | consolidation_parent as $parent
      | {
          number: $number,
          state: ((.state // "OPEN") | text_value | ascii_upcase),
          task_id: $task_id,
          consolidation_parent: $parent,
          task_ids: $task_ids,
          issue_nums: $issue_nums,
          defer: $defer,
          has_blockers: (($task_ids | length) > 0 or ($issue_nums | length) > 0)
        }
    end;

map(parsed_issue | select(. != null)) as $issues
| reduce ($issues[]) as $issue (
  {open_issues: [], closed_issues: [], known_issues: [], task_to_issue: {}, blocked_by: {}, defer_flags: {}};
  .known_issues += [$issue.number]
  | if $issue.state == "CLOSED" then .closed_issues += [$issue.number] else .open_issues += [$issue.number] end
  | if $issue.task_id != "" then .task_to_issue[$issue.task_id] = $issue.number else . end
  | if $issue.has_blockers and $issue.state != "CLOSED" then
      .blocked_by[($issue.number | tostring)] = {
        task_ids: $issue.task_ids,
        issue_nums: $issue.issue_nums,
        has_defer_marker: $issue.defer
      }
    else . end
  | if $issue.defer then .defer_flags[($issue.number | tostring)] = true else . end
)
# Resolve task aliases after the complete task map exists, independent of input
# order. Filter both body and label edges without suppressing other blockers.
| .task_to_issue as $task_map
| reduce ($issues[] | select(.consolidation_parent != null)) as $child (.;
    ($child.number | tostring) as $key
    | $child.consolidation_parent as $parent
    | if .blocked_by[$key] != null then
        .blocked_by[$key].issue_nums |= map(select(. != $parent))
        | .blocked_by[$key].task_ids |= map(select(($task_map[.] | tostring) != $parent))
        | if (.blocked_by[$key].issue_nums | length) == 0 and (.blocked_by[$key].task_ids | length) == 0 then
            del(.blocked_by[$key])
          else . end
      else . end
  )

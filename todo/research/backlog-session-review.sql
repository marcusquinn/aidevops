-- SPDX-License-Identifier: MIT
-- SPDX-FileCopyrightText: 2026 Marcus Quinn
-- Read-only aggregate evidence for #32829; run against the local OpenCode 1 DB.
-- Emit no message bodies, tool arguments, credentials or private project paths.
WITH summaries AS (
    SELECT m.id, m.session_id, m.time_created,
           json_extract(p.data, '$.text') AS summary_text
    FROM message m JOIN part p ON p.message_id = m.id
    WHERE json_extract(m.data, '$.role') = 'assistant'
      AND json_extract(m.data, '$.summary') = 1
      AND json_extract(p.data, '$.type') = 'text'
    ORDER BY m.time_created DESC LIMIT 12
)
SELECT count(*) AS samples,
       sum(instr(summary_text, '## Objective') > 0
           AND instr(summary_text, '## Important Details') > 0
           AND instr(summary_text, '## Work State') > 0
           AND instr(summary_text, '## Next Move') > 0
           AND instr(summary_text, '## Relevant Files') > 0) AS host_headings,
       sum(instr(summary_text, 'Continuation required: yes') > 0) AS explicit_continuation,
       sum(instr(summary_text, '**active**') > 0
           OR instr(summary_text, '**satisfied**') > 0
           OR instr(summary_text, '**blocked**') > 0
           OR instr(summary_text, '**superseded**') > 0) AS objective_status,
       sum(instr(summary_text, 'ACTIVE') > 0
           OR instr(summary_text, 'DELIVERED') > 0
           OR instr(summary_text, 'EXTERNALLY_BLOCKED') > 0) AS next_move_status
FROM summaries;

WITH summaries AS (
    SELECT id, session_id, time_created FROM message
    WHERE json_extract(data, '$.role') = 'assistant'
      AND json_extract(data, '$.summary') = 1
    ORDER BY time_created DESC LIMIT 12
)
SELECT (SELECT json_extract(p.data, '$.tool') FROM part p
        WHERE p.session_id = s.session_id AND p.time_created > s.time_created
          AND json_extract(p.data, '$.type') = 'tool'
        ORDER BY p.time_created LIMIT 1) AS first_resumed_tool,
       count(*) AS samples
FROM summaries s GROUP BY first_resumed_tool;

-- These counts do not establish semantic aim preservation or OC2 cache reuse.

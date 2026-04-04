<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# agent-browser Benchmark Scripts

CLI-based. Uses `_time` helper to avoid repeating timing boilerplate per test.

## Sequential benchmark

```bash
#!/bin/bash
set -euo pipefail

_time() { local s e; s=$(python3 -c 'import time; print(time.time())'); "$@"; e=$(python3 -c 'import time; print(time.time())'); python3 -c "print(f'{$e - $s:.2f}')"; return 0; }

bench_navigate() { agent-browser open "https://the-internet.herokuapp.com/"; agent-browser screenshot /tmp/bench-ab-nav.png; agent-browser close; return 0; }
bench_formFill() { agent-browser open "https://the-internet.herokuapp.com/login"; agent-browser snapshot -i; agent-browser fill '@username' 'tomsmith'; agent-browser fill '@password' 'SuperSecretPassword!'; agent-browser click '@submit'; agent-browser wait --url '**/secure'; agent-browser close; return 0; }
bench_extract() { agent-browser open "https://the-internet.herokuapp.com/challenging_dom"; agent-browser eval "JSON.stringify([...document.querySelectorAll('table tbody tr')].slice(0,5).map(r=>r.textContent.trim()))"; agent-browser close; return 0; }
bench_multiStep() { agent-browser open "https://the-internet.herokuapp.com/"; agent-browser click 'a[href="/abtest"]'; agent-browser wait --url '**/abtest'; agent-browser get url; agent-browser close; return 0; }

echo "=== agent-browser Benchmark ==="
for test in navigate formFill extract multiStep; do
  echo -n "$test: "; for i in 1 2 3; do echo -n "$(_time bench_"$test")s "; done; echo ""
done
```

## Parallel benchmark — 3 parallel sessions

```bash
set -euo pipefail
start=$(python3 -c 'import time; print(time.time())')
agent-browser --session s1 open "https://the-internet.herokuapp.com/login" &
agent-browser --session s2 open "https://the-internet.herokuapp.com/checkboxes" &
agent-browser --session s3 open "https://the-internet.herokuapp.com/dropdown" &
wait
end=$(python3 -c 'import time; print(time.time())')
echo "3 parallel sessions: $(python3 -c "print(f'{$end - $start:.2f}')")s"
for s in s1 s2 s3; do echo "$s: $(agent-browser --session "$s" get url)"; done
for s in s1 s2 s3; do agent-browser --session "$s" close; done
```

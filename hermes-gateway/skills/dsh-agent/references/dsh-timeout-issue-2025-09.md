# DSH Timeout Issue — September 2025

## Observed Behaviour

| Tool | Result |
|------|--------|
| `mcp_dsh_carrot_agent_run` | **Always times out** after 600s (configured timeout) |
| `mcp_dsh_carrot_task_inbox` | Returns `taskId`, status stays `queued` forever |
| `mcp_dsh_carrot_task_result` | Returns `{"status":"queued"}` indefinitely |
| `mcp_dsh_carrot_model_list` | ✅ Works instantly |
| `mcp_dsh_carrot_session_list` | ✅ Works |
| `mcp_dsh_carrot_echo` | ✅ Works |

## Error Messages

```
MCP call failed: TimeoutError: MCP call timed out after 600.0s (configured timeout: 600.0s)
```

```
{"taskId":"...","status":"queued"}  // never progresses
```

## Session Transcript (Key Excerpts)

**Task 1: Create factorial.py + run for 20**
- `agent_run` → timeout 600s
- `task_inbox` → queued forever
- Cancelled after multiple polls

**Task 2: Search Python 3.14 news**
- Not attempted (DSH already confirmed broken)

**Task 3: List models**
- `model_list` → success, returned full provider/model list

## Root Cause Hypothesis

DSH agent container/process appears to be stuck or not processing queue. MCP bridge responds but the backing agent never completes a turn.

## Workaround Used in This Session

1. Detected DSH failure via repeated timeouts
2. Switched to local `terminal` + `file` tools for code execution
3. Used `model_list` for model info (only working DSH tool)
4. Informed user DSH unavailable, provided results via alternative path

## Additional Fallback Techniques (This Session)

### Local code execution via `execute_code`
When DSH `agent_run` times out, use `execute_code` for Python tasks:
```python
import os, subprocess
workspace = '/tmp/dsh_workspace'
os.makedirs(workspace, exist_ok=True)
# write file, run python3, capture output
```

### Web scraping via `execute_code` + `urllib` (when searxng also fails)
Successfully scraped Python 3.14 docs:
```python
import urllib.request, gzip, re
req = urllib.request.Request(url, headers={'Accept-Encoding': 'gzip'})
response = urllib.request.urlopen(req, timeout=10)
content = response.read()
if response.headers.get('Content-Encoding') == 'gzip':
    content = gzip.decompress(content)
html = content.decode('utf-8', errors='ignore')
# Parse with regex: toctree links → section IDs → extract section content
```

Key insight: Python's Sphinx docs use `id="section-name"` anchors in `<section>` tags. Extract toctree links first, then fetch each section by regex on the full HTML.

### User preference: one-line reports per task
User expects: `Задача N ✅: краткий результат в одну строку`

## Recommended Action for Future Sessions

- **Default to local tools** for code/file tasks (`execute_code` preferred over `terminal` for Python)
- Use `model_list` only for model discovery
- Report DSH status to user immediately on first timeout
- Do not waste time polling `task_inbox` — it will not complete
- For web research when both DSH and searxng fail: use `execute_code` + `urllib` with gzip handling
- After each multi-step task, give one-line summary per sub-task
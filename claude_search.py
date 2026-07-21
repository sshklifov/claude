#!/usr/bin/env python3
"""Substring-search across all Claude Code session history.

Usage: claude_search.py [--nvim] <substring> [substring2 ...]
  case-insensitive; ALL substrings must match the same message.
  --nvim  emit machine-readable, tab-separated rows (no ANSI):
            sessionid <TAB> cwd <TAB> timestamp <TAB> role <TAB> snippet
"""
import sys, json, glob, os
from datetime import date


def pretty_ts(ts):
    """'Today'/'Yesterday'/'Monday' if recent, else '2026-07-21', plus HH:MM."""
    if not ts:
        return ""
    day, clock = ts[:10], ts[11:16]
    try:
        d = date.fromisoformat(day)
    except ValueError:
        return f"{day} {clock}".strip()
    diff = (date.today() - d).days
    if diff == 0:
        label = "Today"
    elif diff == 1:
        label = "Yesterday"
    elif 2 <= diff <= 7:
        label = d.strftime("%A")
    else:
        label = day
    return f"{label} {clock}".strip()

args = sys.argv[1:]
nvim = False
if args and args[0] == "--nvim":
    nvim = True
    args = args[1:]

needles = [n.lower() for n in args]
if not needles:
    sys.exit("usage: claude_search.py [--nvim] <substring> ...")

def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for b in c:
            if isinstance(b, dict):
                parts.append(b.get("text") or b.get("content") or json.dumps(b.get("input", "")))
        return " ".join(str(p) for p in parts)
    return ""

results = []
for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") not in ("user", "assistant"):
                continue
            body = text_of(d.get("message", {}))
            low = body.lower()
            if all(n in low for n in needles):
                role = d.get("message", {}).get("role", "?")
                cwd = d.get("cwd", "?")
                branch = d.get("gitBranch", "")
                sid = d.get("sessionId", os.path.basename(path)[:-6])
                snippet = " ".join(body.split())
                ts = d.get("timestamp", "")
                if nvim:
                    # keep it single-line and tab-safe for the vim parser
                    row = "\t".join((sid, cwd, pretty_ts(ts), role, snippet[:200]))
                    results.append((ts, row.replace("\r", " ")))
                else:
                    row = (f"\033[36m{pretty_ts(ts)}\033[0m [{role}] \033[33m{cwd}\033[0m ({branch})\n"
                           f"    resume: claude --resume {sid}\n"
                           f"    {snippet[:160]}\n")
                    results.append((ts, row))

# newest first, by message timestamp
results.sort(key=lambda r: r[0], reverse=True)
for _, row in results:
    print(row)
print(f"--- {len(results)} match(es) ---", file=sys.stderr)

#!/usr/bin/env python3
"""Substring-search across all Claude Code session history.

Usage: claude_search.py [--nvim] [substring ...]
  case-insensitive; ALL substrings must match the same message.
  With no substring: list one row per session (first user prompt as the
  snippet), ordered by most-recent activity.
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


def messages(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") in ("user", "assistant"):
                yield d


args = sys.argv[1:]
nvim = False
if args and args[0] == "--nvim":
    nvim = True
    args = args[1:]

needles = [n.lower() for n in args]


def make_row(sid, cwd, ts, role, branch, snippet):
    # collapse whitespace so the snippet stays single-line and tab-safe
    snippet = " ".join(snippet.split())
    if nvim:
        return "\t".join((sid, cwd, pretty_ts(ts), role, snippet[:200]))
    return (f"\033[36m{pretty_ts(ts)}\033[0m [{role}] \033[33m{cwd}\033[0m ({branch})\n"
            f"    resume: claude --resume {sid}\n"
            f"    {snippet[:160]}\n")


results = []
paths = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))

if needles:
    for path in paths:
        for d in messages(path):
            body = text_of(d.get("message", {}))
            if all(n in body.lower() for n in needles):
                m = d.get("message", {})
                sid = d.get("sessionId", os.path.basename(path)[:-6])
                ts = d.get("timestamp", "")
                row = make_row(sid, d.get("cwd", "?"), ts,
                               m.get("role", "?"), d.get("gitBranch", ""), body)
                results.append((ts, row))
else:
    # one row per session: first real user prompt, sorted by latest activity
    for path in paths:
        sid = None
        cwd, branch, latest_ts, prompt = "?", "", "", None
        for d in messages(path):
            ts = d.get("timestamp", "")
            if ts > latest_ts:
                latest_ts = ts
            if sid is None:
                sid = d.get("sessionId", os.path.basename(path)[:-6])
            if cwd == "?" and d.get("cwd"):
                cwd = d.get("cwd")
            if not branch and d.get("gitBranch"):
                branch = d.get("gitBranch")
            if prompt is None and not d.get("isMeta") \
                    and d.get("message", {}).get("role") == "user":
                body = " ".join(text_of(d.get("message", {})).split())
                if body:
                    prompt = body
        if sid is None:
            continue
        results.append((latest_ts, make_row(
            sid, cwd, latest_ts, "session", branch, prompt or "(no prompt)")))

# newest first, by timestamp
results.sort(key=lambda r: r[0], reverse=True)
for _, row in results:
    print(row)
print(f"--- {len(results)} result(s) ---", file=sys.stderr)

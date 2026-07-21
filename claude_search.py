#!/usr/bin/env python3
"""Substring-search across all Claude Code session history.

Usage: claude_search.py [--nvim] <substring> [substring2 ...]
  case-insensitive; ALL substrings must match the same message.
  --nvim  emit machine-readable, tab-separated rows (no ANSI):
            sessionid <TAB> cwd <TAB> timestamp <TAB> role <TAB> snippet
"""
import sys, json, glob, os

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

hits = 0
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
                hits += 1
                role = d.get("message", {}).get("role", "?")
                cwd = d.get("cwd", "?")
                branch = d.get("gitBranch", "")
                sid = d.get("sessionId", os.path.basename(path)[:-6])
                snippet = " ".join(body.split())
                if nvim:
                    # keep it single-line and tab-safe for the vim parser
                    ts = d.get("timestamp", "")[:16]
                    row = "\t".join((sid, cwd, ts, role, snippet[:200]))
                    print(row.replace("\r", " "))
                else:
                    ts = d.get("timestamp", "")[:19]
                    print(f"\033[36m{ts}\033[0m [{role}] \033[33m{cwd}\033[0m ({branch})")
                    print(f"    resume: claude --resume {sid}")
                    print(f"    {snippet[:160]}\n")
print(f"--- {hits} match(es) ---", file=sys.stderr)

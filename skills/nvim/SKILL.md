---
name: nvim
description: Talk to the user's running neovim through claude#Api — run a vim command in their coding window and read its output. Use to see what they have open (windows, buffers, current file, cursor, visual range), read their quickfix list or LSP diagnostics, or run a command they defined (:Make and friends) instead of guessing at an equivalent shell command.
---

# Driving the user's nvim

`:Claude` runs me in a terminal buffer inside their nvim, so the editor is
already reachable — no setup, no `--listen` flag.

- `$NVIM` — the RPC socket of the instance I was launched from.
- `$CLAUDE_BUF` — my own terminal buffer number, which is how the API finds the
  buffer to work in.

If `$NVIM` is unset I was not started from inside nvim: say so, don't hunt for
another instance to poke at.

## The one call

```sh
nvim --server "$NVIM" --remote-expr "claude#Api('<command>', $CLAUDE_BUF)"
```

The command runs in the context of the most recently used file of my project —
the one `:Claude` was opened on, until they move to another. So `%` and
`FugitiveWorkTree()` mean what I expect, but `%` is *their* current file, not a
fact I set. With no project file loaded it falls back to my own terminal buffer:
global queries still work, `%` is then `term://…`. Check `%` when it matters.
That context is a *buffer*, not a window — it survives the window closing, and
can't quietly become a different file the way a window can.
The answer is the command's output, json-encoded — decode it once and it's
exactly what vim echoed.

**Ask for data by echoing it**, and json-encode structures on the vim side:

```sh
# what is open, and where
claude#Api('echo json_encode(map(getwininfo(), {_,w -> [w.winid, w.tabnr, bufname(w.bufnr)]}))', $CLAUDE_BUF)
claude#Api('echo json_encode(map(getbufinfo({"buflisted":1}), {_,b -> b.name}))', $CLAUDE_BUF)
claude#Api('echo json_encode([expand("%:p"), line("."), FugitiveWorkTree()])', $CLAUDE_BUF)

# their quickfix list, and clangd's view of the file
claude#Api('echo json_encode(getqflist({"title":1,"items":1}))', $CLAUDE_BUF)
claude#Api('echo json_encode(luaeval("vim.diagnostic.get(0)"))', $CLAUDE_BUF)

# a command they defined
claude#Api('Make', $CLAUDE_BUF)
```

Quoting: single-quote the vim command for the shell; inside a vimscript
double-quoted string escape nested quotes as `\"`. Keep the outer
`--remote-expr` argument double-quoted so `$CLAUDE_BUF` expands.

## Reading the answer

- `"…"` — the output. Empty string means the command said nothing, which for
  most `:commands` is success.
- `"claude#Api: N is not a claude session buffer"` — `$CLAUDE_BUF` was wrong or
  its terminal is gone. Nothing ran. Check the variable; don't retry elsewhere.
- `"Vim:E492: Not an editor command: …"` and friends — my command was wrong,
  not their editor. Fix it and retry.

## Async commands

Anything job-backed (`:Make`) returns long before it finishes. There is no
completion signal in the API yet, so **never report a build result I haven't
seen**. If the command hands back a job id, `jobwait([id], 0)[0]` is `-1` while
it lives and `-3` once reaped — and by the time it stops saying `-1` the job's
own callbacks have run, so the quickfix list is complete. Otherwise, ask the
user how it went, or check back on `getqflist()`.

## House rules

- Query freely. State-changing commands are fine when they serve the task, but
  never anything outward-facing or irreversible (`:Push`, a deploy) without
  asking first, whatever the permission mode allows.
- Don't rearrange their editor: no writing buffers, no `:q`, no opening or
  closing windows. Resizing the pty reflows the claude TUI and tears it. Window
  commands are meaningless here anyway — the command runs in a buffer context
  with no window of its own.
- Don't send keystrokes (`--remote-send`). One command, one answer.
- Every call is logged in vim; the user reads it with `:ClaudeLog` and presses
  `<CR>` for the full answer. Assume they are watching.

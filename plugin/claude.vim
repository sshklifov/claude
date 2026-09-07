" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists(':Claude')
  finish
endif

function! s:FindClaudeExecutable()
  let found = ['~/.local/bin/claude', '~/bin/claude',
        \ '/opt/homebrew/bin/claude', '/home/linuxbrew/.linuxbrew/bin/claude', 'claude']
  call filter(map(found, 'expand(v:val)'), 'executable(v:val)')
  return get(found, 0, '')
endfunction

if !exists('g:claude_executable')
  let g:claude_executable = s:FindClaudeExecutable()
endif

" Claude only finds skills under ~/.claude/skills, but ours ships with the
" plugin: opt in and we link it there, so a fresh machine needs no `ln -s`.
let s:skill = expand('<sfile>:p:h:h') .. '/skills/nvim'

function! s:InstallSkill()
  if !get(g:, 'claude_install_skill', v:false)
    return
  endif
  let link = expand('~/.claude/skills/nvim')
  if !empty(getftype(link))
    return
  endif
  call mkdir(fnamemodify(link, ':h'), 'p')
  " Vimscript has no symlink(): ln does, and tells us why if it won't.
  let out = system(['ln', '-s', s:skill, link])
  if v:shell_error
    call init#Warn("Claude: could not link the skill: %s", trim(out))
  endif
endfunction

" Plugin options are usually set after the plugins load, so ask once we're up.
autocmd VimEnter * ++once call s:InstallSkill()

" The topmost window on a file of a:root, else 0. Windows are numbered top-down,
" and claude sits in a bottom split, so the first hit is the one above us.
function! s:CodingWin(root)
  let wins = filter(range(1, winnr('$')),
        \ 'getbufvar(winbufnr(v:val), "&buftype") == ""
        \  && stridx(getbufinfo(winbufnr(v:val))[0].name, a:root) == 0')
  return empty(wins) ? 0 : win_getid(wins[0])
endfunction

" Open a claude terminal in a bottom split, wired for <CR> to open diff refs.
function! s:OpenClaudeTerm(args, root)
  below sp
  enew
  " Claude gets its own buffer number, so claude#Api() can find b:root_dir.
  call init#Termopen([g:claude_executable] + a:args,
        \ #{cwd: a:root, env: #{CLAUDE_BUF: bufnr()}, lock_mode: v:true})
  let b:root_dir = a:root
  if a:args[0] ==# '--resume'
    " Known outright: read that transcript directly instead of guessing.
    let b:claude_session_id = a:args[1]
  else
    " Nothing written yet for a session that just started: show $0 rather
    " than guess and risk picking up a sibling session's transcript in the
    " same project. The first throttled check (see s:CheckCost) will have
    " its own transcript to find by then.
    let b:claude_cost_sl = ' [$0.00]'
    let b:claude_cost_at = localtime()
  endif
  " Resizing the pty reflows the TUI, tearing what it already drew: sit still.
  setlocal winfixwidth winfixheight
  " Keep a long session navigable; ]c pays ~35ms to scan this many lines.
  setlocal scrollback=100000
  nnoremap <buffer> <CR> <cmd>call <SID>ClaudeOpenRef()<CR>
  nnoremap <buffer> ]p <cmd>call <SID>JumpTo(v:count1, <SID>PromptLines())<CR>
  nnoremap <buffer> [p <cmd>call <SID>JumpTo(-v:count1, <SID>PromptLines())<CR>
  nnoremap <buffer> [P <cmd>call <SID>JumpTo(-line('$'), <SID>PromptLines())<CR>
  nnoremap <buffer> ]P <cmd>exe get(map(matchbufline('%','^❯',1,'$'),'v:val.lnum'),-1,'')<CR>
  nnoremap <buffer> ]c <cmd>call <SID>JumpTo(v:count1, <SID>HunkLines())<CR>
  nnoremap <buffer> [c <cmd>call <SID>JumpTo(-v:count1, <SID>HunkLines())<CR>
  nnoremap <buffer> <C-l> <cmd>call <SID>TrimScrollback()<CR>
  " The plan limits, shared by all sessions, then this session's own cost.
  setlocal statusline=%{%claude#Limits()%}%{%claude#Cost()%}
  call s:CheckUsage()
  " Percentages rot, the 5-hour one fastest. Every prompt and every line claude
  " prints changes this buffer, so that is our "something happened" event.
  augroup ClaudeLimits
    exe printf('autocmd BufEnter,TextChangedT <buffer=%d> call s:CheckUsage()', bufnr())
  augroup END
  startinsert
endfunction

" Experimental: scrollback isn't reflown on resize, so it tears. Trimming alone
" leaves the torn rows that are still on the live screen, so first make claude
" repaint it with its own Ctrl-L, then drop everything the repaint pushed up.
function! s:TrimScrollback()
  let buf = bufnr()
  let keep = &l:scrollback
  call chansend(&channel, "\<C-l>")
  " The repaint scrolls the old screen out first: trim once it has landed.
  call timer_start(50, {-> s:RunIn(buf,
        \ printf('setlocal scrollback=1 | setlocal scrollback=%d', keep))})
endfunction

" Jump a:n lines of a:lnums forward, or backward if a:n is negative.
function! s:JumpTo(n, lnums)
  let lnums = filter(copy(a:lnums), 'a:n * (v:val - line(".")) > 0')
  if a:n < 0
    call reverse(lnums)
  endif
  if empty(lnums)
    return
  endif
  let lnum = lnums[min([abs(a:n), len(lnums)]) - 1]
  exe 'normal! ' .. lnum .. 'Gzt'
  " Land on the text, not the `❯`/`●` marker.
  call cursor(lnum, matchend(getline(lnum), '\v^\s*\S\s*') + 1)
endfunction

" Tool header, e.g. `● Update(path)`, with the path captured.
let s:tool_header = '\v^\s*●\s+%(Update|Edit|MultiEdit|Write|Create|Read)\((.{-})\)'

" Lines of the prompts you typed (TUI: `❯ text` at column 1, dup'd by redraws).
function! s:PromptLines()
  let seen = {}
  for m in matchbufline('%', '^❯\s\+\S.*', 1, '$')
    " Skip the input box at the bottom: it sits under a rule.
    if getline(m.lnum - 1) !~# '^─\{20,}'
      let seen[trim(m.text)] = m.lnum
    endif
  endfor
  return sort(values(seen), 'n')
endfunction

" Lines of the tool headers, i.e. where a file was read or changed.
function! s:HunkLines()
  return map(matchbufline('%', s:tool_header, 1, '$'), 'v:val.lnum')
endfunction

" Line nearest to a:expected_lnum whose trimmed text equals a:text
function! s:FindSourceLine(expected_lnum, text)
  let nums = range(1, line('$'))
  call filter(nums, 'trim(getline(v:val)) ==# a:text')
  call map(nums, 'v:val - a:expected_lnum')
  call sort(nums, {x, y -> abs(x) - abs(y)})
  return empty(nums) ? a:expected_lnum : a:expected_lnum + nums[0]
endfunction

" In a claude diff/file view, take the gutter line number on the current line
" and the filename from the nearest tool header above, then open there.
" (Coupled to the TUI format: `Update(path)` headers + a leading line-number
" gutter on content lines.)
function! s:ClaudeOpenRef()
  let raw = getline('.')
  let lnum = str2nr(matchstr(raw, '\v^\s*\zs\d+'))
  if lnum <= 0
    return
  endif
  " Code on this line (minus gutter number and diff marker) to verify the jump.
  let text = trim(substitute(raw, '\v^\s*\d+\s*[-+]?', '', ''))
  let path = ""
  for i in range(line('.'), 1, -1)
    let m = matchlist(getline(i), s:tool_header)
    if !empty(m)
      let path = m[1]
      break
    endif
  endfor
  if empty(path)
    return init#Warn("ClaudeOpen: no file header found")
  endif
  let path = expand(path)  " resolve a leading ~
  let root = b:root_dir
  let fullname = path[0] == '/' ? path : root .. '/' .. path
  if !filereadable(fullname)
    return init#Warn("ClaudeOpen: no such file: %s", fullname)
  endif

  " Go to a window already on the project; open one if there is none.
  if !win_gotoid(s:CodingWin(root))
    " Split off the top, not off us: splitting here would resize the pty.
    topleft sp
  endif
  exe 'edit ' .. fnameescape(fullname)
  let lnum = s:FindSourceLine(lnum, text)
  exe 'normal ' .. lnum .. 'G'
  normal z.
endfunction

""""""""""""""""""""""""""""Claude interactive"""""""""""""""""""""""""""" {{{
" The prompt text for a:args, prefixed with where we are (file, range, context).
function! s:MakePrompt(args, root, first, last)
  let filename = expand('%:p')
  if isdirectory(filename)
    return a:args
  elseif filereadable(filename)
    let marker = ""
    if stridx(filename, a:root) == 0
      let filename = filename[len(a:root):]
      if filename[0] == '/'
        let filename = filename[1:]
      endif
      let marker = "@"
    endif
    let whole_file = a:first == 1 && a:last == line('$')
    if whole_file
      return printf('In %s%s: %s', marker, filename, a:args)
    endif
    return printf('In %s%s lines %d-%d: %s', marker, filename, a:first, a:last, a:args)
  endif
  let context = join(getline(a:first, a:last), "\n")
  return printf("%s\n%s", a:args, context)
endfunction

" Write the prompt at leisure; :w sends it off, :q! throws it away.
function! s:ClaudePromptBuffer(text, root)
  below sp
  call init#BufInput('claude-prompt', #{lines: split(a:text, "\n", v:true),
        \ msg: "Prompt not sent; do :w to send it, :q! to drop it"},
        \ expand('<SID>') .. 'SendPrompt', a:root)
endfunction

" :w sends and closes, so there is no second step to remember (empty: cancel).
function! s:SendPrompt(root)
  let nr = bufnr()
  let text = trim(join(getline(1, '$'), "\n"))
  setlocal nomodified
  exe 'bwipeout ' .. nr
  if !empty(text)
    " We're still inside the write: open the terminal once it has settled.
    call timer_start(0, {-> s:OpenClaudeTerm([text], a:root)})
  endif
endfunction

function! s:ClaudeInteractive(args) range
  let root = FugitiveWorkTree()
  if empty(root)
    let root = getcwd()
  endif
  let text = s:MakePrompt(a:args, root, a:firstline, a:lastline)
  if empty(a:args)
    return s:ClaudePromptBuffer(text, root)
  endif
  call s:OpenClaudeTerm([text], root)
endfunction

command! -nargs=* -range=% Claude <line1>,<line2>call s:ClaudeInteractive(<q-args>)
" }}}

""""""""""""""""""""""""""""Claude resume by history search"""""""""""""""""""""""""""" {{{
let s:script = expand('<sfile>:p:h:h') .. '/claude_search.py'

" Field colors for the ClaudeResume quickfix; override these at your leisure.
highlight default link ClaudeResumeTime Number
highlight default link ClaudeResumeDir Directory
highlight default link ClaudeResumeId Comment
highlight default link ClaudeResumePrompt String

function! s:ClaudeResume(bang, ...)
  " No args: python lists one row per session (see claude_search.py).
  let cmd = ['python3', s:script]
  if !empty(a:bang)
    " Scope to the current project
    let root = FugitiveWorkTree()
    let cmd += ['--path', empty(root) ? getcwd() : root]
  endif
  let cmd += a:000
  call init#OnJobOutput(cmd, expand('<SID>') .. 'OnSearchResults')
endfunction

function! s:OnSearchResults(data)
  let rows = filter(copy(a:data), '!empty(v:val)')
  if empty(rows)
    echo "ClaudeResume: no matches"
    return
  endif
  let fields = map(copy(rows), 'split(v:val, "\t", v:true)')
  let fields = filter(fields, 'len(v:val) >= 5')
  " f = [sid, cwd, ts, role, snippet]
  let lines = map(copy(fields), {_, f -> [
        \ [printf('%-16s  ', f[2]), 'ClaudeResumeTime'],
        \ [printf('%-30s', f[1]), 'ClaudeResumeDir'],
        \ [printf(' [%s] ', f[0][:4]), 'ClaudeResumeId'],
        \ [f[4], 'ClaudeResumePrompt'],
        \ ]})
  let data = map(copy(fields), '#{id: v:val[0], cwd: v:val[1]}')
  let nr = qutil#CreateCustomQuickfix(lines, "ClaudeResume", function('s:OnResumeSession'))
  call qutil#SetLineData(nr, data)
endfunction

function! s:OnResumeSession()
  let entry = qutil#GetLineData()
  let id = entry.id
  " Resume is scoped to a project dir, so it must run in the session's own cwd.
  let cwd = entry.cwd
  if empty(cwd) || !isdirectory(cwd)
    call init#Warn("ClaudeResume: session %s has no usable cwd (%s)", id, cwd)
    return
  endif

  quit
  call s:OpenClaudeTerm(["--resume", id], cwd)
endfunction

command! -bang -nargs=* ClaudeResume call s:ClaudeResume("<bang>", <f-args>)
" }}}

""""""""""""""""""""""""""""Usage stats"""""""""""""""""""""""""""" {{{
let s:cc_usage = expand('<sfile>:p:h:h') .. '/cc-usage'

" Token/cost usage: by default today's, with its sessions and the plan limits.
function! s:ClaudePlan(args)
  let args = empty(a:args) ? ['today', '-l', '-s'] : s:UsageArgs(a:args)
  call init#OnJobOutput([s:cc_usage] + args, expand('<SID>') .. 'OnUsage')
endfunction

" The period can be a phrase: ':Plan last friday -s' -> ['last friday', '-s'].
function! s:UsageArgs(args)
  let words = split(a:args)
  let n = 0
  while n < len(words) && words[n][0] !=# '-'
    let n += 1
  endwhile
  return n > 1 ? [join(words[: n - 1])] + words[n :] : words
endfunction

function! s:OnUsage(data)
  " stdout ends in an empty element (the stream's final newline): drop it.
  let lines = empty(get(a:data, -1, 'x')) ? a:data[:-2] : a:data
  if empty(lines)
    return init#Warn("Plan: cc-usage said nothing")
  endif
  call init#CustomBottomBuffer('cc-usage', lines)
  exe 'resize ' .. min([len(lines), &lines / 2])
endfunction

command! -nargs=* Plan call s:ClaudePlan(<q-args>)

" Zones for the limits statusline, as a percentage of a plan window.
let g:claude_limit_yellow = get(g:, 'claude_limit_yellow', 70)
let g:claude_limit_red = get(g:, 'claude_limit_red', 90)

" How close the plan windows are: knowing you are one prompt from the 5-hour
" wall is worth having in front of you, not a :Plan away. It goes in the
" session's statusline -- showmode's -- TERMINAL -- wipes any cmdline message,
" and a winbar would take a screen line, resizing (and tearing) the pty.
"
" The windows are account-wide, so all sessions read one figure: whoever asks
" first pays for it, the rest just redraw. This is what their statusline calls.
let s:limits_sl = ''

function! claude#Limits()
  return s:limits_sl
endfunction

" What this session has run up at API list prices; per buffer, unlike the
" limits, so the statusline reads it off the terminal it is drawing.
function! claude#Cost()
  return get(b:, 'claude_cost_sl', '')
endfunction

" Claude redraws many times a second, so throttle; the snapshot behind this is
" only refetched every 5 minutes anyway (see cc-usage), so a minute is plenty.
let s:limit_interval = 60
let s:limits_at = 0

function! s:CheckUsage()
  call s:CheckLimits()
  call s:CheckCost()
endfunction

function! s:CheckLimits()
  if localtime() - s:limits_at < s:limit_interval
    return
  endif
  let s:limits_at = localtime()
  call init#OnJobOutput([s:cc_usage, '--brief'], expand('<SID>') .. 'OnLimits')
endfunction

" Throttled per buffer, not account-wide: each session bills its own.
function! s:CheckCost()
  if localtime() - get(b:, 'claude_cost_at', 0) < s:limit_interval
    return
  endif
  let b:claude_cost_at = localtime()
  let cmd = [s:cc_usage, '-c', b:root_dir]
  " Known outright for a resumed session; a fresh one is still guessed by
  " last touched in this project (fine once it has actually been used).
  if !empty(get(b:, 'claude_session_id', ''))
    let cmd += ['--session-id', b:claude_session_id]
  endif
  call init#OnJobOutput(cmd, expand('<SID>') .. 'OnCost', bufnr())
endfunction

function! s:OnCost(bufnr, data)
  let cost = trim(get(a:data, 0, ''))
  if empty(cost)
    return
  endif
  call setbufvar(a:bufnr, 'claude_cost_sl', printf(' [$%s]', cost))
  redrawstatus!
endfunction

function! s:OnLimits(data)
  " Rows of `name<TAB>percent<TAB>resets`, tightest first; none means no data.
  let rows = map(filter(copy(a:data), '!empty(v:val)'), 'split(v:val, "\t", v:true)')
  call filter(rows, 'len(v:val) >= 3')
  if empty(rows)
    return
  endif
  let worst = str2nr(rows[0][1])
  let hl = worst >= g:claude_limit_red ? 'ErrorMsg'
        \ : worst >= g:claude_limit_yellow ? 'WarningMsg' : 'MoreMsg'
  " The reset time only matters once a window is tight enough to wait on.
  let msg = join(map(copy(rows),
        \ 'printf("[%s %d%%%s]", v:val[0], str2nr(v:val[1]),
        \   str2nr(v:val[1]) >= g:claude_limit_yellow && !empty(v:val[2])
        \     ? ", " .. v:val[2] : "")'), ' ')
  " In a statusline a % is an escape; ours are literal text.
  let s:limits_sl = '%#' .. hl .. '#' .. substitute(msg, '%', '%%', 'g') .. '%*'
  redrawstatus!
endfunction
" }}}

""""""""""""""""""""""""""""Claude remote API"""""""""""""""""""""""""""" {{{
" What claude asked of us, newest last. See skills/nvim/SKILL.md.
let s:api_log = []

" Field colors for the ClaudeLog quickfix; override these at your leisure.
highlight default link ClaudeLogTime Number
highlight default link ClaudeLogCmd Identifier
highlight default link ClaudeLogText String

" a:cmd in a:bufnr's context, no window needed: a window can be closed, or keep
" its id while another buffer moves in, whereas a buffer stays what it was.
function! s:RunIn(bufnr, cmd)
  return trim(luaeval('vim.api.nvim_buf_call(_A[1],
        \ function() return vim.fn.execute(_A[2]) end)', [a:bufnr, a:cmd]))
endfunction

" The buffer claude works in: the project file used most recently, i.e. the one
" claude was opened on until someone moves on, else claude's own terminal. Every
" candidate belongs to b:root_dir, so this can't wander into another project.
function! s:CodingBuf(termbuf)
  " Never 0: there is no "no buffer" to run in, and 0 would read whatever the
  " user happens to be sitting on, in whatever project that is.
  if a:termbuf <= 0 || !bufexists(a:termbuf)
    return -1
  endif
  let root = getbufvar(a:termbuf, 'root_dir', '')
  if empty(root)
    return a:termbuf
  endif
  let bufs = filter(getbufinfo(#{bufloaded: 1, buflisted: 1}),
        \ 'getbufvar(v:val.bufnr, "&buftype") == "" && stridx(v:val.name, root) == 0')
  " lastused ticks in whole seconds, so ties are common: newest buffer wins.
  call sort(bufs, {a, b -> a.lastused != b.lastused
        \ ? b.lastused - a.lastused : b.bufnr - a.bufnr})
  return empty(bufs) ? a:termbuf : bufs[0].bufnr
endfunction

" Run a:cmd for claude, over `nvim --server $NVIM --remote-expr`, and answer with
" its output as json. Ask for data by echoing it: `echo json_encode(getwininfo())`.
" a:1 is claude's own terminal buffer, which it knows as $CLAUDE_BUF; with no
" file left to work in we fall back to that terminal, never to the current buffer.
function! claude#Api(cmd, ...)
  let termbuf = str2nr(get(a:000, 0, 0))
  let buf = s:CodingBuf(termbuf)
  if buf <= 0
    let out = printf('claude#Api: %d is not a claude session buffer', termbuf)
  else
    try
      let out = s:RunIn(buf, a:cmd)
    catch
      let out = v:exception
    endtry
  endif
  call add(s:api_log, #{time: strftime('%H:%M:%S'), cmd: a:cmd, out: out})
  return json_encode(out)
endfunction

function! s:ClaudeLog()
  if empty(s:api_log)
    return init#Warn("ClaudeLog: nothing yet")
  endif
  let lines = map(copy(s:api_log), {_, e -> [
        \ [e.time .. '  ', 'ClaudeLogTime'],
        \ [printf('%-40.40s  ', e.cmd), 'ClaudeLogCmd'],
        \ [substitute(e.out[:200], '\n', ' ', 'g'), 'ClaudeLogText'],
        \ ]})
  let nr = qutil#CreateCustomQuickfix(lines, "ClaudeLog", expand('<SID>') .. 'ShowLogEntry')
  call qutil#SetLineData(nr, copy(s:api_log))
endfunction

" The whole call and its answer, untruncated.
function! s:ShowLogEntry()
  let entry = qutil#GetLineData()
  echo entry.cmd .. "\n" .. entry.out
endfunction

command! -nargs=0 ClaudeLog call s:ClaudeLog()
" }}}

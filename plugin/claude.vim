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
" a:1 is an opts dict: new_window (default true), false opens it in this one.
function! s:OpenClaudeTerm(args, root, ...)
  let opts = get(a:000, 0, #{})
  if get(opts, 'new_window', v:true)
    call init#SmartSplit('below')
  else
    enew
  endif
  " Name a new session ourselves, so its transcript is known before it exists.
  let args = a:args[0] ==# '--resume' ? a:args : ['--session-id', s:Uuid()] + a:args
  " A later /clear or /resume starts another session: the hook tells us which.
  let hook = #{type: 'command', command: shellescape(s:session_hook)}
  let settings = json_encode(#{hooks: #{SessionStart: [#{hooks: [hook]}]}})
  " Claude gets its own buffer number, so claude#Api() can find b:root_dir.
  call init#Termopen([g:claude_executable, '--settings', settings] + args,
        \ #{cwd: a:root, env: #{CLAUDE_BUF: bufnr()}, lock_mode: v:true})
  let b:root_dir = a:root
  let b:claude_session_id = args[1]
  " Resizing the pty reflows the TUI, tearing what it already drew: sit still.
  setlocal winfixwidth winfixheight
  " Keep a long session navigable; ]c pays ~35ms to scan this many lines.
  setlocal scrollback=100000
  nnoremap <buffer> <CR> <cmd>call <SID>ClaudeOpenRef()<CR>
  call s:MapPromptJumps()
  nnoremap <buffer> ]c <cmd>call <SID>JumpTo(v:count1, <SID>HunkLines())<CR>
  nnoremap <buffer> [c <cmd>call <SID>JumpTo(-v:count1, <SID>HunkLines())<CR>
  nnoremap <buffer> <C-l> <cmd>call <SID>TrimScrollback()<CR>
  " The plan limits, shared by all sessions, then this session's own cost and
  " model in the middle.
  setlocal statusline=%{%claude#Limits()%}%{claude#Middle()}
  " Percentages rot, the 5-hour one fastest. Every prompt and every line claude
  " prints changes this buffer, so that is our "something happened" event.
  augroup ClaudeLimits
    exe printf('autocmd BufEnter,TextChangedT <buffer=%d> call s:CheckUsage()', bufnr())
  augroup END
  startinsert
endfunction

" A random (version 4) UUID.
function! s:Uuid()
  let r = map(range(4), 'rand()')
  return printf('%08x-%04x-4%03x-%04x-%04x%08x', r[0], r[1] % 0x10000,
        \ r[1] / 0x10000 % 0x1000, 0x8000 + r[2] % 0x4000, r[2] / 0x10000, r[3])
endfunction

let s:session_hook = expand('<sfile>:p:h:h') .. '/claude-session-hook'

" Scrollback isn't reflown on resize, so it tears. Trimming alone leaves the
" torn rows that are still on the live screen, so first make claude repaint it
" with its own Ctrl-L, then drop everything the repaint pushed up.
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

" The TUI pads ⎿ with a non-breaking space, which \s doesn't match.
let s:file_headers = [
      \ '\v^\s*●\s+%(Update|Edit|MultiEdit|Write|Create|Read)\((.{-})\)',
      \ '\v^\s*⎿[[:space:] ]+Updated\s+(\S+)',
      \ ]

" ]p/[p between your prompts, [P/]P to the first/last one.
function! s:MapPromptJumps()
  nnoremap <buffer> ]p <cmd>call <SID>JumpTo(v:count1, <SID>PromptLines())<CR>
  nnoremap <buffer> [p <cmd>call <SID>JumpTo(-v:count1, <SID>PromptLines())<CR>
  nnoremap <buffer> [P <cmd>call <SID>JumpTo(-line('$'), <SID>PromptLines())<CR>
  nnoremap <buffer> ]P <cmd>exe get(map(matchbufline('%','^❯',1,'$'),'v:val.lnum'),-1,'')<CR>
endfunction

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

" Lines of the file headers, i.e. where a file was read or changed.
function! s:HunkLines()
  let lnums = []
  for pat in s:file_headers
    let lnums += map(matchbufline('%', pat, 1, '$'), 'v:val.lnum')
  endfor
  call sort(lnums, 'n')
  " An Update(path) has its own summary right under it: one stop, not two.
  return filter(copy(lnums), 'v:key == 0 || lnums[v:key - 1] != v:val - 1')
endfunction

" Line nearest to a:expected_lnum whose trimmed text equals a:text
function! s:FindSourceLine(expected_lnum, text)
  let nums = range(1, line('$'))
  call filter(nums, 'trim(getline(v:val)) ==# a:text')
  call map(nums, 'v:val - a:expected_lnum')
  call sort(nums, {x, y -> abs(x) - abs(y)})
  return empty(nums) ? a:expected_lnum : a:expected_lnum + nums[0]
endfunction

" The file line a:lnum is a header of, only if it passes every check and names a
" file that is actually there; else ''.
function! s:HeaderFile(lnum)
  let m = filter(map(copy(s:file_headers), 'matchlist(getline(a:lnum), v:val)'), '!empty(v:val)')
  if empty(m)
    return ''
  endif
  let path = expand(m[0][1])  " resolve a leading ~
  if path[0] == '/'
    let found = [path]
  else
    " Relative to wherever claude was, so try our root, then the files we
    " have open or had lately that end in it.
    let found = [b:root_dir .. '/' .. path]
          \ + map(getbufinfo(#{buflisted: 1}), 'v:val.name') + v:oldfiles
    call filter(found, 'v:key == 0 || v:val[-len(path) - 1:] ==# "/" .. path')
  endif
  return get(filter(found, 'filereadable(v:val)'), 0, '')
endfunction

" In a claude diff/file view, take the gutter line number on the current line
" and the file from the nearest header above, then open there.
" (Coupled to the TUI format: see s:file_headers, plus a leading line-number
" gutter on content lines.)
function! s:ClaudeOpenRef()
  let raw = getline('.')
  let lnum = str2nr(matchstr(raw, '\v^\s*\zs\d+'))
  if lnum <= 0
    return
  endif
  " Code on this line (minus gutter number and diff marker) to verify the jump.
  let text = trim(substitute(raw, '\v^\s*\d+\s*[-+]?', '', ''))
  let fullname = ''
  for i in range(line('.'), 1, -1)
    let fullname = s:HeaderFile(i)
    if !empty(fullname)
      break
    endif
  endfor
  if empty(fullname)
    return init#Warn("ClaudeOpen: no file header found")
  endif
  let root = b:root_dir

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
    let lines = a:first == a:last ? printf('line %d', a:first)
          \ : printf('lines %d-%d', a:first, a:last)
    return printf('In %s%s %s: %s', marker, filename, lines, a:args)
  endif
  let context = join(getline(a:first, a:last), "\n")
  " Linux caps one argv string at 128K, and long before that a paste just floods
  " the prompt: hand over a file instead.
  if len(context) >= 16384
    let path = tempname()
    call writefile(getline(a:first, a:last), path)
    " No @: inlining a file this size would blow the context; let claude page it.
    return printf("%s\n(the text of %s is in %s)", a:args, bufname(), path)
  endif
  return printf("%s\n%s", a:args, context)
endfunction

" Write the prompt at leisure; :w sends it off, :q! throws it away.
function! s:ClaudePromptBuffer(text, root)
  " One draft at a time: its name is taken until it is sent or dropped.
  if win_gotoid(get(win_findbuf(bufnr('^claude-prompt$')), 0))
    return init#Warn("Claude: finish this prompt first (:w sends, :q! drops)")
  endif
  call init#SmartSplit('below')
  call init#BufInput('claude-prompt', #{lines: split(a:text, "\n", v:true),
        \ msg: "Prompt not sent; do :w to send it, :q! to drop it"},
        \ expand('<SID>') .. 'SendPrompt', a:root)
  " Prose, not code: wrap for reading, and hard-wrap at 120 as you type so
  " no line grows wider than that regardless of window width. No 'a' in
  " formatoptions: it reflows the whole paragraph on every edit, pulling the
  " next line up into the one you are fixing.
  setlocal wrap linebreak breakindent textwidth=120
  setlocal spell
endfunction

" :w sends and closes, so there is no second step to remember (empty: cancel).
function! s:SendPrompt(root)
  let nr = bufnr()
  let text = trim(join(getline(1, '$'), "\n"))
  setlocal nomodified
  exe 'bwipeout ' .. nr
  if !empty(text)
    " We're still inside the write: open the terminal once it has settled.
    call timer_start(0, {-> s:OpenClaudeTerm(['--', text], a:root)})
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
  " `--` ends the options: a prompt starting with `-` is still a prompt.
  call s:OpenClaudeTerm(['--', text], root)
endfunction

command! -nargs=* -range=% Claude <line1>,<line2>call s:ClaudeInteractive(<q-args>)

" The claude session here, else the first one shown in this tab, else -1.
function! s:SessionBuf()
  let bufs = [bufnr()] + tabpagebuflist()
  call filter(bufs, 'getbufvar(v:val, "&buftype") ==# "terminal"
        \ && !empty(getbufvar(v:val, "root_dir"))')
  return get(bufs, 0, -1)
endfunction

" Plain names for claude's model aliases; anything else goes through as is.
let g:claude_models = get(g:, 'claude_models', #{
      \ cheap: 'haiku', fast: 'sonnet', smart: 'opus[1m]', smartest: 'fable'})

" Switch the session at hand; claude's /model also saves it as the default.
function! s:ClaudeModel(name)
  let model = get(g:claude_models, a:name, a:name)
  let buf = s:SessionBuf()
  if buf < 0
    " No session to run /model: save the default where it would have. Edit the
    " text in place, since json_encode() would flatten the file to one line.
    let path = expand('~/.claude/settings.json')
    let text = filereadable(path) ? join(readfile(path), "\n") : "{\n}"
    let entry = '"model": ' .. json_encode(model)
    if text =~# '"model":\s*"[^"]*"'
      let text = substitute(text, '"model":\s*"[^"]*"', '\=entry', '')
    else
      " First key, then drop the comma if it was the only one.
      let text = substitute(text, '{', '\="{\n  " .. entry .. ","', '')
      let text = substitute(text, ',\(\_s*}\)', '\1', '')
    endif
    call writefile(split(text, "\n", v:true), path)
    return
  endif
  call chansend(getbufvar(buf, '&channel'), '/model ' .. model .. "\r")
  " The transcript only learns of it with the next reply: show it till then.
  call setbufvar(buf, 'claude_model', model)
  call setbufvar(buf, 'claude_model_at', localtime())
  redrawstatus!
endfunction

command! -nargs=1 -complete=customlist,s:CompleteModel ClaudeModel call s:ClaudeModel(<q-args>)

function! s:CompleteModel(lead, ...)
  return filter(sort(keys(g:claude_models)), 'v:val =~# "^" .. a:lead')
endfunction
" }}}

""""""""""""""""""""""""""""Claude resume by history search"""""""""""""""""""""""""""" {{{
let s:script = expand('<sfile>:p:h:h') .. '/claude_search.py'

" Field colors for the ClaudeResume quickfix; override these at your leisure.
highlight default link ClaudeResumeTime Number
highlight default link ClaudeResumeDir Directory
highlight default link ClaudeResumeId Comment
highlight default link ClaudeResumePrompt String
highlight default link ClaudeResumeMatch Search
highlight default link ClaudeResumeSeen Comment

function! s:ClaudeResume(bang, ...)
  " No args: python lists one row per session (see claude_search.py).
  let cmd = ['python3', s:script]
  if !empty(a:bang)
    " Scope to the current project
    let root = FugitiveWorkTree()
    let cmd += ['--path', empty(root) ? getcwd() : root]
  endif
  let cmd += a:000
  call init#OnJobOutput(cmd, expand('<SID>') .. 'OnSearchResults', a:000)
endfunction

" a:text as chunks, with what a:needles matched (case-insensitively) picked out.
function! s:MarkNeedles(text, needles)
  if empty(a:needles)
    return [[a:text, 'ClaudeResumePrompt']]
  endif
  let pat = '\c\V' .. join(map(copy(a:needles), 'escape(v:val, "\\")'), '\|')
  let chunks = []
  let pos = 0
  while 1
    let [m, start, end] = matchstrpos(a:text, pat, pos)
    if start < 0
      break
    endif
    let chunks += [[strpart(a:text, pos, start - pos), 'ClaudeResumePrompt'], [m, 'ClaudeResumeMatch']]
    let pos = end
  endwhile
  return filter(chunks + [[a:text[pos :], 'ClaudeResumePrompt']], '!empty(v:val[0])')
endfunction

function! s:OnSearchResults(needles, data)
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
        \ ] + s:MarkNeedles(f[4], a:needles)})
  let data = map(copy(fields), '#{id: v:val[0], cwd: v:val[1]}')
  " One list at a time (with its previews); it outlives its window so a session
  " can <C-o> back to it.
  for b in getbufinfo()
    if b.name =~# '\v(^|/)ClaudeResume$|^claude-preview://'
      exe 'bwipeout ' .. b.bufnr
    endif
  endfor
  let nr = qutil#CreateCustomQuickfix(lines, "ClaudeResume", function('s:OnResumeSession'))
  call qutil#SetLineData(nr, data)
  setlocal bufhidden=hide
  nnoremap <buffer> p <cmd>call <SID>PreviewSession()<CR>
endfunction

" Read the session under the cursor in place of the list; <C-o> comes back.
function! s:PreviewSession()
  let entry = qutil#GetLineData()
  call s:GraySession(entry.id)
  call init#OnJobOutput(['python3', s:script, '--show', entry.id],
        \ expand('<SID>') .. 'OnPreview', win_getid(), bufnr(), entry)
endfunction

" Gray out every row of session a:id in the list, so the search can move on.
function! s:GraySession(id)
  let list = bufnr('^ClaudeResume$')
  let data = getbufvar(list, 'qutil_line_data', [])
  let ns = nvim_create_namespace('ClaudeResumeSeen')
  for i in filter(range(len(data)), 'data[v:val].id ==# a:id')
    call nvim_buf_set_extmark(list, ns, i, 0,
          \ #{id: i + 1, end_row: i + 1, hl_group: 'ClaudeResumeSeen', priority: 5000})
  endfor
endfunction

function! s:OnPreview(win, list, entry, data)
  " Moved on while python read it: leave the window be.
  if winbufnr(a:win) != a:list
    return
  endif
  if empty(join(a:data, ''))
    return init#Warn("ClaudeResume: session %s has nothing to show", a:entry.id)
  endif
  " Hidden, not wiped, so <C-i> can come back to it.
  let name = 'claude-preview://' .. a:entry.id
  let nr = bufexists(name) ? bufnr(name) : init#CreateCustomBuffer(name, a:data)
  call setbufvar(nr, '&bufhidden', 'hide')
  call win_gotoid(a:win)
  exe 'buffer ' .. nr
  setlocal wrap linebreak
  syntax match ClaudeResumePrompt /^❯.*/
  " Where it left off says most about which session it was.
  keepjumps normal! G
  let b:claude_entry = a:entry
  nnoremap <buffer> <CR> <cmd>call <SID>ResumeSession(b:claude_entry)<CR>
  call s:MapPromptJumps()
endfunction

function! s:OnResumeSession()
  call s:ResumeSession(qutil#GetLineData())
endfunction

function! s:ResumeSession(entry)
  let entry = a:entry
  let id = entry.id
  call s:GraySession(id)
  " Resume is scoped to a project dir, so it must run in the session's own cwd.
  let cwd = entry.cwd
  if empty(cwd) || !isdirectory(cwd)
    call init#Warn("ClaudeResume: session %s has no usable cwd (%s)", id, cwd)
    return
  endif

  " In the list's own window: its jumplist is how <C-o> gets back here.
  call s:OpenClaudeTerm(["--resume", id], cwd, #{new_window: v:false})
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
  return get(b:, 'claude_cost_statusline', '')
endfunction

" Cost and model, padded out to the window's middle past what the limits took.
function! claude#Middle()
  let text = trim(claude#Cost() .. ' ' .. get(b:, 'claude_model', ''))
  " Only the visible text counts: drop highlight groups, unescape %%.
  let left = substitute(claude#Limits(), '%#[^#]*#\|%\*', '', 'g')
  let left = strdisplaywidth(substitute(left, '%%', '%', 'g'))
  let mid = (winwidth(get(g:, 'statusline_winid', 0)) - strdisplaywidth(text)) / 2
  return repeat(' ', max([1, mid - left])) .. text
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
  " Until the first reply lands there is nothing to show: look again soon.
  let interval = exists('b:claude_cost_statusline') ? s:limit_interval : 5
  if localtime() - get(b:, 'claude_cost_at', 0) < interval
    return
  endif
  let b:claude_cost_at = localtime()
  let cmd = [s:cc_usage, '-c', b:root_dir, '--session-id', b:claude_session_id]
  call init#OnJobOutput(cmd, expand('<SID>') .. 'OnCost', bufnr())
endfunction

" Claude moved session a:bufnr to session a:id (see claude-session-hook): drop
" the old one's figures and look the new one up.
function! claude#SetSession(bufnr, id)
  if getbufvar(a:bufnr, 'claude_session_id') ==# a:id
    return
  endif
  call setbufvar(a:bufnr, 'claude_session_id', a:id)
  call s:RunIn(a:bufnr, 'unlet! b:claude_cost_statusline b:claude_cost_at b:claude_model'
        \ .. ' | call ' .. expand('<SID>') .. 'CheckCost()')
  redrawstatus!
endfunction

function! s:OnCost(bufnr, data)
  let [cost, model, at] = split(get(a:data, 0, '') .. "\t\t", "\t", v:true)[:2]
  if empty(cost)
    return
  endif
  call setbufvar(a:bufnr, 'claude_cost_statusline', printf(' [$%s]', cost))
  " A reply from before :ClaudeModel still has the old model.
  if str2nr(at) >= getbufvar(a:bufnr, 'claude_model_at', 0)
    call setbufvar(a:bufnr, 'claude_model', substitute(model, '^claude-', '', ''))
  endif
  redrawstatus!
endfunction

function! s:OnLimits(data)
  " Rows of `name<TAB>percent<TAB>resets`, tightest first; none means no data.
  let rows = map(filter(copy(a:data), '!empty(v:val)'), 'split(v:val, "\t", v:true)')
  call filter(rows, 'len(v:val) >= 3')
  if empty(rows)
    return
  endif
  let s:limits_sl = join(map(rows, 's:LimitItem(v:val[0], str2nr(v:val[1]), v:val[2])'), ' ')
  redrawstatus!
endfunction

" One window, e.g. `[week 85%, Fri 10:00]`, in its own color.
function! s:LimitItem(name, pct, resets)
  let hl = a:pct >= g:claude_limit_red ? 'ErrorMsg'
        \ : a:pct >= g:claude_limit_yellow ? 'WarningMsg' : 'MoreMsg'
  let text = printf('[%s %d%%', a:name, a:pct)
  " The reset time only matters once a window is tight enough to wait on.
  if a:pct >= g:claude_limit_yellow && !empty(a:resets)
    let text ..= ', ' .. a:resets
  endif
  let text ..= ']'
  " In a statusline a % is an escape; ours are literal text.
  return '%#' .. hl .. '#' .. substitute(text, '%', '%%', 'g') .. '%*'
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

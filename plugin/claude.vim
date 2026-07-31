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

" Open a claude terminal in a bottom split, wired for <CR> to open diff refs.
function! s:OpenClaudeTerm(args, root)
  let coding_win = win_getid()
  below sp
  enew
  call init#Termopen([g:claude_executable] + a:args, #{cwd: a:root})
  let b:root_dir = a:root
  let b:coding_win = coding_win
  nnoremap <buffer> <CR> <cmd>call <SID>ClaudeOpenRef()<CR>
  startinsert
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
    return init#Warn("ClaudeOpen: no line number on this line")
  endif
  " Code on this line (minus gutter number and diff marker) to verify the jump.
  let text = trim(substitute(raw, '\v^\s*\d+\s*[-+]?', '', ''))
  let path = ""
  for i in range(line('.'), 1, -1)
    let m = matchlist(getline(i), '\v^\s*●\s+%(Update|Edit|MultiEdit|Write|Create|Read)\((.{-})\)')
    if !empty(m)
      let path = m[1]
      break
    endif
  endfor
  if empty(path)
    return init#Warn("ClaudeOpen: no file header found")
  endif
  let path = expand(path)  " resolve a leading ~
  let fullname = path[0] == '/' ? path : b:root_dir .. '/' .. path
  if !filereadable(fullname)
    return init#Warn("ClaudeOpen: no such file: %s", fullname)
  endif

  " Return to the coding window we opened from; recreate it if it's gone.
  if !win_gotoid(get(b:, 'coding_win', 0))
    let claude_buf = bufnr()
    above sp
    call setbufvar(claude_buf, 'coding_win', win_getid())
  endif
  exe 'edit ' .. fnameescape(fullname)
  let lnum = s:FindSourceLine(lnum, text)
  exe 'normal ' .. lnum .. 'G'
  normal z.
endfunction

""""""""""""""""""""""""""""Claude interactive"""""""""""""""""""""""""""" {{{
function! s:ClaudeInteractive(args) range
  let root = FugitiveWorkTree()
  if empty(root)
    let root = getcwd()
  endif
  let filename = expand('%:p')

  if empty(a:args)
    let prompt = []
  elseif filereadable(filename)
    let marker = ""
    if stridx(filename, root) == 0
      let filename = filename[len(root):]
      if filename[0] == '/'
        let filename = filename[1:]
      endif
      let marker = "@"
    endif
    let whole_file = a:firstline == 1 && a:lastline == line('$')
    if whole_file
      let prompt = [printf('In %s%s: %s', marker, filename, a:args)]
    else
      let prompt = [printf('In %s%s lines %d-%d: %s', marker, filename, a:firstline, a:lastline, a:args)]
    endif
  else
    let context = join(getline(a:firstline, a:lastline), "\n")
    let prompt = [printf("%s\n%s", a:args, context)]
  endif

  call s:OpenClaudeTerm(prompt, root)
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

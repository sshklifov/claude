" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists(':Claude')
  finish
endif

let g:claude_executable = expand("~/.local/bin/claude")

""""""""""""""""""""""""""""Claude interactive"""""""""""""""""""""""""""" {{{
function! s:ClaudeInteractive(args) range
  let root = FugitiveWorkTree()
  if empty(root)
    let root = getcwd()
  endif
  let filename = expand('%:p')

  if empty(a:args)
    let prompt = '--resume'
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
      let prompt = printf('In %s%s: %s', marker, filename, a:args)
    else
      let prompt = printf('In %s%s lines %d-%d: %s', marker, filename, a:firstline, a:lastline, a:args)
    endif
  else
    let context = join(getline(a:firstline, a:lastline), "\n")
    let prompt = printf("%s\n%s", a:args, context)
  endif

  below sp
  enew
  call init#Termopen([g:claude_executable, prompt], #{cwd: root})
  startinsert
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
  below sp
  enew
  call init#Termopen([g:claude_executable, "--resume", id], #{cwd: cwd})
  startinsert
endfunction

command! -bang -nargs=* ClaudeResume call s:ClaudeResume("<bang>", <f-args>)
" }}}

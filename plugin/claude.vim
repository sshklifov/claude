" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists(':Claude')
  finish
endif

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
  call init#Termopen(["claude", prompt], #{cwd: root})
  startinsert
endfunction

command! -nargs=* -range=% Claude <line1>,<line2>call s:ClaudeInteractive(<q-args>)
" }}}

""""""""""""""""""""""""""""Claude history search"""""""""""""""""""""""""""" {{{
let s:script = expand('<sfile>:p:h:h') .. '/csearch.py'

function! s:Fmt(f) abort
  " f = [sid, cwd, ts, role, snippet]
  return printf('%s  %-30s [%s] %s', a:f[2], a:f[1], a:f[3], a:f[4])
endfunction

function! s:Resume() abort
  let ids = getbufvar(bufnr(), 'csearch_ids', [])
  let cwds = getbufvar(bufnr(), 'csearch_cwds', [])
  let idx = line('.') - 1
  if idx < 0 || idx >= len(ids)
    return
  endif
  let id = ids[idx]
  " Resume is scoped to a project dir, so it must run in the session's own cwd.
  let cwd = get(cwds, idx, '')
  if empty(cwd) || !isdirectory(cwd)
    call init#Warn("Csearch: session %s has no usable cwd (%s)", id, cwd)
    return
  endif
  quit
  below sp
  enew
  call init#Termopen(["claude", "--resume", id], #{cwd: cwd})
  startinsert
endfunction

function! s:Collect(_0, data, _1) abort
  let rows = filter(copy(a:data), '!empty(v:val)')
  if empty(rows)
    echo "Csearch: no matches"
    return
  endif
  let fields = map(copy(rows), 'split(v:val, "\t", v:true)')
  let fields = filter(fields, 'len(v:val) >= 5')
  let lines = map(copy(fields), 's:Fmt(v:val)')
  let ids = map(copy(fields), 'v:val[0]')
  let cwds = map(copy(fields), 'v:val[1]')
  let nr = qutil#CreateCustomQuickfix(lines, "Csearch", function('s:Resume'))
  if nr >= 0
    call setbufvar(nr, 'csearch_ids', ids)
    call setbufvar(nr, 'csearch_cwds', cwds)
  endif
endfunction

function! s:Csearch(...) abort
  if a:0 == 0
    call init#Warn("Csearch: need at least one substring")
    return
  endif
  let cmd = ['python3', s:script, '--nvim'] + a:000
  call init#Jobstart(cmd, #{stdout_buffered: 1, on_stdout: function('s:Collect')})
endfunction

command! -nargs=+ Csearch call s:Csearch(<f-args>)
" }}}

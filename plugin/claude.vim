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
" :Csearch FooBar rockchip   — substring-search across all session history.
" All args are ANDed (a message must contain every substring). <CR> on a
" result resumes that session in a terminal.
let s:script = expand('~/.claude/csearch.py')

" What <CR> does with the selected session id. Change to taste:
"   resume  — open `claude --resume <id>` in a terminal split (default)
"   edit    — open the raw .jsonl for that session
"   yank    — copy `claude --resume <id>` to the unnamed register
let g:csearch_action = get(g:, 'csearch_action', 'resume')

function! s:Fmt(f) abort
  " f = [sid, cwd, ts, role, snippet]
  return printf('%s  %-30s [%s] %s', a:f[2], a:f[1], a:f[3], a:f[4])
endfunction

function! s:Resume() abort
  let ids = getbufvar(bufnr(), 'csearch_ids', [])
  let idx = line('.') - 1
  if idx < 0 || idx >= len(ids)
    return
  endif
  let id = ids[idx]
  quit
  if g:csearch_action ==# 'yank'
    let cmd = 'claude --resume ' .. id
    call setreg('"', cmd)
    echo 'Yanked: ' .. cmd
  elseif g:csearch_action ==# 'edit'
    let root = expand('~/.claude/projects')
    let matches = globpath(root, '*/' .. id .. '.jsonl', v:false, v:true)
    if empty(matches)
      call init#Warn("No .jsonl found for session %s", id)
      return
    endif
    exe 'edit ' .. fnameescape(matches[0])
  else
    below sp
    enew
    call init#Termopen(["claude", "--resume", id], #{cwd: getcwd()})
    startinsert
  endif
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
  let nr = qutil#CreateCustomQuickfix(lines, "Csearch", function('s:Resume'))
  if nr >= 0
    call setbufvar(nr, 'csearch_ids', ids)
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

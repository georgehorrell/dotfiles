" BASIC SETUP:

" enter the current millenium
set nocompatible

" enable syntax and plugins (for netrw)
syntax enable
filetype plugin on

" Enable insert backspace through everything
set backspace=indent,eol,start

" Enable autoindent
set autoindent

" FINDING FILES:

" Search down into subfolders
" Provides tab-completion for all file-related tasks
set path+=**

" Display all matching files when we tab complete
set wildmenu

" NOW WE CAN:
" - Hit tab to :find by partial match
" - Use * to make it fuzzy

" THINGS TO CONSIDER:
" - :b lets you autocomplete any open buffer


" TAG JUMPING:

" Create the `tags` file (may need to install ctags first)
command! MakeTags !ctags -R .

" NOW WE CAN:
" - Use ^] to jump to tag under cursor
" - Use g^] for ambiguous tags
" - Use ^t to jump back up the tag stack

" THINGS TO CONSIDER:
" - This doesn't help if you want a visual list of tags


" AUTOCOMPLETE:

" The good stuff is documented in |ins-completion|

" HIGHLIGHTS:
" - ^x^n for JUST this file
" - ^x^f for filenames (works with our path trick!)
" - ^x^] for tags only
" - ^n for anything specified by the 'complete' option

" NOW WE CAN:
" - Use ^n and ^p to go back and forth in the suggestion list


" FILE BROWSING:

" Tweaks for browsing
let g:netrw_banner=0        " disable annoying banner
let g:netrw_browse_split=4  " open in prior window
let g:netrw_altv=1          " open splits to the right
let g:netrw_liststyle=3     " tree view

" NOW WE CAN:
" - :edit a folder to open a file browser
" - <CR>/v/t to open in an h-split/v-split/tab
" - check |netrw-browse-maps| for more mappings


" SNIPPETS:

" Read an empty HTML template and move cursor to title
nnoremap ,html :-1read $HOME/.vim/.skeleton.html<CR>3jwf>a

" NOW WE CAN:
" - Take over the world!
"   (with much fewer keystrokes)


" BUILD INTEGRATION:

" Steal Mr. Bradley's formatter & add it to our spec_helper
" http://philipbradley.net/rspec-into-vim-with-quickfix

" Configure the `make` command to run RSpec
" set makeprg=bundle\ exec\ rspec\ -f\ QuickfixFormatter

" NOW WE CAN:
" - Run :make to run RSpec
" - :cl to list errors
" - :cc# to jump to error by number
" - :cn and :cp to navigate forward and back

" github.com/mcantor/no_plugins


" STATUS LINE:
" Stolen from https://shapeshed.com/vim-statuslines/

set statusline=
set statusline+=%#CursorIM#%{(mode()=='n')?'\ \ NORMAL\ ':''}
set statusline+=%#DiffChange#%{(mode()=='i')?'\ \ INSERT\ ':''}
set statusline+=%#DiffDelete#%{(mode()=='r')?'\ \ RPLACE\ ':''}
set statusline+=%#Cursor#%{(mode()=='v')?'\ \ VISUAL\ ':''}
set statusline+=\ %n\                         " buffer number
set statusline+=%#Visual#                     " colour
set statusline+=%{&paste?'\ PASTE\ ':''}
set statusline+=%{&spell?'\ SPELL\ ':''}
set statusline+=%#CursorIM#                   " colour
set statusline+=%R                            " readonly flag
set statusline+=%M                            " modified [+] flag
set statusline+=%#Cursor#                     " colour
set statusline+=%#CursorLine#                 " colour
set statusline+=\ %t\                         " short file name
set statusline+=%=                            " right align
set statusline+=%#CursorLine#                 " colour
set statusline+=\ %Y\                         " file type
set statusline+=%#CursorIM#                   " colour
set statusline+=\ %3l:%-2c\                   " line + column
set statusline+=%#Cursor#                     " colour
set statusline+=\ %3p%%\                      " percentage

set laststatus=2

" COLORSCHEME AND DISPLAY:
" Stolen from https://stackoverflow.com/questions/7278267/incorrect-colors-with-vim-in-iterm2-using-solarized
set background=dark
let g:solarized_visibility = "high"
let g:solarized_contrast = "high"
colorscheme solarized

" filetype specific configuration
"" markdown
command! OpenBrowser :silent ! open -a "Google Chrome" "file://%:p"

" for MacVim, set the GUI font
set gfn=SourceCodeProRoman-Regular:h14

function! FormatCurl()
  let l:line = getline('.')

  " Extract and format JSON payload from single-quoted -d argument
  if l:line =~# '\v(-d|--data|--data-raw)[= ]''\{.*}'''
    let l:json_raw = matchstr(l:line, '\v(-d|--data|--data-raw)[= ]''\zs{.*}\ze''')
    let l:pretty_json = system('jq .', l:json_raw)

    " Escape internal single quotes if any (JSON typically doesn't use them)
    let l:pretty_json = substitute(l:pretty_json, '''', '''\\''''', 'g')
    let l:pretty_json_lines = split(l:pretty_json, '\n')

    " Add \n between lines for literal shell string, re-wrap in single quotes
    let l:json_final = "'". join(map(l:pretty_json_lines, {idx, val -> (idx == 0 ? val : "\\n" . val)}), '') . "'"

    " Replace original JSON string in the line
    let l:line = substitute(l:line, '\v(-d|--data|--data-raw)[= ]''{.*}''', '\1 ' . l:json_final, '')
  endif

  " Split options so each begins on a new line, with 2-space indent and \
  let l:parts = split(l:line, '\s\+\zs-(?=-|[A-Za-z])')
  for i in range(len(l:parts))
    if i == 0
      let l:parts[i] = l:parts[i]
    else
      let l:parts[i] = '  \\' . "\r  -" . l:parts[i]
    endif
  endfor

  call setline('.', join(l:parts, ' '))
endfunction

command! FormatCurl call FormatCurl()

source "${HOME}/.git_prompt.sh"
source "${HOME}/.iterm2_shell_integration.zsh"
source "${HOME}/.z.sh"

# source custom file if it exists
test -f "${HOME}/.custom.zshrc" && source "${HOME}/.custom.zshrc"

# configure zsh prompt
export GIT_PS1_SHOWDIRTYSTATE='true'
setopt PROMPT_SUBST ; PS1='%F{cyan}[%*]%f %F{magenta}%n%f %F{yellow}::%f %F{magenta}%m%f %F{blue}%~%f%F{red}$(__git_ps1 " (%s)")%f %F{yellow}\$%f '

# configure zsh history
export HISTFILESIZE=1000000000
export HISTSIZE=1000000000
export HISTFILE=~/.zsh_history

setopt HIST_FIND_NO_DUPS
setopt INC_APPEND_HISTORY

# source aliases
source "${HOME}/.aliases/git"
source "${HOME}/.aliases/misc"

# vi-mode on zsh
bindkey -v

vi-search-fix() {
  zle vi-cmd-mode
  zle .vi-history-search-backward
}

autoload vi-search-fix
zle -N vi-search-fix
bindkey -M viins '\e/' vi-search-fix

# Beginning search with arrow keys
autoload -U up-line-or-beginning-search
autoload -U down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey "^[OA" up-line-or-beginning-search
bindkey "^[OB" down-line-or-beginning-search
bindkey -M vicmd "k" up-line-or-beginning-search
bindkey -M vicmd "j" down-line-or-beginning-search

# Jump to end of line when running history complete
autoload -U history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "^[[A" history-beginning-search-backward-end
bindkey "^[[B" history-beginning-search-forward-end

# enable git tab completion
autoload -Uz compinit && compinit -i

# ensure menu and select
zstyle ':completion:*' menu select
zstyle ':completion:*' completer _expand_alias _complete _ignored
zstyle ':completion:*' regular true

# Make Vi mode transitions faster (KEYTIMEOUT is in hundredths of a second)
export KEYTIMEOUT=1

# Enable scrolling in less file reader.
export LESS=-R

function ops-today() {
  DATE=$(date +%y%m%d)
  mkdir -p $HOME/ops/$DATE
  cd $HOME/ops/$DATE
}

# Copy the last command run to clipboard.
function lc() {
  history | tail -1 | head -1 | cut -c8-999 | pbcopy
}

# Copy the file to ~/bin
function binit() {
  cp $1 ~/bin/
}

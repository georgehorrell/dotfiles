source "${HOME}/.git_prompt.sh"
source "${HOME}/.iterm2_shell_integration.zsh"

# source custom file if it exists
test -f "${HOME}/.custom.zshrc" && source "${HOME}/.custom.zshrc"

# configure zsh prompt
export GIT_PS1_SHOWDIRTYSTATE='true'
setopt PROMPT_SUBST ; PS1='%F{cyan}[%*]%f %F{magenta}%n%f %F{yellow}::%f %F{magenta}%m%f %F{blue}%~%f%F{red}$(__git_ps1 " (%s)")%f %F{yellow}\$%f '

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

# Make Vi mode transitions faster (KEYTIMEOUT is in hundredths of a second)
export KEYTIMEOUT=1

function ops-today() {
  DATE=$(date +%y%m%d)
  mkdir -p ~/ops/$DATE
  cd ~/ops/$DATE
}


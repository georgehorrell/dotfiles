source "${HOME}/.git_prompt.sh"
source "${HOME}/.iterm2_shell_integration.zsh"
source "${HOME}/.z.sh"

export PATH="${PATH}:${HOME}/bin:${HOME}/.bin"

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
setopt correct

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
autoload -Uz compinit 
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
	compinit;
else
	compinit -C;
fi;

# ensure menu and select
zstyle ':completion:*' menu select
zstyle ':completion:*' completer _expand_alias _complete _ignored
zstyle ':completion:*' regular true

# edit current command in vim
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Make Vi mode transitions faster (KEYTIMEOUT is in hundredths of a second)
export KEYTIMEOUT=1

# Enable scrolling in less file reader.
export LESS=-XFRS

ops() {
    command_output=$(~/.ops.py "$@")
    if [[ $command_output == cd* ]]; then
        eval $command_output
    else
        echo $command_output
    fi
}

function ops-today() {
    ops today
}

# get the main branch
function git_main_branch() {
  def=`git remote show origin | sed -n '/HEAD branch/s/.*: //p'`
  echo $def
}

# Copy the last command run to clipboard.
function lc() {
  history | tail -1 | head -1 | cut -c8-999 | pbcopy
}

# Copy the file to ~/bin
function binit() {
  cp $1 ~/bin/
}

function rgv() {
  vim -q <(rg --vimgrep $1)
}

function fbr() {
  BRANCH_NAME="$(git branch --sort=-committerdate | grep -v 'stale--' | fzf --no-sort)"
  if [ $? -eq 0 ]; then
    git checkout "$(echo $BRANCH_NAME | tr -d '[:space:]')"
  fi
}

function fbra() {
  BRANCH_NAME="$(git branch --all --sort=-committerdate | fzf --no-sort)"
  if [ $? -eq 0 ]; then
    git checkout "$(echo $BRANCH_NAME | tr -d '[:space:]')"
  fi
}

function gbstale() {
    local branch="${1:-$(git branch --show-current)}"
    if [[ $branch == stale--* ]]; then
        git branch -m "${branch}" "${branch#stale--}"
    else
        git branch -m "${branch}" "stale--${branch}"
    fi
}

# Path to the file where the timestamp and decision are stored
SOD_TIMESTAMP_FILE="$HOME/.sod_last_run"

# This flag will help us determine if the terminal was just opened
FIRST_LOAD=1

prompt_sod() {
    echo -n "Start of day setup has not been run in the last 10 hours. Run now? [Y/n] "

    read REPLY
    REPLY=${REPLY:-Y}

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        sod # Call your 'sod' function or command
        echo "$(date +%s) run" > "$SOD_TIMESTAMP_FILE"
    else
        echo "$(date +%s) declined" > "$SOD_TIMESTAMP_FILE"
    fi
}

check_sod() {
    # Skip the first check when the terminal is opened
    if [[ $FIRST_LOAD -eq 1 ]]; then
        FIRST_LOAD=0
        return
    fi

    local last_run last_decision
    if [[ -f "$SOD_TIMESTAMP_FILE" ]]; then
        read last_run last_decision < "$SOD_TIMESTAMP_FILE"
        local current_time=$(date +%s)
        local diff=$((current_time - last_run))

        if [[ "$last_decision" == "declined" && $diff -lt 36000 ]]; then
            return # No action if declined within 12 hours
        elif [[ "$last_decision" == "run" && $diff -lt 36000 ]]; then
            return # No action if run within 12 hours
        fi
    fi
    prompt_sod
}

cache_command() {
    local cache_dir=~/.cache/command_cache
    local cache_file="$cache_dir/$(echo -n "$1" | md5)"
    local expiration_time=$2  # Expiration time in seconds

    # Check if cache file exists and is not expired
    if [[ -f "$cache_file" && $(($(date +%s) - $(stat -f %m "$cache_file"))) -lt $expiration_time ]]; then
        cat "$cache_file"
    else
        # Execute the command and cache its output
        eval "$1" | tee "$cache_file"
    fi
}

# For zsh, use the precmd hook
autoload -U add-zsh-hook
add-zsh-hook precmd check_sod

if command -v atuin &> /dev/null
then
  eval "$(atuin init zsh)"
fi

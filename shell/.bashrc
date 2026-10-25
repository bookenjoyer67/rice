
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

[ -s "$HOME/.config/envman/load.sh" ] && source "$HOME/.config/envman/load.sh"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
[ -d /usr/lib/jvm/java-26-openjdk ] && export JAVA_HOME=/usr/lib/jvm/java-26-openjdk

[ -f "$HOME/.terminal-juice-aliases" ] && source "$HOME/.terminal-juice-aliases"
alias sybau='sudo pacman -Syu'

command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"

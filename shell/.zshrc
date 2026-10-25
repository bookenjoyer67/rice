[ -f /usr/share/cachyos-zsh-config/cachyos-config.zsh ] && source /usr/share/cachyos-zsh-config/cachyos-config.zsh

[ -s "$HOME/.config/envman/load.sh" ] && source "$HOME/.config/envman/load.sh"

export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
[ -f "$HOME/.terminal-juice-aliases" ] && source "$HOME/.terminal-juice-aliases"

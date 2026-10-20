[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

# Login greeting: fastfetch, when installed (config: ~/.config/fastfetch).
if [ -n "$PS1" ] && command -v fastfetch >/dev/null 2>&1; then fastfetch; fi

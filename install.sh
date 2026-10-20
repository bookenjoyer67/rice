#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# niri / Noctalia rice — installer
#
# Symlinks every package in this repo into $HOME (no stow required). Any file
# or directory it would overwrite is moved aside to <name>.bak-<timestamp>
# first, so nothing is ever destroyed.
#
#   ./install.sh                 link configs into $HOME
#   ./install.sh --dry-run       show what would happen, touch nothing
#   ./install.sh --build-shim    also compile noctalia-layer-swap.so
#   ./install.sh --with-system   also install /etc/greetd/config.toml (sudo)
# ---------------------------------------------------------------------------
set -euo pipefail
shopt -s nullglob

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
DRY=0; SYSTEM=0; SHIM=0

usage() {
  cat <<'EOF'
niri / Noctalia rice — installer

Symlinks every package in this repo into $HOME (no stow required). Any file
or directory it would overwrite is moved aside to <name>.bak-<timestamp>
first, so nothing is ever destroyed.

  ./install.sh                 link configs into $HOME
  ./install.sh --dry-run       show what would happen, touch nothing
  ./install.sh --build-shim    also compile and install noctalia-layer-swap.so
  ./install.sh --with-system   also install /etc/greetd/config.toml (needs sudo)

Packages are directories in the repo that contain .config/, .local/,
.screenlayout/ or a dotfile.
EOF
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)   DRY=1 ;;
    --build-shim)   SHIM=1 ;;
    --with-system)  SYSTEM=1 ;;
    -h|--help)      usage ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  would: $*"; else "$@"; fi; }

# link_obj <src> <dest> — idempotent symlink with backup of anything in the way
link_obj() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    if [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
      say "  ok        ${dest/#$HOME/\~}"
      return 0
    fi
    run rm -f "$dest"
  elif [ -e "$dest" ]; then
    say "  backup    ${dest/#$HOME/\~} -> .bak-$TS"
    run mv "$dest" "$dest.bak-$TS"
  fi
  run mkdir -p "$(dirname "$dest")"
  run ln -s "$src" "$dest"
  say "  link      ${dest/#$HOME/\~}"
}

# Mirror a package into $HOME. Shared platform directories are recursed into;
# everything else is owned wholesale by the package (backed up, then linked),
# so two packages can never fight over ~/.local/bin or ~/.config/hypr.
is_container() {
  case "$1" in
    "$HOME"|"$HOME/.config"|"$HOME/.local"|"$HOME/.local/bin"|\
    "$HOME/.local/src"|"$HOME/.local/share") return 0 ;;
    *) return 1 ;;
  esac
}

_mirror() {
  local src="$1" destroot="$2" entry base dest
  for entry in "$src"/* "$src"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
      *.bak|*.bak-*|*.bak.*|*.old|.backup-*|*~) continue ;;
    esac
    dest="$destroot/$base"
    if [ -d "$entry" ] && [ ! -L "$entry" ] && is_container "$dest"; then
      _mirror "$entry" "$dest"
    else
      link_obj "$entry" "$dest"
    fi
  done
}

link_pkg() { _mirror "$1" "$HOME"; }

if [ "$DRY" -eq 1 ]; then say "DRY RUN — nothing will be changed"; fi

say ""
say "Linking packages into $HOME"
say ""
for dir in "$REPO"/*/; do
  pkg="$(basename "$dir")"
  case "$pkg" in
    system|screenshots|assets|yambar|eww|wofi) continue ;;
  esac
  # only packages that actually contain dotfiles
  if [ -d "$dir/.config" ] || [ -d "$dir/.local" ] || [ -d "$dir/.screenlayout" ] \
     || [ -e "$dir/.zshrc" ]; then
    say "$pkg"
    link_pkg "${dir%/}"
  fi
done

# --- the LD_PRELOAD shim ---------------------------------------------------
say ""
if [ "$SHIM" -eq 1 ]; then
  say "Building noctalia-layer-swap.so"
  if [ "$DRY" -eq 1 ]; then
    say "  would: make -C $REPO/layer-swap/.local/src/noctalia-layer-swap"
    say "  -> installs \$HOME/.local/lib/noctalia-layer-swap.so (the Makefile's target)"
  else
    # the Makefile's target IS $HOME/.local/lib/noctalia-layer-swap.so — no copy needed
    make -C "$REPO/layer-swap/.local/src/noctalia-layer-swap"
    if [ -f "$HOME/.local/lib/noctalia-layer-swap.so" ]; then
      say "  installed ~/.local/lib/noctalia-layer-swap.so"
    else
      echo "  ERROR: shim did not land in ~/.local/lib" >&2
      exit 1
    fi
  fi
else
  say "Shim not built (pass --build-shim). niri skips LD_PRELOAD cleanly if it is missing,"
  say "but desktop widgets will zoom with the workspace in the overview."
fi

# --- system greeter config -------------------------------------------------
if [ "$SYSTEM" -eq 1 ]; then
  say ""
  say "Installing /etc/greetd/config.toml (sudo)"
  run sudo install -m 644 "$REPO/system/greetd/config.toml" /etc/greetd/config.toml
  say "  The session launched by the greeter is set by --cmd in that file."
  say "  Enable the greeter:  sudo systemctl enable --now greetd"
fi

say ""
say "Done. Next:"
say "  1. Log out and back in — or reload in place:  niri msg action load-config-file"
say "  2. Runtime deps:  niri noctalia matugen awww tuigreet kitty cliphist"
say "                    wl-clipboard grim slurp swaylock brightnessctl wlsunset"
say "  3. Optional:  swaylock + the lock scripts need ~/.local/bin on \$PATH."

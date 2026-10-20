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
DRY=0; SYSTEM=0; SHIM=1; DEPS=1

usage() {
  cat <<'EOF'
niri / Noctalia rice — installer

Symlinks every package in this repo into $HOME (no stow required). Any file
or directory it would overwrite is moved aside to <name>.bak-<timestamp>
first, so nothing is ever destroyed.

  ./install.sh                 packages, configs, Noctalia state, shim
  ./install.sh --dry-run       show what would happen, touch nothing
  ./install.sh --no-deps       do not install packages (configs only)
  ./install.sh --no-shim       skip compiling noctalia-layer-swap.so
  ./install.sh --with-system   also install /etc/greetd/config.toml (needs sudo)

Package lists: packages.txt (official repos) and aur-packages.txt (brave-bin,
via paru/yay, else makepkg).

Packages are directories in the repo that contain .config/, .local/,
.screenlayout/ or a dotfile.
EOF
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)   DRY=1 ;;
    --build-shim)   SHIM=1 ;;
    --no-shim)      SHIM=0 ;;
    --no-deps)      DEPS=0 ;;
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
    "$HOME/.local/src"|"$HOME/.local/share"|"$HOME/.config/systemd"|\
    "$HOME/.config/systemd/user"|"$HOME/.config/environment.d") return 0 ;;
    *) return 1 ;;
  esac
}

_mirror() {
  local src="$1" destroot="$2" entry base dest
  for entry in "$src"/* "$src"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
      *.bak|*.bak-*|*.bak.*|*.old|.backup-*|*~|__pycache__|.git|.DS_Store|*.pyc) continue ;;
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

# --- packages --------------------------------------------------------------
# Everything the configs spawn. Guarded by `pacman -Q`, so rerunning on a
# configured machine is a no-op instead of a 40-package reinstall prompt.
pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }

# AUR builds need makepkg. A minimal Arch install has neither an AUR helper nor
# base-devel, so pull the toolchain in rather than skipping the one package the
# rice actually needs from the AUR.
ensure_build_tools() {
  # `makepkg` ships with pacman itself, so it is not a marker for base-devel.
  # fakeroot + debugedit are: makepkg refuses to build without them.
  command -v paru >/dev/null 2>&1 && return 0
  command -v yay >/dev/null 2>&1 && return 0
  if command -v fakeroot >/dev/null 2>&1 && command -v debugedit >/dev/null 2>&1; then
    return 0
  fi
  say "  install   base-devel (needed to build AUR packages)"
  sudo pacman -S --needed --noconfirm base-devel >/dev/null || return 1
}

aur_install() {
  local pkg="$1" tmp runner=()
  if command -v paru >/dev/null 2>&1; then
    paru -S --needed --noconfirm "$pkg" && return 0
  elif command -v yay >/dev/null 2>&1; then
    yay -S --needed --noconfirm "$pkg" && return 0
  fi
  if ! command -v makepkg >/dev/null 2>&1; then
    say "  SKIP      $pkg: no AUR helper and no makepkg (pacman -S base-devel)"
    return 1
  fi
  if [ "$EUID" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ]; then
      runner=(sudo -u "$SUDO_USER")
    else
      say "  SKIP      $pkg: makepkg refuses to run as root; rerun install.sh as your user"
      return 1
    fi
  fi
  tmp="$(mktemp -d)"
  if ! git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$tmp/$pkg" >/dev/null 2>&1; then
    say "  FAIL      $pkg: git clone failed"
    rm -r "$tmp"
    return 1
  fi
  if ! ( cd "$tmp/$pkg" && "${runner[@]}" makepkg -si --noconfirm ); then
    say "  FAIL      $pkg: makepkg failed"
    rm -r "$tmp"
    return 1
  fi
  rm -r "$tmp"
}

if [ "$DEPS" -eq 1 ]; then
  say ""
  say "Packages"
  if ! command -v pacman >/dev/null 2>&1; then
    say "  SKIP      not an Arch system (no pacman)"
  else
    mapfile -t WANT < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO/packages.txt")
    MISSING=()
    for p in "${WANT[@]}"; do pkg_installed "$p" || MISSING+=("$p"); done
    if [ "${#MISSING[@]}" -eq 0 ]; then
      say "  ok        all ${#WANT[@]} repo packages present"
    elif [ "$DRY" -eq 1 ]; then
      say "  would: pacman -S --needed ${MISSING[*]}"
    else
      # A fresh install boots with an empty sync database: `pacman -S` then fails
      # with "package not found" even though the package exists. Refresh first.
      if ! pacman -Si "${MISSING[0]}" >/dev/null 2>&1; then
        say "  refresh   pacman -Sy (empty sync database)"
        sudo pacman -Sy --noconfirm >/dev/null || say "  WARN      pacman -Sy failed"
      fi
      say "  install   ${#MISSING[@]} package(s)"
      sudo pacman -S --needed --noconfirm "${MISSING[@]}" || \
        say "  WARN      pacman returned non-zero — check the list above"
    fi

    if [ -f "$REPO/aur-packages.txt" ]; then
      mapfile -t AWANT < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO/aur-packages.txt")
      if [ "${#AWANT[@]}" -gt 0 ] && [ "$DRY" -eq 0 ]; then
        ensure_build_tools || say "  WARN      no build toolchain — AUR packages will be skipped"
      fi
      for p in "${AWANT[@]}"; do
        if pkg_installed "$p"; then
          say "  ok        $p (AUR)"
        elif [ "$DRY" -eq 1 ]; then
          say "  would: build $p from the AUR"
        else
          say "  install   $p (AUR)"
          aur_install "$p" || say "  WARN      $p failed to build — install it later or rerun"
        fi
      done
    fi
  fi
fi

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

# --- editor plugins --------------------------------------------------------
# lazy.nvim bootstraps itself on first start, but that leaves the first real
# `nvim` session downloading plugins with an empty UI. Sync headlessly instead.
say ""
say "Neovim plugins"
if [ ! -e "$HOME/.config/nvim/init.lua" ]; then
  say "  skip      no ~/.config/nvim"
elif ! command -v nvim >/dev/null 2>&1; then
  say "  skip      nvim not installed"
elif [ "$DRY" -eq 1 ]; then
  say "  would: nvim --headless '+Lazy! sync' +qa"
else
  if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    say "  ok        lazy.nvim plugins synced"
  else
    say "  WARN      plugin sync failed (offline?) — run :Lazy sync inside nvim"
  fi
fi

# --- Brave Origin profile + theme ------------------------------------------
# Noctalia's community "brave" template writes into
# ~/.config/BraveSoftware/Brave-Browser (hardcoded upstream) while Brave Origin
# keeps its profile in Brave-Origin, and the theme it renders is an *unpacked*
# extension that upstream expects you to load by hand. brave-origin-theme.py
# handles both: relative symlink, then the Chromium unpacked-extension entry.
say ""
if [ -x "$HOME/.local/bin/brave-origin-theme.py" ]; then
  if [ "$DRY" -eq 1 ]; then
    "$HOME/.local/bin/brave-origin-theme.py" --check
  else
    "$HOME/.local/bin/brave-origin-theme.py"
  fi
else
  say "Brave origin theme helper not linked yet (run install.sh again after linking)"
fi

# --- Noctalia state ---------------------------------------------------------
# The shell's effective config lives in ~/.local/state/noctalia/settings.toml and
# loads AFTER ~/.config/noctalia/bar.toml. It is where plugin enablement, the
# desktop widgets, the lockscreen widgets and the theme/template choices actually
# live: without it a fresh install renders an empty bar with none of the rice's
# plugins loaded, no desktop cat/clock/weather and no lockscreen layout.
# Shipped as a template because it carries absolute paths (/home/computing).
STATE_SRC="$REPO/noctalia-state/settings.toml"
STATE_DST="$HOME/.local/state/noctalia/settings.toml"
say ""
say "Noctalia state"
if [ -f "$STATE_SRC" ]; then
  if pgrep -x noctalia >/dev/null 2>&1; then
    say "  SKIP      Noctalia is running: it rewrites settings.toml from memory when it"
    say "            exits, which wipes everything below. Log out, rerun ./install.sh,"
    say "            then log in again."
  elif [ "$DRY" -eq 1 ]; then
    say "  would: render settings.toml with $HOME substituted"
  else
    if [ -f "$STATE_DST" ]; then
      say "  backup    ~/.local/state/noctalia/settings.toml -> .bak-$TS"
      cp -f "$STATE_DST" "$STATE_DST.bak-$TS"
    fi
    mkdir -p "$(dirname "$STATE_DST")"
    sed "s|/home/computing|$HOME|g" "$STATE_SRC" > "$STATE_DST"
    say "  render    ~/.local/state/noctalia/settings.toml"
  fi
else
  say "  missing   noctalia-state/settings.toml"
fi

# --- cursor theme ----------------------------------------------------------
# 13 MB asset rather than 261 MB of loose cursor files. niri aborts cursor
# loading entirely when XCURSOR_THEME (session/environment.d) points at a theme
# that is not installed: the pointer disappears and the log reads
#   WARN niri::cursor: error loading xcursor default@24: no default icon
CURSOR_TAR="$REPO/cursors/Bibata-Rainbow-Modern.tar.zst"
CURSOR_DIR="$HOME/.icons/Bibata-Rainbow-Modern"
say ""
say "Cursor theme"
if [ -f "$CURSOR_TAR" ]; then
  if [ -f "$CURSOR_DIR/index.theme" ] && [ -e "$CURSOR_DIR/cursors/left_ptr" ]; then
    say "  ok        ~/.icons/Bibata-Rainbow-Modern"
  elif [ "$DRY" -eq 1 ]; then
    say "  would: tar -xf cursors/Bibata-Rainbow-Modern.tar.zst -C ~/.icons"
  elif ! command -v zstd >/dev/null 2>&1; then
    say "  SKIP      zstd not installed — cursor theme not extracted (pacman -S zstd)"
  else
    mkdir -p "$HOME/.icons"
    tar -xf "$CURSOR_TAR" -C "$HOME/.icons"
    say "  extract   ~/.icons/Bibata-Rainbow-Modern"
  fi
else
  say "  missing   cursors/Bibata-Rainbow-Modern.tar.zst"
fi

# --- user units that the session needs -------------------------------------
# Enabled with symlinks so this works without a live user manager. niri-session
# starts graphical-session.target; units outside that target never come up.
say ""
say "Session units"
for unit in awww-daemon.service lock-on-sleep.service; do
  if [ -f "$HOME/.config/systemd/user/$unit" ] || [ -L "$HOME/.config/systemd/user/$unit" ]; then
    run mkdir -p "$HOME/.config/systemd/user/graphical-session.target.wants"
    run ln -sfn "$HOME/.config/systemd/user/$unit" \
        "$HOME/.config/systemd/user/graphical-session.target.wants/$unit"
    say "  enable    $unit"
  else
    say "  missing   ~/.config/systemd/user/$unit"
  fi
done

# --- the LD_PRELOAD shim ---------------------------------------------------
# Desktop widgets are their own layer surfaces. Without the shim they are still
# drawn, but niri scales them with the workspace in the overview instead of
# pinning them to the backdrop, which breaks the "widgets live on the desktop"
# look. It is built by default because a fresh install must look right, not
# almost right.
say ""
if [ "$SHIM" -eq 1 ]; then
  say "Building noctalia-layer-swap.so"
  if [ "$DRY" -eq 1 ]; then
    say "  would: make -C $REPO/layer-swap/.local/src/noctalia-layer-swap"
    say "  -> installs \$HOME/.local/lib/noctalia-layer-swap.so (the Makefile's target)"
  elif ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
    say "  SKIP      no C toolchain (make + cc): install base-devel, then rerun"
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
  say "Shim not built (--no-shim). niri skips LD_PRELOAD cleanly if it is missing,"
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

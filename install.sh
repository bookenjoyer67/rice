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
#   ./install.sh --no-bars       skip compiling wallpaper-bars-gpu
#   ./install.sh --with-system   also install /etc/greetd/config.toml (sudo)
# ---------------------------------------------------------------------------
set -euo pipefail
shopt -s nullglob

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
DRY=0; SYSTEM=0; SHIM=1; DEPS=1; BARS=1

usage() {
  cat <<'EOF'
niri / Noctalia rice — installer

Symlinks every package in this repo into $HOME (no stow required). Any file
or directory it would overwrite is moved aside to <name>.bak-<timestamp>
first, so nothing is ever destroyed.

  ./install.sh                 packages, configs, Noctalia state, shim, bars
  ./install.sh --dry-run       show what would happen, touch nothing
  ./install.sh --no-deps       do not install packages (configs only)
  ./install.sh --no-shim       skip compiling noctalia-layer-swap.so
  ./install.sh --no-bars       skip compiling wallpaper-bars-gpu
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
    --build-bars)   BARS=1 ;;
    --no-bars)      BARS=0 ;;
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
# so two packages can never fight over ~/.local/bin or ~/.config/niri.
is_container() {
  case "$1" in
    "$HOME"|"$HOME/.config"|"$HOME/.local"|"$HOME/.local/bin"|\
    "$HOME/.local/src"|"$HOME/.local/share"|"$HOME/.config/systemd"|\
    "$HOME/.config/systemd/user"|"$HOME/.config/environment.d"|\
    "$HOME/.config/fish"|"$HOME/.config/fish/conf.d"|"$HOME/.config/fish/functions"|\
    "$HOME/.config/fish/completions"|"$HOME/.config/fish/themes") return 0 ;;
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
    system|screenshots|assets|eww|wofi) continue ;;
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
    # Two passes on purpose. The helper can only register the theme once
    # ~/.local/share/noctalia/brave-theme/manifest.json exists, and that is
    # created by Noctalia's `brave` community template — which declares
    #   requires_path = "~/.config/BraveSoftware/Brave-Browser"
    # and therefore renders nothing until the first pass has made the
    # Brave-Browser -> Brave-Origin symlink. First pass makes the link, second
    # pass writes the unpacked-extension entry into Preferences.
    "$HOME/.local/bin/brave-origin-theme.py"
    if [ ! -f "$HOME/.local/share/noctalia/brave-theme/manifest.json" ]; then
      if pgrep -x noctalia >/dev/null 2>&1; then
        say "  render    Noctalia brave template (templates-apply)"
        if noctalia msg templates-apply >/dev/null 2>&1; then
          "$HOME/.local/bin/brave-origin-theme.py"
        else
          say "  WARN      templates-apply failed — run manually: noctalia msg templates-apply"
        fi
      else
        say "  later     Brave theme needs a rendered theme pack and no running Noctalia."
        say "            Start Brave Origin once, log into the rice, then rerun ./install.sh"
        say "            (or: noctalia msg templates-apply && brave-origin-theme.py)"
      fi
    fi
  fi
else
  say "Brave origin theme helper not linked yet (run install.sh again after linking)"
fi

# --- fastfetch --------------------------------------------------------------
# The config carries an absolute logo path (fastfetch's kitty-direct logo reads
# the file directly), so it is rendered rather than symlinked, like the Noctalia
# state. Everything else in ~/.config/fastfetch is copied.
FF_DIR="$REPO/fastfetch"
say ""
say "fastfetch"
if [ -f "$FF_DIR/config.jsonc" ]; then
  if [ "$DRY" -eq 1 ]; then
    say "  would: render ~/.config/fastfetch/config.jsonc + logo + themes"
  else
    if [ -L "$HOME/.config/fastfetch" ]; then
      rm -f "$HOME/.config/fastfetch"          # stale symlink from an older install
    fi
    mkdir -p "$HOME/.config/fastfetch/themes"
    sed "s|/home/computing|$HOME|g" "$FF_DIR/config.jsonc" > "$HOME/.config/fastfetch/config.jsonc"
    cp -f "$FF_DIR/logo.png" "$HOME/.config/fastfetch/logo.png" 2>/dev/null || true
    cp -f "$FF_DIR"/themes/*.jsonc "$HOME/.config/fastfetch/themes/" 2>/dev/null || true
    say "  render    ~/.config/fastfetch/config.jsonc"
  fi
else
  say "  missing   fastfetch/config.jsonc"
fi

# --- starship ---------------------------------------------------------------
# The prompt palette is generated from the wallpaper (matugen template
# templates/starship.toml). starship has no include mechanism, so the whole file
# is generated: ship a fallback for the window before matugen first runs, and
# render immediately when a wallpaper is already known.
say ""
say "starship"
STAR_DST="$HOME/.config/starship.toml"
if [ -L "$STAR_DST" ]; then
  say "  unlink    ~/.config/starship.toml (was a symlink; it is generated now)"
  run rm -f "$STAR_DST"
fi
if [ "$DRY" -eq 1 ]; then
  say "  would: render ~/.config/starship.toml with the wallpaper palette"
elif [ -f "$STAR_DST" ]; then
  say "  ok        ~/.config/starship.toml (regenerated on wallpaper change)"
elif command -v matugen >/dev/null 2>&1 && [ -f "$HOME/.config/matugen/config.toml" ] \
     && [ -n "$(readlink -f "$HOME/.config/backgrounds/current-wallpaper" 2>/dev/null)" ]; then
  if matugen image "$(readlink -f "$HOME/.config/backgrounds/current-wallpaper")" \
        -m dark --prefer darkness --quiet >/dev/null 2>&1; then
    say "  render    ~/.config/starship.toml (matugen)"
  else
    say "  WARN      matugen failed — using the static fallback palette"
  fi
fi
if [ ! -f "$STAR_DST" ] && [ -f "$REPO/starship/fallback.toml" ]; then
  run cp -f "$REPO/starship/fallback.toml" "$STAR_DST"
  say "  fallback  ~/.config/starship.toml (until the first wallpaper change)"
fi

# --- fonts ------------------------------------------------------------------
# The terminal font is a Nerd Font; kitty silently falls back to whatever
# fontconfig picks if the family is missing, which looks like a broken rice.
say ""
say "Fonts"
if command -v fc-match >/dev/null 2>&1; then
  for fam in "CaskaydiaCove Nerd Font Mono" "MesloLGL Nerd Font Mono"; do
    got="$(fc-match -f '%{family}' "$fam" 2>/dev/null | head -n1)"
    case "$got" in
      *"$fam"*) say "  ok        $fam" ;;
      *) say "  MISSING   $fam (resolves to '${got:-nothing}') — pacman -S ttf-cascadia-code-nerd ttf-meslo-nerd" ;;
    esac
  done
else
  say "  skip      fontconfig not installed yet"
fi
# starship's format uses emoji (💻 👤 📁 🕰); Nerd Fonts cover the private-use
# glyphs but not these, so without an emoji font the prompt renders tofu boxes.
if command -v fc-list >/dev/null 2>&1; then
  if fc-list ':charset=1f4bb' family 2>/dev/null | grep -q .; then
    say "  ok        emoji coverage (U+1F4BB)"
  else
    say "  MISSING   emoji coverage — pacman -S noto-fonts-emoji"
  fi
fi

# --- wallpaper pool ---------------------------------------------------------
# ~/.config/wallpaper/pool.txt is the user's own file: seed it if missing,
# never overwrite, and never symlink it into the repo.
POOL_DST="$HOME/.config/wallpaper/pool.txt"
say ""
say "Wallpaper pool"
run mkdir -p "$HOME/.config/wallpaper"
if [ -e "$POOL_DST" ]; then
  say "  keep      ~/.config/wallpaper/pool.txt"
else
  run cp -f "$REPO/wallpaper-pool.default.txt" "$POOL_DST"
  say "  seed      ~/.config/wallpaper/pool.txt"
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

# Noctalia binds every desktop widget and lockscreen box to an output BY NAME
# (`output = "HDMI-A-1"`). The shipped state carries the names off the machine it
# was recorded on, so a box with different outputs (a VM's Virtual-1) creates no
# widget surfaces at all: the plugins load, the log says so, the desktop is just
# empty. Retargeting also has to drop the duplicates that collapsing two recorded
# outputs into one produces — otherwise you get two clocks, two bar groups.
#
# The work lives in local-bin/.local/bin/noctalia-widget-retarget.py so it can be
# rerun by hand (and, later, from a session-start hook) instead of only here.
retarget_widget_outputs() {
  local f="$1"
  shift
  if [ -x "$HOME/.local/bin/noctalia-widget-retarget.py" ]; then
    NOCTALIA_STATE="$f" "$HOME/.local/bin/noctalia-widget-retarget.py" "$@" || true
  else
    say "  skip      noctalia-widget-retarget.py not linked yet (rerun after linking)"
  fi
}

if [ -f "$STATE_SRC" ]; then
  if pgrep -x noctalia >/dev/null 2>&1; then
    say "  SKIP      Noctalia is running and owns settings.toml: it regenerates the file"
    say "            from memory when it exits, so a write here is lost. Do NOT try to"
    say "            reload under a live shell — a reload against a half-written file"
    say "            leaves it with an empty state and it then saves that on exit."
    say "            Log out, rerun this script, then log in again."
  elif [ "$DRY" -eq 1 ]; then
    say "  would: render settings.toml with $HOME substituted"
    say "  would: retarget desktop-widget/lockscreen outputs to this machine's outputs"
  else
    if [ -f "$STATE_DST" ]; then
      say "  backup    ~/.local/state/noctalia/settings.toml -> .bak-$TS"
      cp -f "$STATE_DST" "$STATE_DST.bak-$TS"
    fi
    mkdir -p "$(dirname "$STATE_DST")"
    sed "s|/home/computing|$HOME|g" "$STATE_SRC" > "$STATE_DST"
    say "  render    ~/.local/state/noctalia/settings.toml"
    retarget_widget_outputs "$STATE_DST"
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


# --- the GPU cava bars -----------------------------------------------------
# The wallpaper-bars widget was replaced by a layer-shell GLES renderer because
# cairo rasterising ~1400 translucent boxes per output cost about a full core.
# The binary is a build artifact, not a tracked file, so a fresh install has to
# compile it or the spawn-at-startup line in config.kdl points at nothing.
say ""
if [ "$BARS" -eq 1 ]; then
  BARS_SRC="$REPO/wallpaper-bars-gpu/.local/src/wallpaper-bars-gpu"
  say "Building wallpaper-bars-gpu"
  if [ "$DRY" -eq 1 ]; then
    say "  would: make -C $BARS_SRC && make -C $BARS_SRC install"
    say "  -> installs \$HOME/.local/bin/wallpaper-bars-gpu"
  elif ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
    say "  SKIP      no C toolchain (make + cc): install base-devel, then rerun"
  elif ! pkg-config --exists wayland-client wayland-egl egl glesv2 2>/dev/null; then
    say "  SKIP      missing dev headers: wayland egl glesv2 (--no-bars to ignore)"
  else
    if ! make -C "$BARS_SRC" >/dev/null; then
      echo "  ERROR: wallpaper-bars-gpu failed to build" >&2
      exit 1
    fi
    make -C "$BARS_SRC" install >/dev/null
    if [ -x "$HOME/.local/bin/wallpaper-bars-gpu" ]; then
      say "  installed ~/.local/bin/wallpaper-bars-gpu"
      say "  needs cava + imagemagick at runtime; cava.conf is linked from this repo"
    else
      echo "  ERROR: wallpaper-bars-gpu did not land in ~/.local/bin" >&2
      exit 1
    fi
  fi
else
  say "Bars not built (--no-bars). Mod+B and the startup line will find no binary,"
  say "so the cava bars simply do not appear."
fi

# --- system greeter config -------------------------------------------------
if [ "$SYSTEM" -eq 1 ]; then
  say ""
  say "Installing /etc/greetd/config.toml (sudo)"
  run sudo install -m 644 "$REPO/system/greetd/config.toml" /etc/greetd/config.toml
  say "  The session launched by the greeter is set by --cmd in that file."
  # tuigreet runs as the `greeter` user, whose HOME is / — it therefore never
  # reads ~/.config/tuigreet and only loads the system path. Without this copy a
  # fresh box gets the stock greeter: no theme colours, no title, no matrix rain.
  # The title is a brand string from the repo (custom_title), not the distro id:
  # only the pre-filled username is machine state, so only that is rendered here.
  TUI_SRC="$REPO/tuigreet/.config/tuigreet/config.toml"
  tui_title="$(sed -n 's/^custom_title = "\(.*\)"$/\1/p' "$TUI_SRC" | head -1)"
  tui_user="${SUDO_USER:-${USER:-}}"
  [ "$tui_user" = root ] && tui_user=""
  tui_tmp="$(mktemp)"
  if [ -n "$tui_user" ]; then
    tui_user_line="default_user = \"$tui_user\""
  else
    tui_user_line="# default_user unset (run --with-system via sudo from your user)"
  fi
  sed -e "s|^default_user = .*|$tui_user_line|" \
      "$TUI_SRC" > "$tui_tmp"
  # The shipped background is the patched "matrix-peak" (tuigreet-patch/).
  # Stock tuigreet only knows doom|matrix: an unknown kind silently renders no
  # background at all, so degrade to "matrix" when the patched binary that the
  # greeter would resolve is not installed.
  tui_kind="$(sed -n 's/^kind = "\(.*\)"$/\1/p' "$tui_tmp" | head -1)"
  if [ "$tui_kind" = "matrix-peak" ] && [ ! -x /usr/local/bin/tuigreet ]; then
    sed -i 's/^kind = "matrix-peak"/kind = "matrix"/' "$tui_tmp"
    say "  fallback  background matrix-peak -> matrix (patched greeter not installed)"
    say "            install it with $REPO/tuigreet-patch/build-matrix-peak.sh,"
    say "            then rerun this with --with-system to get the rainbow back"
  fi
  say "Installing /etc/tuigreet/config.toml (sudo, title=\"$tui_title\", user=\"${tui_user:-<none>}\")"
  run sudo install -D -m 644 "$tui_tmp" /etc/tuigreet/config.toml
  rm -f "$tui_tmp"
  say "  Check what the greeter will actually load:"
  say "    sudo -u greeter env HOME=/ tuigreet --dump-config | grep -A2 '\\[background\\]'"
  say "  Enable the greeter:  sudo systemctl enable --now greetd"
fi

say ""
say "Done. Next:"
say "  1. Log out and back in — or reload in place:  niri msg action load-config-file"
say "  2. Runtime deps:  niri noctalia matugen awww tuigreet kitty cliphist cava imagemagick"
say "                    wl-clipboard grim slurp swaylock brightnessctl wlsunset"
say "  3. Optional:  swaylock + the lock scripts need ~/.local/bin on \$PATH."

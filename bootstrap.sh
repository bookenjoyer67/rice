#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${RICE_REPO_URL:-https://github.com/bookenjoyer67/rice.git}"
BRANCH="${RICE_BRANCH:-main}"
DEST="${DOTFILES_DIR:-$HOME/dotfiles}"
REBOOT=0
SYSTEM=1
PASSTHROUGH=()

say() { printf '%s\n' "$*"; }
die() { printf '\nbootstrap: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --reboot)     REBOOT=1 ;;
    --no-system)  SYSTEM=0 ;;
    -h|--help)    sed -n '2,20p' "$0" 2>/dev/null || say "see the repo README"; exit 0 ;;
    *)            PASSTHROUGH+=("$arg") ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "run this as your user, not root (it links into \$HOME and builds AUR packages)."
command -v pacman >/dev/null 2>&1 || die "no pacman: this bootstrapper targets Arch."
command -v sudo   >/dev/null 2>&1 || die "no sudo: install it, or run the steps in the README by hand."
sudo -n true 2>/dev/null || say "sudo will ask for your password."

if ! command -v git >/dev/null 2>&1; then
  say "==> git is not installed (a fresh Arch install does not include it)"
  sudo pacman -S --needed --noconfirm git \
    || { say "    sync database empty — pacman -Sy"; sudo pacman -Sy --noconfirm; \
         sudo pacman -S --needed --noconfirm git; }
fi

if [ -d "$DEST/.git" ]; then
  say "==> updating $DEST (fast-forward only; local changes are never touched)"
  if [ -f "$DEST/.git/shallow" ]; then
    say "    shallow checkout — fetching full history once so future updates fast-forward"
    git -C "$DEST" fetch --unshallow origin "$BRANCH" || git -C "$DEST" fetch origin "$BRANCH"
  else
    git -C "$DEST" fetch origin "$BRANCH"
  fi
  git -C "$DEST" checkout -q "$BRANCH"
  git -C "$DEST" merge --ff-only "origin/$BRANCH" \
    || die "$DEST has local commits or changes — reconcile it, or set DOTFILES_DIR to a fresh path."
elif [ -e "$DEST" ]; then
  die "$DEST exists and is not a git checkout — move it aside or set DOTFILES_DIR."
else
  say "==> cloning $REPO_URL -> $DEST"
  git clone --branch "$BRANCH" "$REPO_URL" "$DEST"
fi

cd "$DEST"

say ""
say "==> ./install.sh ${PASSTHROUGH[*]:-}"
./install.sh ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

if [ "$SYSTEM" -eq 1 ] && [ "${#PASSTHROUGH[@]}" -eq 0 ]; then
  say ""
  say "==> /etc/greetd + /etc/tuigreet (sudo)"
  sudo env HOME="$HOME" ./install.sh --with-system
  say "==> enabling greetd"
  sudo systemctl enable greetd
fi

say ""
say "Done."
say ""
if [ "$SYSTEM" -eq 1 ] && [ "${#PASSTHROUGH[@]}" -eq 0 ]; then
  say "  reboot to land on the greeter (tuigreet -> niri-session):"
  say "    sudo reboot"
  say ""
  say "  after the first login, two things finish only with no live session:"
  say "    1. start Brave Origin once (its profile must exist for the theme)"
  say "    2. log out to a TTY, rerun $DEST/install.sh, log back in"
  say "       (Noctalia rewrites ~/.local/state/noctalia/settings.toml from"
  say "        memory on exit, so the state write is skipped while it runs)"
fi
say "  repo:  $DEST"
say "  logs:  rerun with --dry-run to see every action without changing anything"

if [ "$REBOOT" -eq 1 ] && [ "$SYSTEM" -eq 1 ] && [ "${#PASSTHROUGH[@]}" -eq 0 ]; then
  say ""
  say "==> rebooting in 5s — Ctrl-C to cancel"
  sleep 5
  sudo systemctl reboot
fi

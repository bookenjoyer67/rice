#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# niri / Noctalia rice — one-command onboarding for a fresh Arch install
#
#   curl -fsSL https://raw.githubusercontent.com/bookenjoyer67/rice/main/bootstrap.sh | bash
#
# Fetches the repo, installs every package it needs, mirrors the configs into
# $HOME, builds the LD_PRELOAD shim, installs the greetd/tuigreet configuration
# and enables the greeter. Safe to rerun: every step is idempotent.
#
#   ... | bash                 full install (packages + configs + system greeter)
#   ... | bash -s -- --dry-run show every action, touch nothing
#   ... | bash -s -- --reboot  reboot into the greeter when it is done
#   ... | bash -s -- --no-system
#                              skip /etc/greetd + /etc/tuigreet + greetd
#
# Any other argument is passed straight through to install.sh (--no-deps,
# --no-shim, ...). The system stage only runs when no argument was passed.
# ---------------------------------------------------------------------------
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

# --- preflight -------------------------------------------------------------
# makepkg refuses to build as root and the configs are linked into $HOME, so
# the whole install has to run as the user who will own the desktop.
[ "$(id -u)" -ne 0 ] || die "run this as your user, not root (it links into \$HOME and builds AUR packages)."
command -v pacman >/dev/null 2>&1 || die "no pacman: this bootstrapper targets Arch."
command -v sudo   >/dev/null 2>&1 || die "no sudo: install it, or run the steps in the README by hand."
sudo -n true 2>/dev/null || say "sudo will ask for your password."

# --- git -------------------------------------------------------------------
# git is in extra, not in base, and the archiso live environment does not ship
# it either: a fresh install cannot clone anything until this runs.
if ! command -v git >/dev/null 2>&1; then
  say "==> git is not installed (a fresh Arch install does not include it)"
  sudo pacman -S --needed --noconfirm git \
    || { say "    sync database empty — pacman -Sy"; sudo pacman -Sy --noconfirm; \
         sudo pacman -S --needed --noconfirm git; }
fi

# --- fetch -----------------------------------------------------------------
# A full clone, not --depth 1: a shallow checkout cannot fast-forward onto new
# upstream commits later ("refusing to merge unrelated histories"), which breaks
# the rerun this bootstrapper is documented to be safe for.
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

# --- install ---------------------------------------------------------------
say ""
say "==> ./install.sh ${PASSTHROUGH[*]:-}"
./install.sh ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

# The system stage is skipped for dry runs and partial runs on purpose: it
# writes /etc and would enable the greeter on a box that was not fully linked.
if [ "$SYSTEM" -eq 1 ] && [ "${#PASSTHROUGH[@]}" -eq 0 ]; then
  say ""
  say "==> /etc/greetd + /etc/tuigreet (sudo)"
  # HOME is preserved so the installer's own mirroring pass is a no-op here:
  # every link already exists from the user run above.
  sudo env HOME="$HOME" ./install.sh --with-system
  say "==> enabling greetd"
  sudo systemctl enable greetd
fi

# --- what is left ----------------------------------------------------------
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

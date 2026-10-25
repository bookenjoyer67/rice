#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/matrix-peak.patch"
TAG="${TUIGREET_TAG:-0.11.1}"
WORK="${TUIGREET_BUILD_DIR:-$HOME/.cache/tuigreet-matrix-peak}"
DEST=/usr/local/bin/tuigreet
MODE="${1:-install}"

say() { printf '%s\n' "$*"; }

if [ "$MODE" = "--uninstall" ]; then
  sudo rm -f "$DEST"
  say "removed $DEST (the packaged /usr/bin/tuigreet takes over again)"
  exit 0
fi

installed="$(pacman -Q greetd-tuigreet 2>/dev/null | awk '{print $2}')" || true
if [ -n "$installed" ]; then
  case "$installed" in
    "$TAG"-*) : ;;
    *) say "NOTE  packaged tuigreet is $installed, patching upstream $TAG."
       say "      Set TUIGREET_TAG=$installed to match, or the greeter will be"\
          ; say "      the patched build rather than the packaged one." ;;
  esac
fi

for bin in git cargo; do
  command -v "$bin" >/dev/null 2>&1 || { say "missing $bin"; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK"
say "cloning tuigreet $TAG -> $WORK"
git clone -q --depth 1 --branch "$TAG" https://github.com/tuigreet/tuigreet.git "$WORK"

cd "$WORK"
say "applying matrix-peak.patch"
git apply --index "$PATCH"

say "running the animation tests"
cargo test -q -p tuigreet bg_animation >/dev/null || {
  say "tests failed — not installing"; exit 1; }

say "building (release)"
cargo build -q --release -p tuigreet

BIN="$WORK/target/release/tuigreet"
[ -x "$BIN" ] || { say "build produced no binary"; exit 1; }

if [ "$MODE" = "--no-install" ]; then
  say "built: $BIN"
  exit 0
fi

say "installing $DEST"
sudo install -D -m 755 "$BIN" "$DEST"

say ""
say "done — $("$DEST" --version 2>/dev/null | tail -1)"
say "the greeter picks it up on the next boot; verify a running greeter with:"
say "  sudo -u greeter env HOME=/ /usr/local/bin/tuigreet --dump-config | grep -A3 background"

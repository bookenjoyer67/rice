#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build tuigreet with the "Matrix Peak" login background and install it.
#
# tuigreet's matrix takes three fixed colours and its background menu is a
# hard-coded catalog, so the rainbow wave and the "Matrix Peak" entry come from
# tuigreet/matrix-peak.patch against the upstream tag. This script applies that
# patch to a clean checkout, runs the animation tests, builds, and installs the
# binary to /usr/local/bin — which greetd resolves before the packaged
# /usr/bin/tuigreet, so the package itself is never touched or replaced.
#
#   tuigreet-patch/build-matrix-peak.sh              build + install (sudo for /usr/local)
#   tuigreet-patch/build-matrix-peak.sh --no-install compile only
#   tuigreet-patch/build-matrix-peak.sh --uninstall  remove /usr/local/bin/tuigreet
#
# Env: TUIGREET_TAG (default 0.11.1), TUIGREET_BUILD_DIR.
# Rebuild after a tuigreet package update: bump TUIGREET_TAG to the new version.
# ---------------------------------------------------------------------------
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

# --- what is installed right now -------------------------------------------
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

# --- clean checkout at the tag, patch applied ------------------------------
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

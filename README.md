# niri · Noctalia rice

A Wayland desktop rice: **[niri](https://github.com/YaLTeR/niri)** scrollable-tiling
compositor plus **[Noctalia v5](https://github.com/noctalia-dev/noctalia)** as the
shell, tied together by a wallpaper-driven Material 3 palette. The image on screen
is the only colour source — its palette is pushed into the compositor's focus ring,
the bar, the terminals, the editor and the browser.

Verified on Arch Linux: `niri 26.04` · `noctalia 5.3.0` · `matugen 4.2.0` ·
`awww 0.12.1` · `tuigreet 0.11.0`.

---

## Requirements

- Arch Linux (or a derivative with the same package names), x86_64
- a normal user with `sudo` — the installer runs as you, never as root
- working network access

That is the whole list. Packages, the AUR build, the fonts, the cursor theme, the
editor plugins and the `LD_PRELOAD` shim are all installed for you.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bookenjoyer67/rice/main/bootstrap.sh | bash
```

Run it as your user on a fresh Arch install. It:

1. installs `git` if the machine has none
2. clones this repo to `~/dotfiles`
3. runs `install.sh`, which installs every package in `packages.txt` (official
   repos) and `aur-packages.txt` (`brave-origin-bin`, via paru/yay or makepkg),
   mirrors each package into `$HOME`, syncs the Neovim plugins, renders the
   fastfetch and starship configs, writes the Noctalia state, extracts the cursor
   theme, enables the session units and compiles `noctalia-layer-swap.so`
4. writes `/etc/greetd/config.toml` and `/etc/tuigreet/config.toml` and enables
   `greetd`, so the next boot lands on the login screen and logging in starts
   `niri-session`

Anything the installer would overwrite is first moved to `<name>.bak-<timestamp>`.
It never deletes a file of yours.

### Flags

| Command | Effect |
|---|---|
| `… \| bash` | full install, including the system greeter |
| `… \| bash -s -- --dry-run` | print every action, change nothing |
| `… \| bash -s -- --reboot` | reboot into the greeter when it finishes |
| `… \| bash -s -- --no-system` | skip `/etc/greetd`, `/etc/tuigreet` and enabling greetd |
| `… \| bash -s -- --no-deps` | link configs only, install no packages |
| `… \| bash -s -- --no-shim` | skip compiling the layer-swap shim |

`DOTFILES_DIR` overrides the checkout path, `RICE_REPO_URL` / `RICE_BRANCH` the
remote. With any argument present the system stage is skipped on purpose, so a
partial run never half-configures a greeter. Rerunning is safe: the checkout is
fast-forwarded and every install step is idempotent.

### After the first reboot

Log in at the greeter — niri starts with the bar, wallpaper and palette already
applied. Then finish two one-time steps:

1. launch Brave Origin once, so its profile exists
2. log out to a TTY, run `~/dotfiles/install.sh`, log back in

The first registers the generated browser theme. The second writes the Noctalia
state file, which Noctalia rewrites from memory while it runs — the installer
skips it under a live session rather than losing the write.

---

## Install by hand

```bash
sudo pacman -S --needed git
git clone https://github.com/bookenjoyer67/rice.git ~/dotfiles
cd ~/dotfiles

./install.sh --dry-run            # what would be linked
./install.sh                      # packages, configs, Noctalia state, shim
sudo ./install.sh --with-system   # /etc/greetd + /etc/tuigreet (run with HOME kept)
sudo systemctl enable greetd
```

`install.sh` mirrors every top-level package directory onto `$HOME` — the GNU-stow
convention, done explicitly so stow is not a dependency. Shared directories
(`~/.config`, `~/.local/bin`, `~/.local/src`, `~/.config/systemd/user`) are
recursed into, so two packages can never clobber each other.

For the system stage keep `HOME` intact (`sudo env HOME="$HOME" ./install.sh
--with-system`), otherwise `sudo` rewrites `HOME` to `/root` and the mirroring
pass lands in the wrong place.

Reload in place with `niri msg action load-config-file`, or log out and back in.

---

## What ships

| Component | Role |
|---|---|
| **niri** | Scrollable-tiling Wayland compositor, KDL config, hot-reloadable over IPC |
| **Noctalia v5** | Bar on every output, notifications, SNI tray, launcher, control centre, wallpaper picker, OSD |
| **matugen** | Material 3 palette extraction, rendered into kitty, Neovim and the lock-screen palette |
| **awww** | Per-output wallpaper daemon |
| **tuigreet + greetd** | Text login that `exec`s `niri-session` on tty1; the shipped theme renders the patched "Matrix Peak" background (rainbow wave, hot pink head) |
| **kitty** | Daily-driver terminal, running fish; alacritty and ghostty ship as alternatives |
| **swaylock** | Lock screen with a palette-matched backdrop |
| **Noctalia plugins** | Seven Luau plugins — bar widgets, desktop widgets, wallpaper browser |
| **`noctalia-layer-swap.so`** | `LD_PRELOAD` shim (C, `layer-swap/`) that pins desktop widgets to the niri overview backdrop |

Also installed: Neovim + plugins, starship, fastfetch, tmux, cliphist, grim/slurp,
wf-recorder, brightnessctl, wlsunset, xwayland-satellite, pipewire, the Caskaydia
Cove and Meslo Nerd Fonts, and Brave Origin from the AUR.

---

## Login screen

The greeter runs the stock `tuigreet` binary from the repos, except for one
patch: the shipped theme asks for `kind = "matrix-peak"`, a matrix rain whose
trail scrolls through the spectrum with a hot pink leading glyph, listed in the
greeter's background switcher (F4) as **Matrix Peak**. Stock tuigreet only knows
`doom` and `matrix`, so build the patched binary once:

```bash
~/dotfiles/tuigreet-patch/build-matrix-peak.sh            # clones the matching
                                                          # tuigreet tag, applies
                                                          # the patch, installs
                                                          # /usr/local/bin/tuigreet
sudo env HOME="$HOME" ~/dotfiles/install.sh --with-system  # re-render /etc/tuigreet
```

`/usr/local/bin/tuigreet` wins over the packaged `/usr/bin/tuigreet` in greetd's
PATH, so the package stays untouched; `build-matrix-peak.sh --uninstall` puts the
stock binary back. Rainbow speed and width live in
`tuigreet/.config/tuigreet/config.toml` as `hue_speed` and `hue_step`. After a
tuigreet package update, rebuild with `TUIGREET_TAG=<new version>`.

---

## Layout

Each top-level directory is a package mirroring onto `$HOME`.

```
niri/              .config/niri            config.kdl · animations/ · focus-ring.kdl · noctalia.kdl · scripts/
noctalia/          .config/noctalia        bar.toml · backdrop.toml · templates/ · scripts/
noctalia-plugins/  .config/noctalia-v5-plugins   seven Luau plugins
noctalia-state/    settings.toml template  plugin enablement, desktop widgets
matugen/           .config/matugen         palette templates (kitty, nvim, lock)
kitty/  alacritty/  ghostty/               terminal configs
backgrounds/       .config/backgrounds     wallpapers
tuigreet/          .config/tuigreet        login screen theme
tuigreet-patch/    matrix-peak.patch       patches tuigreet with the rainbow
                   build-matrix-peak.sh    "Matrix Peak" background + installs it
system/            greetd/config.toml      installed by --with-system
layer-swap/        .local/src/noctalia-layer-swap   shim source, Makefile, protocol XML
local-bin/         .local/bin              lock.sh · make_backdrop.py · calcurse · refresh scripts
shell/             .zshrc .bashrc .profile .zshenv
fastfetch/         rendered config.jsonc + logo + themes
brave/             .config/brave-origin-flags.conf
session/           .config/environment.d + systemd user units
cursors/           Bibata-Rainbow-Modern.tar.zst, extracted to ~/.icons
packages.txt  aur-packages.txt   what the installer installs
bootstrap.sh                     the curl one-liner
```

The helper scripts niri spawns (`apply-wallpaper.sh`, `start-wallpaper-one.sh`,
`wallpaper-hotplug.sh`, `record-screen.sh`, `search-selection.sh`, …) live in
`niri/.config/niri/scripts/` and are reached through `~/.config/niri/scripts/`.
`system/` is the only package that needs root. `i3/`, `polybar/`, `picom/`,
`xresources/`, `screenlayout/` and `revclock/` are optional extras you can prune.

---

## Plugins

`~/.config/noctalia-v5-plugins/` — six are mine, one is upstream.

| Plugin | Id | What it does |
|---|---|---|
| Wallpaper Browser | `computing/wallpaper-browser` | Browse wallhaven.cc thumbnails in a panel and apply one. `Mod+Shift+B`. |
| Wallpaper Bars | `computing/wallpaper-bars` | Spectrum bars that sample the wallpaper behind them |
| Theme Refresh | `computing/theme-refresh` | Bar button that re-syncs the shell and widget palette |
| Desktop Essentials | `computing/desktop-essentials` | Desktop clock, one-line weather, DeepSeek peak/price countdown |
| Desktop Cat | `computing/desktop-cat` | Bongo Cat on the desktop: idles, blinks, sleeps, slaps its paws to the beat |
| Spotify Port | `computing/spotport` | Status for spotport — Spotify playlists ported into YouTube Music |
| Catwalk | `nathan/catwalk` | Animated cat for the bar. Third-party (MIT), vendored — upstream `natersalad/noctalia-catwalk` |

---

## Colour pipeline

```
wallpaper ──► Noctalia: extract palette ──► focus ring · bar · panels · widgets · Brave theme
          └─► matugen image ──────────────► kitty theme + background · nvim palette · lock backdrop
```

The niri focus ring is generated, not hand-written: `noctalia/templates.toml`
renders `templates/niri-focus-ring.kdl` and its post-hook reloads niri's config, so
the selection ring recolours on every wallpaper change without touching windows.
`noctalia/scripts/theme-refresh.sh` re-runs the chain on demand.

---

## Keybinds

`Mod` = Super.

| Bind | Action |
|---|---|
| `Mod+Return` | kitty |
| `Mod+Space` | launcher |
| `Mod+E` | file manager |
| `Mod+Q` / `Mod+F` | close window / fullscreen |
| `Mod+Shift+F` | toggle floating |
| `Mod+M` | maximise to edges |
| `Mod+A` / `Mod+D` | focus column left / right |
| `Mod+S` / `Mod+W` | focus window-or-workspace down / up |
| `Mod+Alt+A` / `Mod+Alt+D` | focus monitor left / right |
| `Mod+Ctrl+A` / `Mod+Ctrl+D` | move column left / right |
| `Mod+Ctrl+S` / `Mod+Ctrl+W` | move window down / up |
| `Mod+R`, `Mod+Minus`, `Mod+Equal` | cycle / shrink / grow column width |
| `Mod+1` … `Mod+9` | focus workspace |
| `Mod+Shift+1` … `Mod+Shift+9` | move window to workspace |
| `Mod+Shift+J` / `Mod+Shift+K` | move window to workspace down / up |
| `Mod+Tab` | overview |
| `Mod+Shift+L` | lock |
| `Mod+N` | notifications + control centre |
| `Mod+Shift+V` | clipboard history |
| `Mod+Shift+W` / `Mod+Shift+B` | random wallpaper / wallpaper browser |
| `Mod+Shift+E` | power menu |
| `Mod+Y` | yt-music panel |
| `Mod+P` / `Mod+Print` | screenshot region / screen |
| `Mod+Shift+R` | record screen |
| `Mod+Shift+P` | power off monitors |
| `Mod+Shift+Slash` | hotkey overlay |
| `XF86Audio*`, `XF86MonBrightness*` | volume / mute / brightness, also when locked |

Full list with comments: `niri/.config/niri/config.kdl`.

---

## Different hardware

Three places name this machine specifically. Change them once after the first
install:

- **Outputs.** `niri/.config/niri/config.kdl` declares `eDP-1` (1920x1080@144) and
  `HDMI-A-1` (1360x768 at x=1920). Run `niri msg outputs` and rewrite both blocks.
  `wallpaper-hotplug.sh` and `start-wallpaper-one.sh` assume the same two outputs.
- **Desktop-widget outputs.** `noctalia-state/settings.toml` binds widgets and the
  lock screen to an output by name, so a machine without those names draws no
  widget surfaces. Run this logged out, or from a TTY with `--assume`:

      ~/.local/bin/noctalia-widget-retarget.py --assume Virtual-1

- **Night light** is pinned to St. Louis: `wlsunset -l 38.6 -L -90.2` in
  `config.kdl`.

`~/.local/bin` must stay on `$PATH` — `lock.sh`, the wallpaper scripts and the
calcurse helpers live there.

---

## Credits

- [niri](https://github.com/YaLTeR/niri) — GPL-3.0
- [Noctalia](https://github.com/noctalia-dev/noctalia) and its community templates
- `nathan/catwalk` — MIT, © Nathan, ported from MannuVilasara's v4 Catwalk
- Wallpaper images collected from various sources — check licensing before
  redistributing this repo

## Licence

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own licence.

# niri · Noctalia rice

A Wayland desktop rice on CachyOS: **[niri](https://github.com/YaLTeR/niri)**
scrollable-tiling compositor + **[Noctalia v5](https://github.com/noctalia-dev/noctalia)**
shell, wired together with a wallpaper-driven colour pipeline. One palette,
extracted from the image on screen, pushed into the compositor, the bar, the
terminals, the launcher and the editor.

Verified on: `niri 26.04` · `noctalia v5.3.0` · `matugen 4.2.0` ·
`awww 0.12.1` · `tuigreet 0.11.0` · `plugin_api 30`

Clean-install tested: fresh Arch VM, `./install.sh` from an empty `$HOME`,
shim compiled, niri + Noctalia started, wallpaper palette propagated to the bar
and the niri focus ring.

> **Screenshot:** drop one in as `screenshots/desktop.png` and embed it here.
> This repo intentionally ships without a capture — one taken from a working
> session leaks window titles, open documents and terminal history.

---

## Stack

| Component | Role |
|---|---|
| **niri** | Scrollable-tiling Wayland compositor. KDL config, hot-reloadable via IPC. |
| **Noctalia v5** | Native shell: bar on every output, notifications (`org.freedesktop.Notifications`), SNI tray, launcher, control centre, wallpaper picker, OSD. |
| **Noctalia plugins** | Bar widgets and desktop widgets written in Luau — see the table below. |
| **matugen** | Material-3 palette extraction → rendered into app config files. |
| **awww** | Wallpaper daemon, per-output, animated. |
| **tuigreet + greetd** | Text-mode login that `exec`s `niri-session` on tty1. |
| **kitty** | Daily-driver terminal; alacritty and ghostty ship as alternatives. |
| **swaylock** | Lock screen; backdrop is pre-graded per output by `make_backdrop.py`. |
| **`noctalia-layer-swap.so`** | Custom `LD_PRELOAD` shim (C, `layer-swap/`) that pins desktop widgets into the niri overview backdrop instead of letting them zoom with the workspace. |

---

## Plugins

`~/.config/noctalia-v5-plugins/` — six are mine, one is upstream.

| Plugin | Id | What it does |
|---|---|---|
| Wallpaper Browser | `computing/wallpaper-browser` | Browse wallhaven.cc thumbnails in a panel and apply one by hand. Bound to `Mod+Shift+B`. |
| Wallpaper Bars | `computing/wallpaper-bars` | Spectrum bars that sample the wallpaper behind them and take its colours live. |
| Theme Refresh | `computing/theme-refresh` | Bar button that re-syncs the shell + widget palette when colour extraction lags behind a wallpaper change. |
| Desktop Essentials | `computing/desktop-essentials` | Desktop clock, one-line weather, DeepSeek peak/price countdown. |
| Desktop Cat | `computing/desktop-cat` | Bongo Cat on the desktop: idles, blinks, sleeps, slaps its paws to the beat. |
| Spotify Port | `computing/spotport` | Status for spotport — Spotify algorithmic playlists ported into YouTube Music. |
| Catwalk | `nathan/catwalk` | Animated cat for the bar. Third-party, MIT, vendored in `noctalia-plugins/` — upstream: `natersalad/noctalia-catwalk`. |

Older plugins declare `plugin_api` 14/26; they still load on v5.3.0 alongside
`plugin_api 30` ones.

---

## Layout

Each top-level directory is a *package* mirroring onto `$HOME` — the GNU-stow
convention, except `install.sh` does the linking explicitly so stow isn't needed.

```
niri/              .config/niri            config.kdl · animations/ · focus-ring.kdl · noctalia.kdl
noctalia/          .config/noctalia        bar.toml · backdrop.toml · templates/ · scripts/
noctalia-plugins/  .config/noctalia-v5-plugins   seven Luau plugins
matugen/           .config/matugen         palette templates (kitty, nvim, waybar, lock)
kitty/             .config/kitty           kitty.conf + matugen-rendered theme/bg includes
alacritty/         .config/alacritty
ghostty/           .config/ghostty
hyprland/          .config/hypr            wallpaper + screenshot scripts (used by niri — see note)
backgrounds/       .config/backgrounds     wallpapers
tuigreet/          .config/tuigreet        login screen theme
system/            greetd/config.toml      system file, installed with --with-system
layer-swap/        .local/src/noctalia-layer-swap   C shim source + Makefile + protocol XML
local-bin/         .local/bin              lock.sh · make_backdrop.py · calcurse · refresh scripts
shell/             .zshrc .bashrc .profile .zshenv
fastfetch/         config.jsonc + logo.png + themes (rendered, absolute logo path)
brave/             .config/brave-origin-flags.conf
session/           .config/environment.d + systemd user units (awww, lock-on-sleep)
noctalia-state/    settings.toml template (plugin enablement, desktop widgets)
cursors/           Bibata-Rainbow-Modern.tar.zst, extracted to ~/.icons
packages.txt  aur-packages.txt   what the installer installs
starship/  tmux/  nvim/  swaync/  rofi/  waybar/  picom/  polybar/  i3/  xresources/  screenlayout/  revclock/
```

**Note on `hyprland/`:** despite the name it is the shell-helper package niri
actually calls — `start-wallpaper-one.sh`, `wallpaper-hotplug.sh`,
`random-wallpaper.sh`, `swipe-delete-wallpaper.sh`, `record-screen.sh`,
`search-selection.sh` and the CRT shaders, all reached through
`~/.config/hypr/`. Don't delete that path.

`system/` is the only package that needs root. The rest (`i3/`, `polybar/`,
`picom/`, `xresources/`, `screenlayout/`, `revclock/`) are optional extras —
install or prune them as you like.

---

## Install

```bash
git clone <this-repo> ~/dotfiles
cd ~/dotfiles

./install.sh --dry-run            # show exactly what will be linked
./install.sh                      # symlink everything into $HOME
./install.sh --build-shim         # compile + install noctalia-layer-swap.so
sudo ./install.sh --with-system   # install /etc/greetd + /etc/tuigreet configs
```

`install.sh` never deletes: anything it would overwrite is moved to
`<name>.bak-<timestamp>` first, and `--dry-run` prints every action without
touching the disk. Shared directories (`~/.config`, `~/.local/bin`,
`~/.local/src`) are recursed into so packages can't clobber each other.

Then reload in place (`niri msg action load-config-file`) or log out and back in.

### Dependencies

`./install.sh` installs everything itself: `packages.txt` (official repos) via
pacman and `aur-packages.txt` (`brave-origin-bin`) via paru/yay, or makepkg when
no AUR helper exists. Already-installed packages are skipped, so rerunning is a
no-op. `--no-deps` links configs only.

```
./install.sh                 # packages + configs + Noctalia state + shim
./install.sh --dry-run
./install.sh --no-deps
./install.sh --with-system   # /etc/greetd/config.toml (sudo)
```

The editor config ships with the rice: after linking, `install.sh` runs
`nvim --headless "+Lazy! sync" +qa`, so the first `nvim` opens with its plugins
installed instead of an empty plugin manager. Brave Origin gets
`~/.config/brave-origin-flags.conf` (Wayland + native notifications).

Prompt and greeting ship too: `starship` is initialised from `.bashrc` (guarded,
plain PS1 if it is missing) with `starship.toml`, and `fastfetch` runs on
interactive login shells using `fastfetch/config.jsonc` — rendered by the
installer because its kitty-direct logo needs an absolute path.

Terminals: kitty runs `fish`, and `fish/.config/fish/conf.d/rice.fish` adds the
starship prompt plus a `fish_greeting` that prints fastfetch, so every new
terminal opens with the fetch. conf.d is used so an existing
`~/.config/fish/config.fish` is never replaced. Fonts: `ttf-cascadia-code-nerd`
(kitty's CaskaydiaCove Nerd Font Mono) and `ttf-meslo-nerd` (Noctalia widgets)
are installed, and `install.sh` reports whether each family actually resolves.

### Brave Origin theme

Brave Origin is themed by Noctalia's community `brave` template, but two things
in that template assume the regular Brave build. `brave-origin-theme.py`
(run automatically by `install.sh`) fixes both:

- Brave Origin keeps its profile in `~/.config/BraveSoftware/Brave-Origin`, while
  the template writes to `Brave-Browser`. A relative symlink bridges them.
- The theme is an *unpacked* Chromium extension and upstream asks you to
  "Load unpacked" by hand. The unpacked id is a pure function of the extension
  path, so the entry is written into `Preferences` directly.

`apply-wallpaper.sh` re-renders just the Brave manifest on every wallpaper change
(`noctalia theme <image> --scheme vibrant -r ...`) and reinstalls the theme files
— the full `templates-apply` is still avoided because it rewrites vscode, obsidian
and other app configs on every swipe. Chromium only re-reads `Preferences` at
startup, so the palette seed (`browser.theme.user_color`) lands the next time
Brave is launched; the theme images update immediately. Launch Brave Origin once
before the first install, or rerun `./install.sh` after its first start, so the
profile exists.

---

## Colour pipeline

```
wallpaper
   │
   ├── Noctalia: extract Material palette (async)
   │      ├── templates-apply ──► niri/focus-ring.kdl ──► niri msg action load-config-file
   │      ├── bar · panels · widgets · OSD (shell-native)
   │      └── Brave theme manifest (optional)
   │
   └── matugen image
          ├── kitty theme + background
          ├── nvim palette.lua      (SIGUSR1 → live reload)
          └── palette.yml           (lock-screen palette, see below)
```

`niri`'s focus ring is not hand-written: `noctalia/templates.toml` renders
`templates/niri-focus-ring.kdl` → `~/.config/niri/focus-ring.kdl` and its
`post_hook` reloads niri's config, so the selection ring recolours with every
wallpaper without restarting the compositor (windows untouched).

`noctalia/scripts/theme-refresh.sh` forces the whole chain to re-derive.
Noctalia ignores `wallpaper-set` when handed a path it already holds, so the
script alternates between two scratch copies of the same image, then polls the
rendered focus ring until its accent matches the freshly generated palette
before applying templates — otherwise everything renders one palette behind.

**Keep the `palette` matugen template.** `lock.sh` and `make_backdrop.py` read
`~/.local/state/rice/palette.yml` as the palette for the lock-screen backdrop.
Nothing in this rice draws a yambar bar or uses wofi.

---

## Keybinds

`Mod` = Super.

| Bind | Action |
|---|---|
| `Mod+Return` | kitty |
| `Mod+Space` | Noctalia launcher |
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
| `Mod+Shift+W` | random wallpaper |
| `Mod+Shift+B` | wallpaper browser |
| `Mod+Shift+E` | power menu |
| `Mod+Y` | yt-music panel |
| `Mod+P` / `Mod+Print` | screenshot region / screen |
| `Mod+Shift+R` | record screen |
| `Mod+Shift+P` | power off monitors |
| `Mod+Shift+Slash` | hotkey overlay |
| `XF86Audio*`, `XF86MonBrightness*` | volume / mute / brightness (work when locked) |

Full list: `niri/.config/niri/config.kdl` (450 lines, heavily commented).

---

## Porting checklist

If you copy this rather than install it, change these first:

- **Outputs.** `config.kdl` hardcodes `eDP-1` (1920x1080@144) and `HDMI-A-1`
  (1360x768 at x=1920). The TV is deliberately fed 1360x768 — it hard-overscans
  1080p with no OSD setting to disable it. Run `niri msg outputs` and rewrite
  both `output` blocks.
- **Noctalia desktop-widget outputs.** `noctalia-state/settings.toml` binds every
  desktop widget and lockscreen box to an output *by name* (`output = "HDMI-A-1"`).
  A machine without that output draws **no** widget surfaces at all — the plugins
  load and the log says so, the desktop is just empty. `install.sh` rewrites any
  output name it can't find on this machine to the first live output, but only
  when `niri msg` is reachable: install from a bare TTY and it can't, so log in
  and rerun `./install.sh`, or drag each widget once with
  `noctalia msg desktop-widgets-edit`. Placement boxes (`placement_width/height`,
  `cx`, `cy`) keep the recorded machine's geometry — the editor fixes those.
- **tuigreet theme.** tuigreet runs as user `greeter`, whose `HOME` is `/`, so it
  never reads `~/.config/tuigreet`. The theme, title and the matrix background
  only load from `/etc/tuigreet/config.toml` — `install.sh --with-system` renders
  it from `tuigreet/.config/tuigreet/config.toml`, filling in `custom_title` from
  the distro id in `/etc/os-release` and `default_user` from the user running the
  script (`sudo`-aware), since the shipped copy says "cachyos" / "computing".
  Verify with
  `sudo -u greeter env HOME=/ tuigreet --dump-config | grep -A2 '\[background\]'`.
- **`spawn-at-startup` display helpers.** `wallpaper-hotplug.sh` and
  `start-wallpaper-one.sh` assume the two-output layout.
- **Night light** is pinned to St. Louis: `wlsunset -l 38.6 -L -90.2`.
- **`xwayland-satellite`** is resolved from `$PATH` (the config deliberately
  does not pin a local build — uncomment the `xwayland-satellite { path }` block
  if you need a specific version).
- **`~/.local/bin` must be on `$PATH`** for `lock.sh`, the calcurse helpers and
  the wallpaper scripts.

## Known quirks

- **Noctalia's own state wins.** `~/.local/state/noctalia/settings.toml` loads
  after `bar.toml`; `noctalia/bar.toml` mirrors it by hand so the rice is
  reproducible from the repo.
- **The wallpapers are 26 MB** of this repo. Prune `backgrounds/` if that's a
  problem — nothing else depends on those specific images.

---

## Credits

- [niri](https://github.com/YaLTeR/niri) — GPL-3.0
- [Noctalia](https://github.com/noctalia-dev/noctalia) and its community templates
- `nathan/catwalk` — MIT, © Nathan, ported from MannuVilasara's v4 Catwalk
- Wallpaper images: collected from various sources; verify licensing before
  redistributing this repo publicly.

## Licence

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own licence.

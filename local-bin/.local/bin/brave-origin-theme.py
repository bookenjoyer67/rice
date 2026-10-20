#!/usr/bin/env python3
"""Point Noctalia's Brave theme at Brave Origin, and load it without clicks.

Two problems this solves:

1. Noctalia's community `brave` template writes into
   ~/.config/BraveSoftware/Brave-Browser (hardcoded upstream). Brave Origin
   stores its profile in Brave-Origin. A relative symlink makes the template
   work without patching a script Noctalia re-downloads from the registry.

2. The template renders an *unpacked* Chromium theme. Upstream tells you to open
   brave://extensions and "Load unpacked" by hand. Chromium's unpacked id is a
   pure function of the extension path, so the entry can be written straight
   into Preferences instead.

Run it while Brave is closed. install.sh calls it automatically; re-run it
after a fresh Brave install or after the theme directory moves.

  brave-origin-theme.py            seed profile symlink + theme entry
  brave-origin-theme.py --check    report state, change nothing
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
BRAVE_ROOT = CONFIG / "BraveSoftware"
THEME_DIR = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "noctalia" / "brave-theme"
CHECK = "--check" in sys.argv


def die(msg):
    print(f"brave-origin-theme: {msg}")
    sys.exit(0)


def brave_running():
    for name in ("brave", "brave-origin", "brave-browser"):
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            return True
    return False


def unpacked_id(path: Path) -> str:
    """Chromium's id for an unpacked extension: sha256(path)[:32], a-p base16."""
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def ensure_profile_link():
    origin = BRAVE_ROOT / "Brave-Origin"
    compat = BRAVE_ROOT / "Brave-Browser"
    if compat.is_symlink():
        print(f"  ok        {compat} -> {os.readlink(compat)}")
        return
    if compat.exists():
        print(f"  note      {compat} is a real directory (non-Origin profile); leaving it alone")
        return
    if not origin.is_dir():
        print("  skip      no Brave-Origin profile yet — start Brave Origin once, then rerun")
        return
    if CHECK:
        print(f"  would: ln -s Brave-Origin {compat}")
        return
    compat.symlink_to("Brave-Origin")
    print(f"  link      {compat} -> Brave-Origin")


def ensure_theme_entry():
    if not (THEME_DIR / "manifest.json").is_file():
        print("  skip      theme not rendered yet — run: noctalia msg templates-apply")
        return
    profile = BRAVE_ROOT / "Brave-Browser" / "Default" / "Preferences"
    if not profile.is_file():
        print(f"  skip      no Preferences at {profile}")
        return

    eid = unpacked_id(THEME_DIR.resolve())
    data = json.loads(profile.read_text())
    theme = data.get("extensions", {}).get("theme") or {}
    settings = data.get("extensions", {}).get("settings", {})

    if theme.get("id") == eid or eid in settings:
        print(f"  ok        theme loaded ({eid})")
        return
    if CHECK:
        print(f"  would: register unpacked theme {eid}")
        return
    if brave_running():
        print("  SKIP      Brave is running; quit it fully, then rerun this script")
        return

    manifest = json.loads((THEME_DIR / "manifest.json").read_text())
    ext = data.setdefault("extensions", {})
    ext.setdefault("ui", {})["developer_mode"] = True
    ext.setdefault("settings", {})[eid] = {
        "path": str(THEME_DIR.resolve()),
        "manifest": manifest,
        "state": 1,
        "location": 4,          # LOAD = unpacked
        "from_webstore": False,
        "was_installed_by_default": False,
        "install_time": "13300000000000000",
    }
    tmp = profile.with_suffix(".noctalia-tmp")
    tmp.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
    os.chmod(tmp, profile.stat().st_mode & 0o7777)
    tmp.replace(profile)
    print(f"  load      theme {eid} (Brave picks it up on next start)")


print("Brave Origin / Noctalia theme")
ensure_profile_link()
ensure_theme_entry()

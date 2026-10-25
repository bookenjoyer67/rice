#!/usr/bin/env python3
"""Retarget Noctalia desktop/lockscreen widgets to the outputs this machine has.

Noctalia binds every desktop widget and lockscreen box to an output BY NAME in
settings.toml. The state shipped with the rice carries the names of the machine
it was recorded on, so a machine with different outputs (a VM's Virtual-1)
creates no widget surfaces at all: the plugins load, the log says so, the
desktop is just empty.

Collapsing is not enough on its own. The recorded state has one set of widgets
per output, so pointing every unknown name at the single live output stacks two
clocks, two wallpaper-bar groups and two sysmons on top of each other. So after
retargeting, widgets that end up on the same output with the same `type` are
deduplicated, keeping the first one in `widget_order` (the set recorded for the
primary panel).

Only safe while Noctalia is NOT running: it holds this file in memory and
rewrites it on exit, and a reload against a half-written file leaves it with an
empty state that it then saves.

  noctalia-widget-retarget.py                 retarget + dedupe, report, write
  noctalia-widget-retarget.py --dry-run       report only
  noctalia-widget-retarget.py --assume Virtual-1
                                              use this output instead of asking niri
                                              (niri not running: bare TTY)
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("NOCTALIA_STATE",
                           HOME / ".local/state/noctalia/settings.toml"))
DRY = "--dry-run" in sys.argv

SECTIONS = ("desktop_widgets", "lockscreen_widgets")
BLOCK_RE = re.compile(
    r'^(\s*)\[(desktop_widgets|lockscreen_widgets)\.widget\.("?[^".\]]+"?)\]\s*$')

def out(msg):
    print(msg)

def live_outputs(assume=None):
    if assume:
        return [assume]
    for arg in sys.argv[1:]:
        if arg.startswith("--assume="):
            return [arg.split("=", 1)[1]]
    if "--assume" in sys.argv:
        i = sys.argv.index("--assume")
        if i + 1 < len(sys.argv):
            return [sys.argv[i + 1]]
    try:
        raw = subprocess.run(["niri", "msg", "--json", "outputs"],
                             capture_output=True, text=True, timeout=10)
        if raw.returncode == 0 and raw.stdout.strip():
            return list(json.loads(raw.stdout).keys())
    except Exception:
        pass
    return []

def parse(lines):
    """Return [{id, section, start, end, output, type}] for each widget.

    A widget block runs from its table header to the next table header at the
    same or a lower indent — NOT to the next widget of the same section. Getting
    that wrong deletes everything after the last widget of a section (it ate
    [plugins], [theme] and [wallpaper] once), so the boundary is indent-based.
    """
    widgets = []
    for i, line in enumerate(lines):
        m = BLOCK_RE.match(line)
        if not m:
            continue
        raw = m.group(3).strip()
        indent = len(m.group(1))
        widgets.append({"section": m.group(2), "id": raw, "key": raw.strip('"'),
                        "indent": indent, "start": i, "end": len(lines),
                        "output": None, "type": None})
    for w in widgets:
        for j in range(w["start"] + 1, len(lines)):
            stripped = lines[j].lstrip()
            if stripped.startswith("[") and (len(lines[j]) - len(stripped)) <= w["indent"]:
                w["end"] = j
                break
        for line in lines[w["start"]:w["end"]]:
            s = line.strip()
            if s.startswith("output = ") and w["output"] is None:
                w["output"] = s.split('"')[1] if '"' in s else None
            elif s.startswith("type = ") and w["type"] is None:
                w["type"] = s.split('"')[1] if '"' in s else None
    return widgets

def widget_order_slice(lines, section):
    """Return (start_line, end_line) of `widget_order = [ ... ]` inside [section]."""
    sec_start = None
    for i, line in enumerate(lines):
        if line.strip() == f"[{section}]":
            sec_start = i
            break
    if sec_start is None:
        return None
    for i in range(sec_start + 1, len(lines)):
        if lines[i].startswith("[") and not lines[i].startswith("    "):
            break
        if lines[i].strip().startswith("widget_order = "):
            j = i
            while "]" not in lines[j] and j + 1 < len(lines):
                j += 1
            return (i, j)
    return None

def ids_in_order(lines, span):
    text = "".join(lines[span[0]:span[1] + 1])
    return re.findall(r'"([^"]+)"', text)

def main():
    if not STATE.is_file():
        out(f"  skip      no {STATE}")
        return 0
    lines = STATE.read_text().splitlines(keepends=True)
    widgets = parse(lines)
    if not widgets:
        out("  ok        no widget tables in settings.toml")
        return 0

    outputs = live_outputs()
    if not outputs:
        out("  skip      cannot read niri outputs (niri not running, no --assume)")
        return 1
    first = outputs[0]
    known = set(outputs)

    retargeted, dropped = [], []
    for w in widgets:
        if w["output"] and w["output"] not in known:
            retargeted.append(w)

    orders = {}
    for sec in SECTIONS:
        span = widget_order_slice(lines, sec)
        orders[sec] = ids_in_order(lines, span) if span else []

    for w in widgets:
        w["effective"] = first if (w["output"] and w["output"] not in known) else w["output"]

    by_key = {}
    for w in widgets:
        by_key.setdefault((w["section"], w["type"]), []).append(w)
    for (sec, _type), group in by_key.items():
        if len(group) < 2:
            continue
        if len({w["effective"] for w in group}) > 1:
            continue  # one per output after retargeting: nothing to collapse
        if len({w["output"] for w in group}) < 2:
            continue  # all recorded on the same output: a deliberate pair, keep it
        order = orders.get(sec) or []
        group_sorted = sorted(group, key=lambda w: order.index(w["key"]) if w["key"] in order else 10**6)
        keep_from = group_sorted[0]["output"]
        for w in group_sorted[1:]:
            if w["output"] != keep_from:
                dropped.append(w)

    if not retargeted and not dropped:
        out(f"  ok        widget outputs match this machine ({', '.join(outputs)})")
        return 0

    for w in retargeted:
        out(f"  retarget  {w['key']}: \"{w['output']}\" -> \"{first}\"")
    for w in dropped:
        out(f"  drop      {w['key']} ({w['type']}) — duplicate of the same widget on {first}")

    if DRY:
        out("  would write ~/.local/state/noctalia/settings.toml")
        return 0

    drop_ranges = sorted(((w["start"], w["end"]) for w in dropped), reverse=True)
    new_lines = list(lines)
    for start, end in drop_ranges:
        del new_lines[start:end]
    text = "".join(new_lines)

    for w in retargeted:
        text = re.sub(
            r"(\[%s\.widget\.%s\][^\[]*?output = )\"[^\"]*\"" % (re.escape(w["section"]), re.escape(w["id"])),
            r'\1"%s"' % first, text, count=1, flags=re.S)

    for sec in SECTIONS:
        sec_drop = {w["key"] for w in dropped if w["section"] == sec}
        if not sec_drop:
            continue
        cur = text.splitlines(keepends=True)
        span = widget_order_slice(cur, sec)
        if not span:
            continue
        block = "".join(cur[span[0]:span[1] + 1])
        ids = re.findall(r'"([^"]+)"', block)
        kept = [i for i in ids if i not in sec_drop]
        indent = re.match(r"^(\s*)", cur[span[0]]).group(1)
        rebuilt = f"{indent}widget_order = [\n" + "".join(f'{indent}    "{i}",\n' for i in kept) + f"{indent}]\n"
        text = "".join(cur[:span[0]]) + rebuilt + "".join(cur[span[1] + 1:])

    tmp = STATE.with_suffix(".toml.retarget-tmp")
    tmp.write_text(text)
    os.chmod(tmp, STATE.stat().st_mode & 0o7777)
    tmp.replace(STATE)
    out(f"  wrote     {STATE}")
    return 0

if __name__ == "__main__":
    sys.exit(main())

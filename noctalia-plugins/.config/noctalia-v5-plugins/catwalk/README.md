# Catwalk for Noctalia v5

An animated cat bar widget for Noctalia v5. The cat reacts to aggregate CPU
utilization: it sleeps while the system is quiet and runs faster as CPU usage
increases.

It also follows Noctalia's resolved theme mode. Dark mode uses white SVG frames
and light mode uses black frames, including when Noctalia is set to automatic
wallpaper-driven mode.

## Install

Clone the repository into a local Noctalia plugin source:

```bash
git clone https://github.com/natersalad/noctalia-catwalk.git \
  ~/.config/noctalia-v5-plugins/catwalk
```

Add that parent directory as a local plugin source if it is not already present,
then enable `nathan/catwalk` and add `nathan/catwalk:cat` to a bar section.

For Nathan's current configuration:

```toml
[widget.catwalk]
type = "nathan/catwalk:cat"
```

## Behavior

- 0–10% CPU: sleeping animation
- 10–35% CPU: trotting
- 35–70% CPU: running
- Above 70% CPU: zooming
- Theme mode is checked every two seconds so the SVG set changes automatically

Hover over the cat to see current CPU utilization and its animation mood.

## Credits

Native Noctalia v5 port based on MannuVilasara's v4 Catwalk widget. The animated
artwork identifies itself as RunCat in the SVG metadata.


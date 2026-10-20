# Screenshots

Add captures here and embed them in the top-level `README.md`:

```markdown
![desktop](screenshots/desktop.png)
```

Take a clean one — this is the step people get wrong:

```bash
# region
grim -g "$(slurp)" screenshots/desktop.png

# whole output
grim -o eDP-1 screenshots/desktop.png
```

Close anything with client names, file paths, document titles or terminal
history visible on screen before capturing.

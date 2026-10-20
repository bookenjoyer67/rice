# Rice drop-in: prompt + terminal greeting.
#
# Lives in conf.d so it never replaces ~/.config/fish/config.fish — fish sources
# conf.d/*.fish first, then config.fish, so a user's own fish_greeting still wins.
if type -q starship
    starship init fish | source
end

function fish_greeting
    if type -q fastfetch
        fastfetch
    end
end

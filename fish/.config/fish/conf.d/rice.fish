if type -q starship
    starship init fish | source
end

function fish_greeting
    if type -q fastfetch
        fastfetch
    end
end

for dir in ~/.local/bin ~/.cargo/bin
    test -d $dir; and fish_add_path $dir
end

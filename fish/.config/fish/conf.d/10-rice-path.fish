# Rice: executable paths.
#
# ~/.local/bin holds local scripts (and hermes); ~/.cargo/bin holds cargo
# installs. A CachyOS ~/.config/fish/config.fish already adds them, a bare fish
# install does not — this drop-in makes the rice work either way. The installer
# only owns files in conf.d, so a machine's own config.fish is never replaced.
#
# Guarded: fish_add_path fails on a directory that does not exist yet, and a
# fresh machine has no ~/.cargo/bin until rustup has run.
for dir in ~/.local/bin ~/.cargo/bin
    test -d $dir; and fish_add_path $dir
end

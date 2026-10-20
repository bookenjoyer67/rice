#!/usr/bin/env bash
# Revolutionary Clock (C/GTK4 layer-shell) launcher.
# GSK_RENDERER=cairo is required: the default GL renderer bloats RAM (~240MB)
# vs cairo (~49MB).
export GSK_RENDERER="cairo"
exec $HOME/.local/bin/revolutionary-clock "$@"

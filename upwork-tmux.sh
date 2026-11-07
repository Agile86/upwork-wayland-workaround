#!/bin/bash
# upwork-tmux.sh - Run upwork-launcher.sh in a detached tmux session
#
# Usage: upwork-tmux.sh [upwork args...]
#   Set UPWORK_TMUX_SESSION to change the session name (default: upwork).
#   Watch the output with:  tmux attach -t upwork   (detach with Ctrl-b d)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/upwork-launcher.sh"
SESSION="${UPWORK_TMUX_SESSION:-upwork}"

if ! command -v tmux > /dev/null 2>&1; then
    echo "upwork-tmux: tmux is not installed (sudo apt install tmux)" >&2
    exit 1
fi

if [ ! -x "$LAUNCHER" ]; then
    echo "upwork-tmux: $LAUNCHER is missing or not executable" >&2
    exit 1
fi

if tmux has-session -t "=$SESSION" 2> /dev/null; then
    # A session that is still alive means Upwork (or the launcher) is running.
    # A dead pane is left over from a failed launch (see remain-on-exit below).
    if [ "$(tmux list-panes -t "=$SESSION:" -F '#{pane_dead}' | head -n1)" = "1" ]; then
        tmux kill-session -t "=$SESSION"
    else
        echo "upwork-tmux: session '$SESSION' is already running; attach with: tmux attach -t $SESSION" >&2
        exit 0
    fi
fi

# Build a properly quoted command line for tmux's shell
CMD=$(printf '%q' "$LAUNCHER")
for arg in "$@"; do
    CMD+=" $(printf '%q' "$arg")"
done

# -d: detached. Start in $HOME so the launcher does not depend on the caller's cwd.
# remain-on-exit failed keeps the pane (and its output) only if the launcher fails;
# it is chained in the same tmux call so a launcher that dies instantly is still caught.
tmux new-session -d -s "$SESSION" -c "$HOME" "$CMD" \; \
    set-option -t "=$SESSION:" remain-on-exit failed || exit 1

echo "upwork-tmux: started in detached tmux session '$SESSION' (attach: tmux attach -t $SESSION)"

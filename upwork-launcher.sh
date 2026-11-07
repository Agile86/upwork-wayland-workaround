#!/bin/bash
# upwork-launcher.sh - Launch Upwork with Wayland screenshot bridge

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Start the bridge in background if not already running
# Match on this checkout's full script path (regex-escaped), not any "screenshot.py"
BRIDGE_PATTERN="python3 $(printf '%s' "$SCRIPT_DIR/screenshot.py" | sed 's/[][\\.*^$+?(){}|\/]/\\&/g')"
if ! pgrep -f -- "$BRIDGE_PATTERN" > /dev/null 2>&1; then
    echo "Starting screenshot bridge..." >&2
    python3 "$SCRIPT_DIR/screenshot.py" &
    disown
    sleep 2
fi

# Fool Upwork into thinking it's running on X11
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY

# Find and launch Upwork
if [ -x /opt/Upwork/upwork ]; then
    exec /opt/Upwork/upwork "$@"
elif [ -x /usr/bin/upwork ]; then
    exec /usr/bin/upwork "$@"
else
    echo "Error: Upwork not found in /opt/Upwork/ or /usr/bin/" >&2
    exit 1
fi

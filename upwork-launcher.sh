#!/bin/bash
# upwork-launcher.sh - Launch Upwork with Wayland screenshot bridge

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/screenshot.py"
SCREENSHOT_NAME="org.gnome.Shell.Screenshot"

warn() { echo "upwork-launcher: $*" >&2; }

# Print the unique bus name owning $1 on the session bus (empty if unowned)
bus_owner() {
    gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner "$1" 2>/dev/null \
        | sed -n "s/^('\(.*\)',)$/\1/p"
}

# Upwork is single-instance: a second launch just quits and keeps the old
# instance, which never got the X11 environment below. Warn, but still
# launch so upwork:// links reach the running instance.
# (upwork-show.sh sets UPWORK_QUIET_RUNNING: relaunching is its whole point.)
if [ -z "$UPWORK_QUIET_RUNNING" ] && pgrep -x upwork > /dev/null 2>&1; then
    warn "Upwork is already running; it keeps the environment it was started with."
    warn "Quit it completely (including the tray icon) and relaunch to get the bridge."
fi

# Start the bridge in background if not already running
# Match on this checkout's full script path (regex-escaped), not any "screenshot.py"
BRIDGE_PATTERN="python3 $(printf '%s' "$BRIDGE" | sed 's/[][\\.*^$+?(){}|\/]/\\&/g')"
if pgrep -f -- "$BRIDGE_PATTERN" > /dev/null 2>&1; then
    : # bridge already running
elif [ -n "$(bus_owner "$SCREENSHOT_NAME")" ]; then
    # The bridge cannot take over a name that is already owned. On newer
    # GNOME (e.g. 50) the X11 environment below is enough, so this is fine.
    warn "$SCREENSHOT_NAME is already owned on the session bus (by gnome-shell?)."
    warn "Not starting the bridge; relying on the X11 environment override instead."
    warn "If Upwork screenshots fail, run 'python3 $BRIDGE' to see if the bridge can start."
elif ! python3 -c 'import dbus_next' 2>/dev/null; then
    warn "Python module 'dbus_next' is missing; the screenshot bridge cannot start."
    warn "Install it: sudo apt install python3-dbus-next  (or: pip3 install --user dbus-next)"
else
    echo "Starting screenshot bridge..." >&2
    python3 "$BRIDGE" &
    BRIDGE_PID=$!
    disown
    sleep 2
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        warn "Screenshot bridge exited right after starting; run 'python3 $BRIDGE' to see why."
    fi
fi

# Fool Upwork into thinking it's running on X11
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY

# Prefer the patched private copy of Upwork (see patch-upwork.sh): stock Upwork
# shows "Wayland not supported" after the first screenshot. The copy is rebuilt
# automatically when the installed Upwork changes. Set UPWORK_NO_PATCH=1 to
# always run the stock install instead.
PATCHED_UPWORK="${UPWORK_PATCHED_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/upwork-wayland-workaround/Upwork}/upwork"
if [ -z "$UPWORK_NO_PATCH" ]; then
    if "$SCRIPT_DIR/patch-upwork.sh" --quiet && [ -x "$PATCHED_UPWORK" ]; then
        SANDBOX_HELPER="$(dirname "$PATCHED_UPWORK")/chrome-sandbox"
        # Chromium aborts at startup unless its setuid sandbox helper is
        # root-owned with mode 4755. A user-made copy cannot set that itself.
        if [ "$(stat -c '%U %a' "$SANDBOX_HELPER" 2>/dev/null)" = "root 4755" ]; then
            exec "$PATCHED_UPWORK" "$@"
        fi
        warn "One-time setup needed: the patched copy's sandbox helper must be root-owned with mode 4755."
        warn "  sudo chown root:root '$SANDBOX_HELPER' && sudo chmod 4755 '$SANDBOX_HELPER'"
        warn "(Re-run this after the copy is rebuilt, e.g. when Upwork is updated.)"
    else
        warn "Could not prepare the patched Upwork copy."
    fi
    warn "Running the stock Upwork install instead (screenshots will stop after the first one)."
fi

# Find and launch Upwork
if [ -x /opt/Upwork/upwork ]; then
    exec /opt/Upwork/upwork "$@"
elif [ -x /usr/bin/upwork ]; then
    exec /usr/bin/upwork "$@"
else
    echo "Error: Upwork not found in /opt/Upwork/ or /usr/bin/" >&2
    exit 1
fi

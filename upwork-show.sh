#!/bin/bash
# upwork-show.sh - Bring Upwork to the foreground (start it if it isn't running).
#
# Why: Upwork's own show/hide hotkey is an X11 key grab. Under GNOME Wayland it
# only fires while an XWayland window (Upwork itself) has focus, so it can hide
# the window but never bring it back. install.sh binds this script to a GNOME
# shortcut instead; GNOME handles it no matter which window has focus.
#
# Upwork is single-instance: launching it again hands the request to the
# running instance, which brings its window to the foreground.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export UPWORK_QUIET_RUNNING=1
exec "$SCRIPT_DIR/upwork-launcher.sh" "$@" > /dev/null 2>&1

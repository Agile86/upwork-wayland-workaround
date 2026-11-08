#!/usr/bin/env python3
"""upwork-toggle.py - show/hide Upwork from a GNOME shortcut (Wayland-safe).

Usage: upwork-toggle.py [toggle|show|hide]      (default: toggle)

Upwork runs under XWayland, so its window is visible to the X11 window manager
interface even on a Wayland session (we use plain Xlib via ctypes; no extra
packages needed).

  toggle: if an Upwork window has focus, minimize it; otherwise bring it to the
          front (un-minimizing it if needed).
  show:   always bring it to the front.
  hide:   always minimize the focused/first Upwork window.

If no Upwork window is known to the window manager (not running, or Upwork hid
it with its own hotkey), it falls back to upwork-show.sh, which relaunches the
single-instance app so Upwork shows its own window.
"""
import ctypes
import os
import subprocess
import sys
import time
from ctypes import (POINTER, Structure, Union, byref, c_char_p, c_int, c_long,
                    c_ubyte, c_ulong, c_void_p)

HERE = os.path.dirname(os.path.abspath(__file__))
SHOW_SCRIPT = os.path.join(HERE, "upwork-show.sh")


def fall_back_to_launcher():
    subprocess.Popen([SHOW_SCRIPT], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


class XClientMessageEvent(Structure):
    _fields_ = [("type", c_int), ("serial", c_ulong), ("send_event", c_int),
                ("display", c_void_p), ("window", c_ulong),
                ("message_type", c_ulong), ("format", c_int),
                ("data", c_long * 5)]


class XEvent(Union):  # padded to the real XEvent size (24 longs)
    _fields_ = [("xclient", XClientMessageEvent), ("pad", c_long * 24)]


class XClassHint(Structure):
    _fields_ = [("res_name", c_char_p), ("res_class", c_char_p)]


def load_x11():
    x = ctypes.CDLL("libX11.so.6")
    x.XOpenDisplay.restype = c_void_p
    x.XOpenDisplay.argtypes = [c_char_p]
    x.XDefaultRootWindow.restype = c_ulong
    x.XDefaultRootWindow.argtypes = [c_void_p]
    x.XDefaultScreen.argtypes = [c_void_p]
    x.XInternAtom.restype = c_ulong
    x.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]
    x.XGetWindowProperty.argtypes = [
        c_void_p, c_ulong, c_ulong, c_long, c_long, c_int, c_ulong,
        POINTER(c_ulong), POINTER(c_int), POINTER(c_ulong), POINTER(c_ulong),
        POINTER(POINTER(c_ubyte))]
    x.XGetClassHint.argtypes = [c_void_p, c_ulong, POINTER(XClassHint)]
    x.XFree.argtypes = [c_void_p]
    x.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_long, POINTER(XEvent)]
    x.XIconifyWindow.argtypes = [c_void_p, c_ulong, c_int]
    x.XFlush.argtypes = [c_void_p]
    x.XSync.argtypes = [c_void_p, c_int]
    # Don't let a stale window id (BadWindow) kill the process.
    handler_t = ctypes.CFUNCTYPE(c_int, c_void_p, c_void_p)
    x._quiet = handler_t(lambda d, e: 0)
    x.XSetErrorHandler(x._quiet)
    return x


def open_display(x):
    for name in (os.environ.get("DISPLAY"), ":0"):
        if name:
            dpy = x.XOpenDisplay(name.encode())
            if dpy:
                return dpy
    return None


class Xw:
    def __init__(self):
        self.x = load_x11()
        self.dpy = open_display(self.x)
        if not self.dpy:
            raise RuntimeError("cannot open X display")
        self.root = self.x.XDefaultRootWindow(self.dpy)

    def atom(self, name):
        return self.x.XInternAtom(self.dpy, name.encode(), 0)

    def prop_longs(self, win, name):
        """32-bit property values (windows/atoms) as a list of ints."""
        atype, fmt = c_ulong(), c_int()
        n, after = c_ulong(), c_ulong()
        data = POINTER(c_ubyte)()
        rc = self.x.XGetWindowProperty(
            self.dpy, win, self.atom(name), 0, 1024, 0, 0,  # AnyPropertyType
            byref(atype), byref(fmt), byref(n), byref(after), byref(data))
        if rc != 0 or not data or fmt.value != 32:
            return []
        vals = list(ctypes.cast(data, POINTER(c_long))[:n.value])
        self.x.XFree(data)
        return [v & 0xFFFFFFFFFFFFFFFF for v in vals]

    def is_upwork(self, win):
        hint = XClassHint()
        if not win or not self.x.XGetClassHint(self.dpy, win, byref(hint)):
            return False
        res = (hint.res_class or b"").lower(), (hint.res_name or b"").lower()
        return res[0] == b"upwork" or res[1] == b"upwork"

    def client_message(self, win, msg, data):
        ev = XEvent()
        ev.xclient.type = 33  # ClientMessage
        ev.xclient.window = win
        ev.xclient.message_type = self.atom(msg)
        ev.xclient.format = 32
        for i, v in enumerate(data):
            ev.xclient.data[i] = v
        mask = (1 << 20) | (1 << 19)  # SubstructureRedirect | SubstructureNotify
        self.x.XSendEvent(self.dpy, self.root, 0, mask, byref(ev))
        self.x.XFlush(self.dpy)

    def active(self):
        v = self.prop_longs(self.root, "_NET_ACTIVE_WINDOW")
        return v[0] if v else 0

    def upwork_windows(self):
        """Managed Upwork windows, popups (always-on-top) last."""
        above = self.atom("_NET_WM_STATE_ABOVE")
        wins = [w for w in self.prop_longs(self.root, "_NET_CLIENT_LIST")
                if self.is_upwork(w)]
        wins.sort(key=lambda w: above in self.prop_longs(w, "_NET_WM_STATE"))
        return wins

    def minimize(self, win):
        self.x.XIconifyWindow(self.dpy, win, self.x.XDefaultScreen(self.dpy))
        self.x.XSync(self.dpy, 0)

    def activate(self, win):
        # source indication 2 = pager: bypasses focus-stealing prevention
        self.client_message(win, "_NET_ACTIVE_WINDOW", [2, 0, 0, 0, 0])
        self.x.XSync(self.dpy, 0)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "toggle"
    if mode not in ("toggle", "show", "hide"):
        sys.exit("usage: upwork-toggle.py [toggle|show|hide]")
    try:
        xw = Xw()
        wins = xw.upwork_windows()
    except (OSError, RuntimeError):
        wins = None
    if not wins:
        if mode != "hide":
            fall_back_to_launcher()
        return

    active = xw.active()
    if mode == "hide" or (mode == "toggle" and active in wins):
        xw.minimize(active if active in wins else wins[0])
        return

    target = wins[0]
    xw.activate(target)
    time.sleep(0.4)
    if xw.active() != target:  # activation refused: let Upwork do it itself
        fall_back_to_launcher()


if __name__ == "__main__":
    main()

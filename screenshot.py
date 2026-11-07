#!/usr/bin/env python3
# screenshot.py - Bridge script for Upwork on Wayland
import asyncio
import datetime as dt
import subprocess
import sys
import os

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method
from dbus_next import BusType, DBusError, RequestNameReply


def debug(*msg):
    try:
        print(*msg, file=sys.stderr, flush=True)
    except OSError:
        pass


# Callers choose the output path over D-Bus, so restrict where we will write.
ALLOWED_ROOTS = [
    os.path.realpath(p)
    for p in (
        os.path.expanduser('~'),
        '/tmp',
        '/var/tmp',
        os.environ.get('XDG_RUNTIME_DIR', ''),
    )
    if p
]
ALLOWED_EXTENSIONS = ('.png',)


def safe_path(filename):
    """Return a validated absolute path for grim to write to, or None."""
    if not filename or not os.path.isabs(filename) or '\0' in filename:
        return None
    if not filename.lower().endswith(ALLOWED_EXTENSIONS):
        return None
    # Resolve symlinks and '..' before checking the location
    real = os.path.realpath(filename)
    if not any(real == r or real.startswith(r + os.sep) for r in ALLOWED_ROOTS):
        return None
    return real


def grim_capture(args, filename):
    path = safe_path(filename)
    if path is None:
        debug('Rejected unsafe filename:', repr(filename))
        return [False, '']
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(['grim', *args, path], check=True)
    return [True, path]


class ScreenshotInterface(ServiceInterface):
    def __init__(self):
        super().__init__('org.gnome.Shell.Screenshot')

    @method()
    def Screenshot(self, include_cursor: 'b', flash: 'b', filename: 's') -> 'bs':
        debug('Screenshot call:', filename)
        try:
            result = grim_capture(['-c'] if include_cursor else [], filename)
            if result[0]:
                debug('Screenshot saved:', result[1])
            return result
        except Exception as e:
            debug('Screenshot error:', e)
            return [False, '']

    @method()
    def ScreenshotWindow(self, include_frame: 'b', include_cursor: 'b', flash: 'b', filename: 's') -> 'bs':
        debug('ScreenshotWindow call:', filename)
        return self.Screenshot(include_cursor, flash, filename)

    @method()
    def ScreenshotArea(self, x: 'i', y: 'i', width: 'i', height: 'i', flash: 'b', filename: 's') -> 'bs':
        debug('ScreenshotArea call:', x, y, width, height, filename)
        try:
            result = grim_capture(['-g', f'{x},{y} {width}x{height}'], filename)
            if result[0]:
                debug('Area screenshot saved:', result[1])
            return result
        except Exception as e:
            debug('ScreenshotArea error:', e)
            return [False, '']


class IdleMonitor(ServiceInterface):
    def __init__(self):
        super().__init__('org.gnome.Mutter.IdleMonitor')
        self.last_active = dt.datetime.now(dt.timezone.utc)
        self.monitor = None
        self.worker = None

    async def start(self):
        try:
            self.monitor = await asyncio.create_subprocess_exec(
                'swayidle', '-w',
                'timeout', '1', 'echo timeout',
                'resume', 'echo resume',
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL
            )
            self.worker = asyncio.create_task(self.run())
            debug('swayidle started')
        except FileNotFoundError:
            debug('swayidle not found, idle tracking disabled')

    async def run(self):
        try:
            async for line in self.monitor.stdout:
                line = line.decode().strip()
                if line == 'resume':
                    self.last_active = dt.datetime.now(dt.timezone.utc)
        except Exception as e:
            debug('swayidle error:', e)

    @method()
    def GetIdletime(self) -> 't':
        delta = dt.datetime.now(dt.timezone.utc) - self.last_active
        return round(delta.total_seconds() * 1000)

    async def cleanup(self):
        if self.monitor and self.monitor.returncode is None:
            self.monitor.terminate()
            try:
                await asyncio.wait_for(self.monitor.wait(), timeout=2)
            except asyncio.TimeoutError:
                self.monitor.kill()


async def main():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    debug('Connected to D-Bus')

    screenshot = ScreenshotInterface()
    bus.export('/org/gnome/Shell/Screenshot', screenshot)
    
    idle = IdleMonitor()
    await idle.start()
    bus.export('/org/gnome/Mutter/IdleMonitor/Core', idle)

    try:
        reply = await bus.request_name('org.gnome.Shell.Screenshot')
    except DBusError as e:
        debug(f'Failed to claim Screenshot: {e}')
        await idle.cleanup()
        return
    if reply != RequestNameReply.PRIMARY_OWNER:
        debug('org.gnome.Shell.Screenshot is already owned by another process; exiting')
        await idle.cleanup()
        return
    debug('Claimed org.gnome.Shell.Screenshot')

    if idle.worker:
        try:
            reply = await bus.request_name('org.gnome.Mutter.IdleMonitor')
            if reply == RequestNameReply.PRIMARY_OWNER:
                debug('Claimed org.gnome.Mutter.IdleMonitor')
            else:
                debug('Warning: org.gnome.Mutter.IdleMonitor is owned by another process')
        except DBusError as e:
            debug(f'Warning: Failed to claim IdleMonitor: {e}')

    debug('Bridge ready!')

    try:
        await bus.wait_for_disconnect()
    finally:
        await idle.cleanup()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        debug('Stopped')

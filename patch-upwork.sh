#!/bin/bash
# patch-upwork.sh - Build a patched private COPY of Upwork (the install in
# /opt/Upwork is never modified).
#
# Why: on every screenshot Upwork calls isWayland(). The native module answers
# true on a Wayland session, so after the first (working) portal screenshot
# Upwork blanks all later ones and shows "Wayland not supported, please switch
# to Xorg". The native capture code itself works; only that reported answer is
# the problem. This patch makes uta_native.node's DesktopSessionAgent::IsWayland
# always return false (the internal capture backend choice is unaffected).
#
# Usage: patch-upwork.sh [--quiet] [--force]
#   Exit 0: patched copy is ready (printed path is $DEST/upwork)
#   Exit 1: could not build it (e.g. an Upwork version this patch does not know)
#
# Environment: UPWORK_SRC (default /opt/Upwork), UPWORK_PATCHED_DIR

set -euo pipefail

SRC="${UPWORK_SRC:-/opt/Upwork}"
DEST="${UPWORK_PATCHED_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/upwork-wayland-workaround/Upwork}"
STAMP="$DEST/.patched-from"
QUIET=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --force) FORCE=1 ;;
        *) echo "patch-upwork: unknown option $arg" >&2; exit 2 ;;
    esac
done

say() { [ "$QUIET" = 1 ] || echo "patch-upwork: $*" >&2; }
die() { echo "patch-upwork: $*" >&2; exit 1; }

[ -x "$SRC/upwork" ] && [ -f "$SRC/uta_native.node" ] || die "Upwork not found in $SRC"

# Identify the installed Upwork build (size + mtime survive dpkg installs)
SIG=$(stat -c '%n %s %Y' "$SRC/upwork" "$SRC/uta_native.node" "$SRC/resources/app.asar")

if [ "$FORCE" = 0 ] && [ -x "$DEST/upwork" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SIG" ]; then
    say "patched copy is up to date: $DEST"
    exit 0
fi

# Never swap the copy out from under a running instance
if pgrep -f -- "^$DEST/upwork" > /dev/null 2>&1; then
    die "the patched copy is running; quit Upwork completely, then retry"
fi

# Patch: DesktopSessionAgent::IsWayland() is
#   endbr64; movzx eax, BYTE PTR [rdi+0x290]; ret
# Replace the 7-byte movzx with  xor eax,eax; nop5  (always returns 0).
patch_native() {
    python3 -I - "$1" << 'PYEOF'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
original = bytes.fromhex('f30f1efa' + '0fb68790020000' + 'c3')
patched  = bytes.fromhex('f30f1efa' + '31c0' + '0f1f440000' + 'c3')
n_orig = data.count(original)
if n_orig != 1:
    if data.count(patched) == 1:
        print('already patched')
        sys.exit(0)
    print('IsWayland bytes not found exactly once (found %d); unknown Upwork build' % n_orig, file=sys.stderr)
    sys.exit(1)
at = data.index(original)
data[at:at + len(original)] = patched
open(path, 'wb').write(data)
print('patched at file offset 0x%x' % at)
PYEOF
}

TMP="$DEST.new"
rm -rf -- "$TMP"
mkdir -p -- "$(dirname "$DEST")"
say "copying $SRC -> $TMP ..."
cp -a -- "$SRC" "$TMP"
chmod -R u+w -- "$TMP"

if ! RESULT=$(patch_native "$TMP/uta_native.node"); then
    rm -rf -- "$TMP"
    die "patch failed: $RESULT"
fi
say "$RESULT"

# Verify: exactly 5 bytes differ from the original, same size, copy is executable
[ "$(stat -c %s "$SRC/uta_native.node")" = "$(stat -c %s "$TMP/uta_native.node")" ] \
    || { rm -rf -- "$TMP"; die "patched file size changed"; }
DIFF=$(cmp -l "$SRC/uta_native.node" "$TMP/uta_native.node" | wc -l)
if [ "$RESULT" != "already patched" ] && [ "$DIFF" != 5 ]; then
    rm -rf -- "$TMP"
    die "unexpected patch result ($DIFF bytes differ, expected 5)"
fi
[ -x "$TMP/upwork" ] || { rm -rf -- "$TMP"; die "copy is not executable"; }

echo "$SIG" > "$TMP/.patched-from"
rm -rf -- "$DEST"
mv -- "$TMP" "$DEST"
say "patched copy ready: $DEST/upwork"

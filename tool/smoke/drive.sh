#!/bin/zsh
# Drives the debug sai app for a manual smoke without a human at the mouse.
#
#   tool/smoke/drive.sh launch <scratch-dir>   build/... sai with scratch env
#   tool/smoke/drive.sh shot <name.png>        screenshot of the sai window
#   tool/smoke/drive.sh click <x> <y> [name]   real mouse click at window-
#                                              relative points, then shot
#   tool/smoke/drive.sh quit
#
# Points are logical (pt) from the window's top-left, title bar included;
# read them off a `shot` (2x pixels, measure from the window edge, not the
# image edge — screenshots carry a shadow margin). Needs Accessibility for
# the terminal. System Events' `click at` is an accessibility press that
# Flutter ignores, so clicks are posted as CGEvents (click.swift).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bin=$root/apps/sai_app/build/macos/Build/Products/Debug/sai.app/Contents/MacOS/sai
tools=${TMPDIR:-/tmp}/sai-smoke-tools
mkdir -p "$tools"
[ -x "$tools/click" ] || swiftc -O -o "$tools/click" "$here/click.swift"

wid() { swift "$here/wid.swift"; }
frame() {
  osascript -e 'tell application "System Events" to tell process "sai" to get {position, size} of window 1' | tr -d ','
}
shot() {
  local id; id=$(wid)
  [ -n "$id" ] || { echo "no sai window" >&2; exit 1; }
  screencapture -x -l "$id" "$1"
}

case $1 in
  launch)
    [ -d "$2" ] || { echo "usage: drive.sh launch <scratch-dir>" >&2; exit 2; }
    [ -x "$bin" ] || { echo "build first: (cd apps/sai_app && flutter build macos --debug)" >&2; exit 1; }
    (SAI_ARCHIVE_ROOT="$2/archive" SAI_SETTINGS_FILE="$2/settings.json" \
      nohup "$bin" >"$2/app.log" 2>&1 &)
    sleep 3
    frame ;;
  shot) shot "$2" ;;
  click)
    read wx wy ww wh <<< "$(frame)"
    [[ "$wx$wy$ww$wh" =~ ^[0-9-]+$ && -n "$ww" ]] || { echo "no sai window frame; not clicking" >&2; exit 1; }
    if (( $2 < 0 || $3 < 0 || $2 >= ww || $3 >= wh )); then
      echo "point ($2,$3) is outside the ${ww}x${wh} window; not clicking" >&2; exit 1
    fi
    osascript -e 'tell application "System Events" to set frontmost of process "sai" to true'
    "$tools/click" $((wx + $2)) $((wy + $3))
    sleep 1
    [ -n "$4" ] && shot "$4" || true ;;
  quit) pkill -f "$bin" || true; sleep 1; ! pgrep -f "$bin" >/dev/null && echo "sai closed" ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac

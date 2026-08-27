#!/bin/zsh
# Drives the debug sai app for a manual smoke without a human at the mouse.
#
#   tool/smoke/drive.sh launch <scratch-dir>   build/... sai with scratch env
#                                              (SAI_APP_BIN=<…/sai.app/Contents/MacOS/sai>
#                                              drives another bundle)
#   tool/smoke/drive.sh shot <name.png>        screenshot of the sai window
#   tool/smoke/drive.sh click <x> <y> [name]   real mouse click at window-
#                                              relative points, then shot
#   tool/smoke/drive.sh clickpx <shot.png> <px> <py> [name]
#                                              click the pixel of an earlier
#                                              shot; refuses if the window
#                                              moved or resized since
#   tool/smoke/drive.sh drag <x1> <y1> <x2> <y2> [name]  real mouse drag
#                                              between window-relative points
#   tool/smoke/drive.sh record <secs> <file.mov>  clip of the sai window's
#                                              screen rect, for a PR
#   tool/smoke/drive.sh quit
#
# Points are logical (pt) from the window's top-left, title bar included.
# Prefer `clickpx`: it takes the pixel you read off a shot and does the
# conversion itself (retina scale; shots carry no shadow) from the frame
# the shot was taken with — and refuses when the window has moved since, which is
# what a "swallowed click" almost always was (#40). Needs Accessibility for
# the terminal. System Events' `click at` is an accessibility press that
# Flutter ignores, so clicks are posted as CGEvents (click.swift).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# SAI_APP_BIN points at another bundle, e.g. a release from dist/ (#42).
bin=${SAI_APP_BIN:-$root/apps/sai_app/build/macos/Build/Products/Debug/sai.app/Contents/MacOS/sai}
tools=${TMPDIR:-/tmp}/sai-smoke-tools
mkdir -p "$tools"
[ -x "$tools/click" ] || swiftc -O -o "$tools/click" "$here/click.swift"
[ -x "$tools/drag" ] || swiftc -O -o "$tools/drag" "$here/drag.swift"

wid() { swift "$here/wid.swift"; }
frame() {
  osascript -e 'tell application "System Events" to tell process "sai" to get {position, size} of window 1' | tr -d ','
}
# Flutter's view does not accept the first mouse: a click on a window that
# is not key only makes it key and is otherwise lost (flutter/flutter#88915).
# So the app is activated first, and the click waits until its window is
# the main one.
activate() {
  osascript -e 'tell application "sai" to activate' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(osascript -e 'tell application "System Events" to tell process "sai" to get value of attribute "AXMain" of window 1' 2>/dev/null)" = "true" ]; then
      sleep 0.2; return 0
    fi
    sleep 0.2
  done
  echo "the sai window did not become main; not clicking" >&2; exit 1
}
shot() {
  local id; id=$(wid)
  [ -n "$id" ] || { echo "no sai window" >&2; exit 1; }
  # No shadow (-o): the image is then exactly the window at 1x or 2x, so a
  # pixel maps to a point without guessing a margin — the shadow is taller
  # below than above, and a symmetric guess put every y ~16 pt high (#40).
  screencapture -x -o -l "$id" "$1"
  # The frame and pixel size the shot was taken with, for clickpx.
  echo "$(frame) $(sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/ {printf "%s ", $2}')" > "$1.frame"
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
    activate
    "$tools/click" $((wx + $2)) $((wy + $3))
    sleep 1
    [ -n "$4" ] && shot "$4" || true ;;
  clickpx)
    [ -f "$2.frame" ] || { echo "no frame for $2; take it with drive.sh shot" >&2; exit 1; }
    read sx sy sw sh iw ih < "$2.frame"
    read wx wy ww wh <<< "$(frame)"
    if [ "$sx $sy $sw $sh" != "$wx $wy $ww $wh" ]; then
      echo "window moved since $2 (was $sx,$sy ${sw}x${sh}; now $wx,$wy ${ww}x${wh}); shot again" >&2; exit 1
    fi
    # Retina shots are 2 px per pt; a shadowless shot has no margin.
    scale=$(( (iw + ww / 2) / ww ))
    if (( iw != ww * scale || ih != wh * scale )); then
      echo "$2 is ${iw}x${ih} for a ${ww}x${wh} window; take shots with drive.sh shot" >&2; exit 1
    fi
    px=$(( $3 / scale )); py=$(( $4 / scale ))
    if (( px < 0 || py < 0 || px >= ww || py >= wh )); then
      echo "pixel ($3,$4) is outside the window; not clicking" >&2; exit 1
    fi
    activate
    "$tools/click" $((wx + px)) $((wy + py))
    sleep 1
    [ -n "$5" ] && shot "$5" || true ;;
  drag)
    read wx wy ww wh <<< "$(frame)"
    [[ "$wx$wy$ww$wh" =~ ^[0-9-]+$ && -n "$ww" ]] || { echo "no sai window frame; not dragging" >&2; exit 1; }
    for p in $2 $3 $4 $5; do
      [[ "$p" =~ ^[0-9]+$ ]] || { echo "usage: drive.sh drag <x1> <y1> <x2> <y2> [name]" >&2; exit 2; }
    done
    if (( $2 >= ww || $3 >= wh || $4 >= ww || $5 >= wh )); then
      echo "a point is outside the ${ww}x${wh} window; not dragging" >&2; exit 1
    fi
    osascript -e 'tell application "System Events" to set frontmost of process "sai" to true'
    "$tools/drag" $((wx + $2)) $((wy + $3)) $((wx + $4)) $((wy + $5))
    sleep 1
    [ -n "$6" ] && shot "$6" || true ;;
  record)
    read wx wy ww wh <<< "$(frame)"
    [[ "$wx$wy$ww$wh" =~ ^[0-9-]+$ && -n "$ww" ]] || { echo "no sai window frame; not recording" >&2; exit 1; }
    [ -n "$3" ] || { echo "usage: drive.sh record <secs> <file.mov>" >&2; exit 2; }
    # Video capture takes a screen rect, not a window id; the rect is the
    # window's frame, so keep other windows off it while it runs.
    screencapture -x -V "$2" -R "$wx,$wy,$ww,$wh" "$3"
    echo "recorded $3" ;;
  quit) pkill -f "$bin" || true; sleep 1; ! pgrep -f "$bin" >/dev/null && echo "sai closed" ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac

#!/usr/bin/env bash
#
# Says whether each phone capture in a directory draws the home indicator, and fails unless
# every one of them matches what was asked for.
#
#   scripts/home-indicator.sh none  docs/app-store-assets/raw/iphone-max
#   scripts/home-indicator.sh drawn docs/app-store-assets/raw/iphone-max
#
# The simulator decides whether the indicator is drawn, not the app and not the tour, and it
# can change between two runs on one booted device. So a set of captures is checked and
# not assumed: captures that disagree, or a set that flipped since the last one, would
# otherwise ship unnoticed. It reads the raw captures, not the framed store images, because
# the rows it samples are a bare capture's.
#
# It reads the 6.9" phone's and iPhone Duo's outer display captures and nothing else, and it
# fails on a capture it cannot read. The rows it samples are those screens', which draw the
# indicator the same distance from the bottom edge. On the iPad they cross the keyboard's
# bottom edge, which read as an indicator in three of five captures.
#
# A light capture and a dark one are judged with different tolerances. On a light capture a
# column counts as crossing the indicator when the two rows differ by more than 25. A dark
# indicator reads about 25 above its background (53 to 58 on 28 to 32, measured on Driverr
# iPhone 17 captures from scripts/look.sh), so 25 sits right at its edge and a dark capture
# that drew it read as "none". A dark capture is judged at 4 instead, which that indicator
# clears with a wide margin. The dark tour's captures measured the two rows identical in
# every sampled column, except where content runs off the bottom edge: the pane switcher's
# list put one tile's label across one of the 50 columns, and the indicator crosses nine in
# ten. So a dark capture reads "none" with up to one column in ten differing.

set -euo pipefail

want="${1:-}"
dir="${2:-}"
case "$want" in none|drawn) ;; *) echo "usage: $0 none|drawn <directory>" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "error: no directory '$dir'" >&2; exit 2; }
# Stops with the README section that lists what a machine needs, and not with a bare
# "command not found" on the first capture.
for tool in python3 sips; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "error: $tool is not on PATH. README.md, \"Building it\", lists what to install" >&2; exit 2; }
done

readonly SIZES="1320x2868 1398x2034"
# The darkest background a light capture may have on the row above the indicator; a capture
# with anything darker there is judged as dark. The light captures measured 225 to 255 and
# the dark tour's 0 to 50.
readonly LIGHT=128
# How far a column's two rows may differ and still count as the same, on a light capture and
# on a dark one.
readonly LIGHT_DELTA=25
readonly DARK_DELTA=4
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

wrong=0
unread=0
count=0
for shot in "$dir"/*.png; do
  [ -e "$shot" ] || { echo "error: no PNG in '$dir'" >&2; exit 2; }
  count=$((count + 1))
  name="$(basename "$shot")"
  height="$(sips -g pixelHeight "$shot" | awk '/pixelHeight/{print $2}')"
  width="$(sips -g pixelWidth "$shot" | awk '/pixelWidth/{print $2}')"
  if [[ " $SIZES " != *" ${width}x${height} "* ]]; then
    echo "$name: cannot classify, ${width}x${height} is not one of the phone sizes, $SIZES" >&2
    unread=$((unread + 1))
    continue
  fi
  # The whole image as an uncompressed BMP, because python3 here has no image library and a
  # BMP needs none.
  sips -s format bmp "$shot" --out "$work/shot.bmp" >/dev/null
  # One line: the verdict, then what was read. An empty line is an image that could not be
  # read, and it fails below with the rest.
  got="" detail=""
  read -r got detail < <(python3 - "$work/shot.bmp" "$LIGHT" "$LIGHT_DELTA" "$DARK_DELTA" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
light = int(sys.argv[2])
light_delta, dark_delta = int(sys.argv[3]), int(sys.argv[4])
offset = struct.unpack_from("<I", data, 10)[0]
width, height = struct.unpack_from("<ii", data, 18)
depth = struct.unpack_from("<H", data, 28)[0] // 8
stride = (width * depth + 3) & ~3
top_down = height < 0
height = abs(height)

def luminance(x, y):
    row = y if top_down else height - 1 - y
    b, g, r = data[offset + row * stride + x * depth : offset + row * stride + x * depth + 3]
    return (2126 * r + 7152 * g + 722 * b) // 10000

# The indicator is 15 rows tall with 24 clear rows below it, y 2829 to 2843 of 2868 and 1995
# to 2009 of 2034. `inside` is a row through it and `above` a row clear of it, both counted
# from the bottom edge.
inside, above = height - 32, height - 50
columns = range(width * 35 // 100, width * 65 // 100, 8)
through = [luminance(x, inside) for x in columns]
clear = [luminance(x, above) for x in columns]
appearance = "dark" if min(clear) < light else "light"
delta = dark_delta if appearance == "dark" else light_delta
hits = sum(1 for a, b in zip(through, clear) if abs(a - b) > delta)
beside = abs(luminance(width // 5, inside) - luminance(width // 5, above))
if hits * 10 >= len(columns) * 9 and beside <= delta:
    verdict = "drawn"
elif hits == 0 or (appearance == "dark" and hits * 10 <= len(columns)):
    verdict = "none"
else:
    verdict = "unclear"
print(f"{verdict} {appearance}, luminance {min(through)}-{max(through)} on the indicator's row "
      f"and {min(clear)}-{max(clear)} above it, {hits} of {len(columns)} columns differ "
      f"by more than {delta}")
PY
) || true
  case "$got" in
    "$want")
      echo "$name: home indicator $got ($detail)"
      ;;
    none|drawn)
      echo "$name: home indicator is $got, expected $want ($detail)" >&2
      wrong=$((wrong + 1))
      ;;
    *)
      echo "$name: cannot classify ($detail)" >&2
      unread=$((unread + 1))
      ;;
  esac
done

if [ "$unread" -gt 0 ]; then
  echo "error: cannot classify $unread of $count captures in $dir" >&2
  exit 1
fi
if [ "$wrong" -gt 0 ]; then
  echo "error: $wrong of $count captures in $dir do not match '$want'" >&2
  exit 1
fi
echo "$count captures in $dir: home indicator $want"

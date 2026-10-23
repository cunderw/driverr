#!/usr/bin/env bash
#
# Capture the App Store screenshot tour at the two sizes App Store Connect requires, and
# frame the captures for the store.
#
#   scripts/screenshots.sh              both sizes
#   scripts/screenshots.sh iphone-max   just the 6.9" iPhone
#   scripts/screenshots.sh ipad         just the 13" iPad
#   scripts/screenshots.sh --frame      no tour: frame the committed captures again
#   scripts/screenshots.sh --help       this text. It touches no simulator
#
# Three directories under docs/app-store-assets/:
#
#   raw/<kind>/   the tour's captures, named for what they show (needs-you.png, chat.png).
#                 Committed, so `--frame` can run without a simulator.
#   <kind>/       the store images, `NN-<name>.png`. Each is a raw capture in a device frame
#                 under a caption, drawn by scripts/frame-screenshots.swift, which also sets
#                 their order and captions. These are what the store upload reads.
#   header/       the product page header, header.png, and two crops of it at the shapes
#                 Apple cuts it to (crop-21x9.png, crop-3x2.png), to check that nothing that
#                 matters is cut off. Only header.png is uploaded, by hand.
#
# The header is drawn from both kinds' raw captures, so every run draws it again.
#
# The tour itself is DriverrUITests/ScreenshotTourUITests, driven against FakeControl's
# seeded session, so the images repeat from run to run.
#
# Each tour runs on this repo's own named simulator for that device kind. The
# sizes come from the devices, not from any scaling step here — a resized screenshot is
# rejected by App Store Connect, and worse, silently looks wrong.
#
# The status bar is overridden for the run (9:41 on a fixed date, four bars, a full
# battery) and cleared afterwards, also when the run fails. Without that every image
# carries the time it was taken at, and the iPad's the date.
#
# Each device is shut down and booted before its tour, and the phone set fails if an image
# draws the home indicator. `capture_one` says why. The shutdown stops anything else that is
# using that simulator, so run nothing else on it while this script runs.
#
# Each tour is captured to a temporary directory. A set replaces the committed one only
# after its count, its sizes and its home-indicator check pass, and the framed set likewise
# after its count, its sizes and its alpha check. A failed tour leaves its own committed
# sets as they were and prints where the failed images are. With both sizes asked for, a
# tour that passed before the failed one has already replaced its sets.

set -euo pipefail

# The build tool sends error reports and usage metrics to Sentry unless told not to. See
# README.md, "Building it".
export XCODEBUILDMCP_SENTRY_DISABLED=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly OUT_ROOT="$REPO_ROOT/docs/app-store-assets"
readonly RAW_ROOT="$OUT_ROOT/raw"
readonly TOUR="DriverrUITests/ScreenshotTourUITests"
readonly FRAMER="$REPO_ROOT/scripts/frame-screenshots.swift"

# What App Store Connect expects, and therefore what this script verifies rather than
# assumes. A tour that quietly captured the wrong device is the failure mode worth
# guarding: the images look fine and the upload is rejected days later.
expected_size() {
  case "$1" in
    iphone-max) echo "1320x2868" ;;
    ipad) echo "2064x2752" ;;
    *) echo "" ;;
  esac
}

# How many captures each tour takes. The tour leaves the host list out of the split view, so
# the iPad has no hosts.png. A skip that fires on the phone, or does not fire on the iPad,
# still passes the test, so the count is checked here and not assumed.
expected_count() {
  case "$1" in
    iphone-max) echo "6" ;;
    ipad) echo "5" ;;
    *) echo "" ;;
  esac
}

# How many store images each kind publishes: the length of `published` in
# scripts/frame-screenshots.swift. The phone's hosts.png is captured and not published.
published_count() {
  case "$1" in
    iphone-max|ipad) echo "5" ;;
    *) echo "" ;;
  esac
}

colour() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
note() { colour "36" "==> $*"; }
fail() { colour "31" "error: $*" >&2; exit 1; }

# The devices whose status bar this run has overridden. One trap for the whole script,
# because `main` loops over the kinds and a trap set per kind would replace the one before it.
OVERRIDDEN=()

clear_status_bars() {
  local udid
  for udid in ${OVERRIDDEN[@]+"${OVERRIDDEN[@]}"}; do
    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
  done
}
trap clear_status_bars EXIT

# The UDID of the one available device with this name. `simctl status_bar` takes a UDID, and
# two devices under one name would make "booted" ambiguous.
device_udid() {
  xcrun simctl list -j devices available | DEVICE_NAME="$1" python3 -c '
import json, os, sys
name = os.environ["DEVICE_NAME"]
found = [d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == name]
if len(found) != 1:
    sys.exit(f"{len(found)} available simulators are named {name!r}, expected exactly 1")
print(found[0])
'
}

# The time the status bar is fixed at, in the one form `simctl status_bar` takes as a
# date: ISO 8601 with milliseconds and a colon in the offset. It rejects
# `2007-01-09T09:41:00` and `…00Z` as "non-ISO", and a bare `9:41` leaves the iPad's date
# at today's. The simulator shows the time, the month and the day from this string and
# draws its own weekday. The offset is this Mac's on that day, because the simulator draws
# the time in the Mac's zone.
#
# `/bin/date`, because a GNU `date` first on PATH has no `-j`. An offset that is not
# `+hhmm` or `-hhmm` is an error and not a guess: a wrong offset draws a wrong time in
# every image.
tour_time() {
  local offset
  offset="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' '2007-01-09 09:41:00' '+%z' 2>/dev/null)" \
    || offset=""
  [[ "$offset" =~ ^[+-][0-9]{4}$ ]] \
    || fail "cannot read this Mac's UTC offset from /bin/date -j (got '$offset')"
  echo "2007-01-09T09:41:00.000${offset:0:3}:${offset:3:2}"
}

# Fails unless the directory holds exactly `want` images. The directory is a fresh one, so
# the message says the committed set was not touched.
check_count() {
  local what="$1" dir="$2" want="$3"
  local got
  got="$(find "$dir" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
  [ "$got" = "$want" ] || fail "$what has $got images, expected $want." \
    "The committed set is unchanged. The failed images are in $dir."
}

# Fails unless the image is `want` pixels (WxH) and, when `opaque` is given, has no alpha
# channel. App Store Connect rejects a screenshot or a header with one.
check_image() {
  local image="$1" want="$2" opaque="${3:-}"
  local got
  got="$(sips -g pixelWidth -g pixelHeight "$image" \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
  [ "$got" = "$want" ] || fail "$(basename "$image") is ${got}, expected ${want}." \
    "The committed set is unchanged. The failed images are in $(dirname "$image")."
  if [ -n "$opaque" ]; then
    local alpha
    alpha="$(sips -g hasAlpha "$image" | awk '/hasAlpha/{print $2}')"
    [ "$alpha" = "no" ] || fail "$(basename "$image") has an alpha channel (hasAlpha: $alpha)." \
      "The committed set is unchanged. The failed images are in $(dirname "$image")."
  fi
}

# Replaces the committed directory with a checked fresh one.
replace_set() {
  local fresh="$1" out="$2"
  rm -rf "$out"
  mkdir -p "$out"
  cp "$fresh"/*.png "$out"/
  rm -rf "$fresh"
}

# Frames one kind's committed raw captures into its store set.
frame_one() {
  local kind="$1"
  note "$kind: framing the captures in raw/$kind"
  local fresh
  fresh="$(mktemp -d)"
  swift "$FRAMER" "$kind" "$RAW_ROOT/$kind" "$fresh" \
    || fail "$kind: the framing failed. The committed set is unchanged."
  check_count "$kind" "$fresh" "$(published_count "$kind")"
  local want shot
  want="$(expected_size "$kind")"
  for shot in "$fresh"/*.png; do
    check_image "$shot" "$want" opaque
  done
  replace_set "$fresh" "$OUT_ROOT/$kind"
  note "$kind: $(ls "$OUT_ROOT/$kind"/*.png | wc -l | tr -d ' ') store images, all ${want}, no alpha"
}

# Draws the header and its two crops from both kinds' committed raw captures.
frame_header() {
  note "header: drawing it from raw/"
  local fresh
  fresh="$(mktemp -d)"
  swift "$FRAMER" header "$RAW_ROOT" "$fresh" \
    || fail "header: the drawing failed. The committed header is unchanged."
  check_count "header" "$fresh" 3
  check_image "$fresh/header.png" "5244x2950" opaque
  check_image "$fresh/crop-21x9.png" "3840x1646"
  check_image "$fresh/crop-3x2.png" "3840x2560"
  replace_set "$fresh" "$OUT_ROOT/header"
  note "header: header.png 5244x2950, no alpha, and its two crops"
}

capture_one() {
  local kind="$1"
  local out="$RAW_ROOT/$kind"
  note "capturing the tour on $kind"

  local device
  case "$kind" in
    ipad)       device="Driverr iPad" ;;
    iphone-max) device="Driverr iPhone 17 Pro Max" ;;
    *) fail "unknown simulator kind '$kind'" ;;
  esac

  # Shut down and booted first. SpringBoard hides the home indicator when the simulator
  # reports that attention is lost, and a booted device can stop getting those reports, so
  # every capture then draws the indicator. A boot brings them back. This is a warm
  # boot of a device that already has its userland. Never erase the device for this.
  #
  # Booted before the override too, because the override fails on a device that is shut
  # down. `-b` boots it and returns when the boot has finished.
  local udid
  udid="$(device_udid "$device")" || fail "cannot find the simulator '$device'"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  OVERRIDDEN+=("$udid")
  # Its own assignment, because a failure inside an argument's `$(…)` does not stop the
  # script.
  local bar_time
  bar_time="$(tour_time)"
  # `discharging`, because a level alone draws a green charging battery.
  xcrun simctl status_bar "$udid" override \
    --time "$bar_time" --cellularBars 4 --batteryLevel 100 --batteryState discharging

  local result_json
  result_json="$(mktemp)"
  # The project by absolute path. The config's relative `projectPath` can resolve to another
  # checkout from a linked worktree, and the tour would then capture that checkout's app.
  ( cd "$REPO_ROOT" && npx -y xcodebuildmcp@2.7.0 simulator test \
      --project-path "$REPO_ROOT/Driverr.xcodeproj" \
      --simulator-name "$device" \
      --extra-args -only-testing:"$TOUR" \
      --output json ) > "$result_json"

  # The run reports its own result bundle, so there is nothing to go hunting for.
  # `expanduser` because XcodeBuildMCP sometimes returns the path with a literal `~`,
  # and a tilde held in a shell variable is never expanded — so `[ -d "$bundle" ]` said
  # "no .xcresult found" about a bundle that was there, on a tour that had passed.
  local bundle
  bundle="$(RESULT_JSON="$result_json" python3 -c '
import json, os
d = json.load(open(os.environ["RESULT_JSON"]))
print(os.path.expanduser(d.get("data", {}).get("artifacts", {}).get("xcresultPath", "")))
')"
  [ -d "$bundle" ] || fail "no .xcresult found for $kind — read $result_json"

  local staging
  staging="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$staging" >/dev/null

  # Not into `$out`. The committed set stays until every check below has passed, so a failed
  # tour does not leave the tree without store images.
  local fresh
  fresh="$(mktemp -d)"

  # The manifest maps the name the test gave each attachment to the file on disk. Without
  # it the exported files are UUIDs and the ordering of the tour is lost.
  python3 - "$staging" "$fresh" <<'PY'
import json, os, shutil, sys
staging, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(staging, "manifest.json")))
count = 0
for entry in manifest:
    for attachment in entry.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName") or ""
        exported = attachment.get("exportedFileName")
        if not exported or not name:
            continue
        # "needs-you_0_<uuid>.png" -> "needs-you.png"
        stem = name.split("_")[0]
        shutil.copyfile(os.path.join(staging, exported), os.path.join(out, stem + ".png"))
        count += 1
print(f"exported {count} screenshots")
PY

  rm -rf "$staging"
  xcrun simctl status_bar "$udid" clear

  note "$kind: checking the captures in $fresh"
  check_count "$kind" "$fresh" "$(expected_count "$kind")"

  # The phone set has no home indicator, and the simulator decides that, not the tour. The
  # check reads the 6.9" phone captures only. The iPad captures have never drawn one.
  if [ "$kind" = "iphone-max" ]; then
    "$REPO_ROOT/scripts/home-indicator.sh" none "$fresh" \
      || fail "$kind drew the home indicator, or the check could not read it." \
        "The committed set is unchanged. The failed captures are in $fresh." \
        "Run the script again."
  fi

  local want
  want="$(expected_size "$kind")"
  local shot
  for shot in "$fresh"/*.png; do
    check_image "$shot" "$want"
  done

  # Every check has passed, so this set replaces the committed one.
  replace_set "$fresh" "$out"
  note "$kind: $(ls "$out"/*.png | wc -l | tr -d ' ') captures, all ${want}"
}

# Stops with the README section that lists what a machine needs, and not with a bare
# "command not found" after the simulator has been rebooted.
require_tools() {
  local tool
  for tool in npx python3 xcrun sips swift; do
    command -v "$tool" >/dev/null 2>&1 \
      || fail "$tool is not on PATH. README.md, \"Building it\", lists what to install"
  done
}

main() {
  case "${1:-}" in
    # Every leading comment line, up to the first line that is not one. The help returns
    # before any `simctl` call, and before the tool check, so it works on any machine.
    -h|--help)
      awk 'NR==1{next} /^#/{print; next} {exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
  require_tools
  local tour=1
  if [ "${1:-}" = "--frame" ]; then
    tour=0
    shift
  fi
  local kinds=("$@")
  [ ${#kinds[@]} -gt 0 ] || kinds=(iphone-max ipad)
  local kind
  for kind in "${kinds[@]}"; do
    [ -n "$(expected_size "$kind")" ] || fail "unknown size $kind (iphone-max|ipad)"
  done
  for kind in "${kinds[@]}"; do
    [ "$tour" = 0 ] || capture_one "$kind"
    frame_one "$kind"
  done
  frame_header
  note "written to docs/app-store-assets/"
  colour "33" "Now open them. A generated screenshot that nobody opened is not evidence."
}

main "$@"

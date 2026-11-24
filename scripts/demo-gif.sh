#!/usr/bin/env bash
#
# Record the README's demo GIF, docs/readme/demo.gif.
#
#   scripts/demo-gif.sh          record on `Driverr iPhone 17`, which must be booted
#   scripts/demo-gif.sh <udid>   record on that simulator instead, an iPhone that is booted
#   scripts/demo-gif.sh --help   this text. It touches no simulator
#
# The GIF is the core flow, recorded against the seeded test session: Needs You lists two
# blocked agents, the first one's chat opens, Approve goes over, and the agent works again.
# `-uiTestingApproveContinues` (Driverr/AppEnvironment.swift) is what makes the agent carry
# on. Without it the fake session stays blocked after Approve.
#
# How it works:
#
# 1. It fixes the status bar at 9:41 with full bars and battery, and clears it again on exit.
# 2. It starts `xcrun simctl io <udid> recordVideo`.
# 3. scripts/look.sh walks the flow in dark appearance. Its `shot:start` (Needs You) and
#    `shot:end` (the agent working) are the two screens the cut is found by.
# 4. It stops the recorder and finds those two screens in the movie by SSIM. The GIF opens
#    HOLD_BEFORE_TAP seconds before Needs You is left and ends HOLD_AT_END seconds after the
#    agent is first shown working. So the build before the walk, the app's exit after it and
#    the time XCUITest takes over each step are not in the GIF, and no trim point is typed in
#    by hand. The wall clock is no use here: the movie's clock does not follow it, and a cut
#    from the shots' timestamps landed 6 s off after a build.
# 5. ffmpeg turns the cut into a GIF with its own palette. It fails over 15 s or 5 MB.
#
# The video, the shots and a copy of every GIF frame go to .build-logs/demo-gif/, which git
# ignores. Read the frames before you commit a new GIF: the flow must be right and nothing
# private may show.
#
# Nothing else may run on that simulator or in this checkout while it records (CONTRIBUTING.md,
# "Two runs in one checkout or on one simulator give a wrong result"). It needs ffmpeg and
# ffprobe on PATH.

set -euo pipefail

colour() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
note() { colour "36" "==> $*"; }
fail() {
  colour "31" "error: $*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help)
    sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v ffmpeg >/dev/null || fail "ffmpeg is not on PATH"
command -v ffprobe >/dev/null || fail "ffprobe is not on PATH"

# The named udid, or the one available device called `Driverr iPhone 17`, and its state.
read -r UDID STATE < <(xcrun simctl list -j devices available | UDID="${1:-}" python3 -c '
import json, os, sys
devices = [d for ds in json.load(sys.stdin)["devices"].values() for d in ds]
asked = os.environ["UDID"]
want = asked or "Driverr iPhone 17"
found = [d for d in devices if d["udid" if asked else "name"] == want]
if len(found) != 1:
    sys.exit(f"{len(found)} available simulators match {want!r}, expected 1")
print(found[0]["udid"], found[0]["state"])
') || fail "could not find the simulator to record on"
[ "$STATE" = "Booted" ] || fail "simulator $UDID is $STATE; boot it first"

# The limits the README asks for, and the GIF's width in pixels.
MAX_SECONDS=15
MAX_BYTES=$((5 * 1024 * 1024))
WIDTH=480
FPS=12
# Seconds of Needs You before the tap, and of the working agent at the end.
HOLD_BEFORE_TAP=2
HOLD_AT_END=2.5

WORK="$REPO_ROOT/.build-logs/demo-gif"
rm -rf "$WORK"
mkdir -p "$WORK/frames"
MOV="$WORK/demo.mov"
SHOTS="$WORK/shots"
GIF="$WORK/demo.gif"
TARGET="$REPO_ROOT/docs/readme/demo.gif"

# The walk. `shot:start` is Needs You once the session's second poll has added its second
# blocked pane, `schema sync`, so the GIF does not open on the list growing. `shot:end` is the
# chat once it says the agent is working again. The sleeps after each shot keep the GIF's
# holds clear of the next step.
STEPS='tap:hosts.row,wait:session.blockedPane|schema sync,sleep:1,shot:start,sleep:2'
STEPS+=',tap:session.blockedPane|needs a decision'
STEPS+=',wait:pane.chat.turn.pending.chip.Approve,sleep:1.5'
STEPS+=',tap:pane.chat.turn.pending.chip.Approve'
STEPS+=',wait:pane.chat.activity|working,sleep:1,shot:end,sleep:3'
ARGS='-uiTestingConnected -uiTestingDemoTranscript -uiTestingApproveContinues'

RECORDER_PID=""
stop_recorder() {
  [ -n "$RECORDER_PID" ] || return 0
  # SIGINT, and a wait, or the movie is never finalised.
  kill -INT "$RECORDER_PID" 2>/dev/null || true
  wait "$RECORDER_PID" 2>/dev/null || true
  RECORDER_PID=""
}
cleanup() {
  stop_recorder
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The same form scripts/screenshots.sh uses; see `tour_time` there.
OFFSET="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' '2007-01-09 09:41:00' '+%z')"
[[ "$OFFSET" =~ ^[+-][0-9]{4}$ ]] || fail "cannot read this Mac's UTC offset (got '$OFFSET')"
xcrun simctl status_bar "$UDID" override \
  --time "2007-01-09T09:41:00.000${OFFSET:0:3}:${OFFSET:3:2}" \
  --cellularBars 4 --batteryLevel 100 --batteryState discharging

note "recording $UDID to $MOV"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$MOV" 2>"$WORK/recorder.log" &
RECORDER_PID=$!
for _ in $(seq 1 100); do
  grep -q "Recording started" "$WORK/recorder.log" && break
  sleep 0.1
done
grep -q "Recording started" "$WORK/recorder.log" \
  || fail "the recorder did not start; read $WORK/recorder.log"

scripts/look.sh --simulator-id "$UDID" --dark --args "$ARGS" --steps "$STEPS" --out "$SHOTS" \
  || fail "the walk failed; the shots are in $SHOTS"
stop_recorder

# How like each shot every frame of the movie is, at $FPS frames a second. Small and grey,
# because only the screen's layout has to match: a spinner's turn must not count.
for which in start end; do
  shot="$(ls "$SHOTS"/*-"$which".png 2>/dev/null | head -n 1 || true)"
  [ -n "$shot" ] || fail "look.sh wrote no '$which' shot; read $SHOTS"
  ffmpeg -v error -i "$MOV" -i "$shot" -lavfi \
    "[0]fps=$FPS,scale=160:-1,format=gray[a];[1]scale=160:-1,format=gray[b];[a][b]ssim=stats_file=$WORK/ssim-$which.txt" \
    -f null - || fail "could not compare the movie with $shot"
done

# The first run of frames that match each shot. Needs You is still until the tap, so the cut
# starts HOLD_BEFORE_TAP before that run ends. The working chat starts at the first frame of
# its run, and the cut ends HOLD_AT_END after it.
read -r CUT_START CUT_END < <(WORK="$WORK" FPS="$FPS" HOLD_BEFORE_TAP="$HOLD_BEFORE_TAP" \
  HOLD_AT_END="$HOLD_AT_END" python3 -c '
import os, re, sys
work, fps = os.environ["WORK"], float(os.environ["FPS"])
def first_run(which):
    scores = [float(re.search(r"All:([0-9.]+)", line).group(1))
              for line in open(os.path.join(work, f"ssim-{which}.txt"))]
    best = max(scores)
    if best < 0.95:
        sys.exit(f"no frame of the movie matches the {which} shot (best SSIM {best:.3f})")
    match = [score >= best - 0.01 for score in scores]
    first = match.index(True)
    last = first
    while last + 1 < len(match) and match[last + 1]:
        last += 1
    return first / fps, (last + 1) / fps
_, leaves = first_run("start")
working, _ = first_run("end")
start = max(0.0, leaves - float(os.environ["HOLD_BEFORE_TAP"]))
end = working + float(os.environ["HOLD_AT_END"])
if end <= start:
    sys.exit(f"the working chat ({working:.2f} s) comes before Needs You is left ({leaves:.2f} s)")
print(f"{start:.2f} {end:.2f}")
') || fail "could not find the cut in $MOV"
note "cut: from ${CUT_START} s to ${CUT_END} s of the movie"
python3 -c "import sys; sys.exit(0 if 0 < $CUT_END - $CUT_START < $MAX_SECONDS else 1)" \
  || fail "the walk runs from $CUT_START s to $CUT_END s; the GIF must be under $MAX_SECONDS s"

# The recorder writes a frame only when the screen changes, so a still screen is one frame
# that lasts seconds. `fps` first makes a frame at every step, then `trim` cuts on them. An
# input seek (`-ss`, `-t`), or a `trim` before `fps`, skipped the still Needs You frame and
# let the home screen after the app's exit into the GIF.
FILTER="fps=$FPS,trim=start=$CUT_START:end=$CUT_END,setpts=PTS-STARTPTS"
FILTER+=",scale=$WIDTH:-1:flags=lanczos,split[a][b]"
FILTER+=";[a]palettegen=stats_mode=diff[p]"
FILTER+=";[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
ffmpeg -v error -y -i "$MOV" -vf "$FILTER" -loop 0 "$GIF"

SECONDS_LONG="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$GIF")"
BYTES="$(stat -f %z "$GIF")"
note "GIF: ${SECONDS_LONG} s, ${BYTES} bytes"
python3 -c "import sys; sys.exit(0 if float('$SECONDS_LONG') < $MAX_SECONDS else 1)" \
  || fail "$GIF is ${SECONDS_LONG} s, over $MAX_SECONDS s"
[ "$BYTES" -lt "$MAX_BYTES" ] || fail "$GIF is $BYTES bytes, over $MAX_BYTES"

# Every frame as a PNG, to read before the GIF is committed.
ffmpeg -v error -i "$GIF" -fps_mode passthrough "$WORK/frames/%03d.png"

mkdir -p "$(dirname "$TARGET")"
cp "$GIF" "$TARGET"
note "wrote $TARGET; its frames are in $WORK/frames"

#!/usr/bin/env bash
#
# Record the README's demo GIF, docs/readme/demo.gif.
#
#   scripts/demo-gif.sh <udid>   record on that simulator, an iPhone that is booted
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
# 2. It starts `xcrun simctl io <udid> recordVideo` and notes the time it started.
# 3. scripts/look.sh walks the flow in dark appearance. Its `shot:start` and `shot:end`
#    steps mark where the GIF begins and ends.
# 4. It stops the recorder, reads the two shots' times from look.sh's attachment manifest,
#    and cuts the video between them. So the build before the walk and the app's exit after
#    it are not in the GIF, and no trim point is typed in by hand.
# 5. ffmpeg turns the cut into a GIF with its own palette. It fails over 15 s or 5 MB.
#
# The video, the shots and a copy of every GIF frame go to .build-logs/demo-gif/, which git
# ignores. Read the frames before you commit a new GIF: the flow must be right and nothing
# private may show.
#
# Run it through the gate locks, which also boot the device:
#
#   ~/.claude/tools/gatelocks.py run --repo "$PWD" --pool "Driverr iPhone 17" -- \
#     scripts/demo-gif.sh {udid}
#
# It needs ffmpeg and ffprobe on PATH.

set -euo pipefail

colour() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
note() { colour "36" "==> $*"; }
fail() {
  colour "31" "error: $*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") fail "name the simulator: scripts/demo-gif.sh <udid> (see --help)" ;;
esac
UDID="$1"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v ffmpeg >/dev/null || fail "ffmpeg is not on PATH"
command -v ffprobe >/dev/null || fail "ffprobe is not on PATH"

STATE="$(xcrun simctl list -j devices | UDID="$UDID" python3 -c '
import json, os, sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["udid"] == os.environ["UDID"]:
            print(d["state"])
')"
[ "$STATE" = "Booted" ] || fail "simulator $UDID is '${STATE:-not found}', not Booted"

# The limits the README asks for, and the GIF's width in pixels.
MAX_SECONDS=15
MAX_BYTES=$((5 * 1024 * 1024))
WIDTH=360
FPS=12

WORK="$REPO_ROOT/.build-logs/demo-gif"
rm -rf "$WORK"
mkdir -p "$WORK/frames"
MOV="$WORK/demo.mov"
SHOTS="$WORK/shots"
GIF="$WORK/demo.gif"
TARGET="$REPO_ROOT/docs/readme/demo.gif"

# The walk. `shot:start` is on Needs You after it has settled, and `shot:end` is a moment
# after the chat says the agent is working again.
STEPS='tap:hosts.row,wait:session.needsYou,sleep:1.5,shot:start,sleep:2'
STEPS+=',tap:session.blockedPane|needs a decision'
STEPS+=',wait:pane.chat.turn.pending.chip.Approve,sleep:2'
STEPS+=',tap:pane.chat.turn.pending.chip.Approve'
STEPS+=',wait:pane.chat.activity|working,sleep:2.5,shot:end'
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
RECORD_START="$(python3 -c 'import time; print(time.time())')"

scripts/look.sh --simulator-id "$UDID" --dark --args "$ARGS" --steps "$STEPS" --out "$SHOTS" \
  || fail "the walk failed; the shots are in $SHOTS"
stop_recorder

# Where `start` and `end` fall in the movie, from the attachment times in look.sh's manifest.
read -r CUT_START CUT_LENGTH < <(SHOTS="$SHOTS" RECORD_START="$RECORD_START" python3 -c '
import json, os, sys
times = {}
for test in json.load(open(os.path.join(os.environ["SHOTS"], "manifest.json"))):
    for a in test.get("attachments", []):
        name = (a.get("suggestedHumanReadableName") or "").split("_")[0]
        times[name.split("-", 1)[-1]] = float(a["timestamp"])
if "start" not in times or "end" not in times:
    sys.exit("the manifest has no start or end shot: " + ", ".join(sorted(times)))
start = times["start"] - float(os.environ["RECORD_START"])
print(f"{start:.2f} {times['end'] - times['start']:.2f}")
') || fail "could not read the shot times from $SHOTS/manifest.json"
note "cut: from ${CUT_START} s, ${CUT_LENGTH} s long"
python3 -c "import sys; sys.exit(0 if 0 < $CUT_LENGTH <= $MAX_SECONDS else 1)" \
  || fail "the walk is ${CUT_LENGTH} s between its shots; the GIF must be 0 to $MAX_SECONDS s"

FILTER="fps=$FPS,scale=$WIDTH:-1:flags=lanczos,split[a][b]"
FILTER+=";[a]palettegen=stats_mode=diff[p]"
FILTER+=";[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
ffmpeg -v error -y -ss "$CUT_START" -t "$CUT_LENGTH" -i "$MOV" -vf "$FILTER" -loop 0 "$GIF"

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

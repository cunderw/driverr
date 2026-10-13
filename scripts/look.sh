#!/usr/bin/env bash
#
# Drive the app on Driverr's simulator and hand back screenshots to look at.
#
# It generates a throwaway XCUITest from a step list, runs it, exports the
# attachments under readable names, deletes the generated file, and prints a
# directory of PNGs in order.
#
# It is a *looking* tool, not a gate. It asserts nothing, and a step that finds
# nothing still takes a screenshot — a picture of the wrong screen is the answer
# to "why didn't that work".
#
# Usage:
#   scripts/look.sh
#   scripts/look.sh --dark
#   scripts/look.sh --kind ipad
#   scripts/look.sh --simulator-id <udid>
#   scripts/look.sh --args '-uiTestingBoundedTranscript -uiTestingSlowTranscript'
#   scripts/look.sh --steps 'tap:hosts.row,shot:hosts,swipe:down,shot:scrolled'
#   scripts/look.sh --out /tmp/shots
#
# With no option the script connects, opens the chat and shoots. `--kind` takes `iphone`
# (the default), `ipad` or `iphone-max`. `--simulator-id <udid>` uses that simulator,
# whatever `--kind` says.
#
# `--out <directory>` is where the PNGs go. A relative path is read from the
# repo root. The script deletes and recreates the directory on every run, and
# writes a `.look-sh-output` marker file in it. It deletes an existing directory
# only if the directory is empty or holds that marker. For any other existing
# path it stops before the build and names the path, and you remove it or pick
# another. It never accepts `/`, your home directory or the repo root. Without
# `--out` the PNGs go to a new `.build-logs/look-<timestamp>` directory.
#
# `--kind` picks the simulator. `iphone` is `Driverr iPhone 17` and is the default, `ipad`
# is `Driverr iPad`, and `iphone-max` is `Driverr iPhone 17 Pro Max`. The environment
# variable `DRIVERR_LOOK_KIND` sets the default `--kind`, and the flag wins over it.
#
# `--simulator-id <udid>` names the simulator itself and wins over `--kind`. The udid must
# be in `xcrun simctl list devices available`, in either case, or the script stops before
# the build and names it. Use it for a simulator you hold yourself, such as a second copy
# of a named one. With it the script does not look for another run, because the caller
# that names a simulator is taken to hold that simulator and this checkout. Without it
# the script refuses to start while an `xcodebuild` or a `swiftpm-testing-helper` is
# live: one run per checkout and per simulator (CONTRIBUTING.md, "Two runs in one
# checkout or on one simulator give a wrong result").
#
# `--dark` and `--light` set the simulator's appearance before the run. The
# device is booted first if it is not already, because `xcrun simctl ui <udid>
# appearance <value>` fails on a shut-down device; the value is then read back
# with `xcrun simctl ui <udid> appearance` and the run fails, naming the udid
# and the value read, if it does not match what was asked for. The appearance
# the device was found in is restored when the script exits.
#
# Steps are comma-separated and run in order:
#   tap:<identifier>     wait for it, then tap it
#   type:<text>          type into whatever has focus
#   keys:<text>          tap the software keyboard's key for each character, or
#                         type the text if the keyboard lacks one of them. Use it
#                         for a secure field: `type:` into one leaves the
#                         terminal's key row out of every later shot on the iPad
#   swipe:up|down        swipe the chat (falls back to the whole app)
#   wait:<identifier>    wait for it without tapping
#   sleep:<seconds>      let an animation or a fetch settle
#   shot:<name>          capture the screen under that name
#   rotate:landscapeLeft|landscapeRight|portrait
#                         set the device orientation and wait for the window's
#                         own aspect ratio to confirm the rotation actually
#                         happened, not just that the request was sent. The run
#                         leaves the device in portrait however it ends — the
#                         orientation outlives the process and the next tier
#                         inherits it
#   focus:<identifier>   tap the identifier, then wait for a software keyboard
#                         to come up
#   press:<identifier>[:<seconds>]
#                         hold a finger on the element for that long, 1.0 s by
#                         default. SwiftTerm arms the terminal's selection off a
#                         `UILongPressGestureRecognizer` at 0.7 s, and no other
#                         verb here can express a hold
#   doubletap:<identifier>
#                         two taps in one place. SwiftTerm selects a word on a
#                         double tap, and this is *not* two `tap:` steps: those
#                         are two separate single taps and each takes the
#                         single-tap path
#   drag:<identifier>     press for 0.6 s, then drag from a quarter to three
#                         quarters of the element's height — downward, which on
#                         a terminal is the scroll-back gesture and is also how
#                         a selection is extended once one is armed. Distinct
#                         from `swipe:`, a flick clipped to the chat's visible
#                         region that cannot hold before it moves
#   swipeleft:<identifier>
#                         swipe the element left to reveal its trailing swipe
#                         actions. If the next step is a `wait:` or `tap:`
#                         whose element has not appeared after a short settle,
#                         it swipes once more
#   home                  press Home and wait for the app to background, so the
#                         next shot catches what SpringBoard draws (a Live
#                         Activity's Lock Screen card, the compact island).
#                         Takes no value, so write `home`
#   activate              bring the app back to the foreground after `home`, so a
#                         walk can photograph the re-layout a resume produces.
#                         Takes no value, so write `activate`
#   back:                 tap the navigation bar's back button, which carries no
#                         identifier of its own (the value after the colon is
#                         ignored, so write `back:`)
#
# A comma always ends a step and cannot be escaped: `type:a,b` types `a`, and
# `b` is read as a verb with no value and dropped without a message. A colon in
# a value is fine, because only the first colon splits the verb from the value.
# Any Unicode is fine in a value, so a pane's glyphs can be typed:
#
#   tap:terminal.view,type:⏺ Done,shot:typed
#
# `tap:` and `wait:` take an optional label filter after a `|`, which picks
# the first element whose label contains that text rather than the first
# element with that identifier:
#
#   tap:session.blockedPane|needs a decision
#
# It exists because several rows share one identifier and `firstMatch` picks
# whichever the app put first — for blocked panes that is whichever went
# blocked most recently, so the pane you meant is not reliably the one you get.
#
# `-uiTesting` and `-uiTestingSeedHost` are always passed; `--args` adds to them.
# The fixture flags are in `Driverr/AppEnvironment.swift` —
# `-uiTestingSlowTranscript` in particular, which makes the fake transcript
# arrive *after* the view is on screen, the way a real host's does.

set -uo pipefail

# The build tool sends error reports and usage metrics to Sentry unless told not to. See
# README.md, "Building it".
export XCODEBUILDMCP_SENTRY_DISABLED=true

# The script's own path, made absolute before the `cd`, because `--help` reads the header from
# it and a relative `${BASH_SOURCE[0]}` stops resolving once the directory changes.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" || exit 1
cd "$(dirname "$SCRIPT_PATH")/.." || exit 1

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# The default walk: the seeded host through to a blocked pane's chat, which is
# the screen nearly every question about this app turns out to be about.
DEFAULT_STEPS='tap:hosts.row,tap:connect.password,keys:hunter2,tap:connect.connect,tap:hostkey.trust,wait:session.workspace,tap:session.blockedPane,wait:pane.chat,sleep:3,shot:chat'

STEPS="$DEFAULT_STEPS"
EXTRA_ARGS=""
APPEARANCE=""
OUT=""
KIND="${DRIVERR_LOOK_KIND:-iphone}"
SIMULATOR_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    # Each option that takes a value checks that one follows. `shift 2` with one argument
    # left fails and shifts nothing, so without the check a trailing `--out` loops forever.
    --steps) [ $# -ge 2 ] || die "$1 needs a value"; STEPS="$2"; shift 2 ;;
    --args) [ $# -ge 2 ] || die "$1 needs a value"; EXTRA_ARGS="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || die "$1 needs a value"; OUT="$2"; shift 2 ;;
    --kind) [ $# -ge 2 ] || die "$1 needs a value"; KIND="$2"; shift 2 ;;
    # An empty value stops here and does not fall back to the `--kind` device: the caller
    # asked for one simulator, and the fallback would run on another.
    --simulator-id)
      [ -n "${2:-}" ] || die "--simulator-id needs a udid (xcrun simctl list devices available)"
      SIMULATOR_ID="$2"; shift 2
      ;;
    --dark) APPEARANCE="dark"; shift ;;
    --light) APPEARANCE="light"; shift ;;
    # Print every leading comment line, stopping at the first blank line that
    # separates the header from the script body. A hardcoded line range would
    # truncate the help whenever the header grows.
    -h|--help)
      awk 'NR==1{next} /^#/{print; next} {exit}' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
done

# After the option loop, so `--help` works on a machine that lacks them. Stops with the README
# section that lists what to install, and not with a bare "command not found" mid-run.
for TOOL in npx python3 xcrun; do
  command -v "$TOOL" >/dev/null 2>&1 \
    || die "$TOOL is not on PATH. README.md, \"Building it\", lists what to install"
done

[ -n "$STEPS" ] || die "--steps cannot be empty"

# The simulator is worked out here, before anything is generated or built, so a wrong
# udid or a missing device costs nothing. `--simulator-id` wins over `--kind`, so with it
# the kind is not read at all, and a `--kind` or `DRIVERR_LOOK_KIND` that names nothing
# does not stop the run. `DEVICE` is then that simulator's own name, for the messages
# below. The udid is matched without regard to case and taken as simctl spells it.
if [ -n "$SIMULATOR_ID" ]; then
  MATCH="$(xcrun simctl list devices available --json \
    | SIMULATOR_ID="$SIMULATOR_ID" python3 -c '
import json, os, sys
asked = os.environ["SIMULATOR_ID"].upper()
hits = [d for rt in json.load(sys.stdin)["devices"].values()
        for d in rt if d["udid"].upper() == asked]
if hits:
    print(hits[0]["udid"])
    print(hits[0]["name"])
')"
  [ -n "$MATCH" ] || die "--simulator-id '$SIMULATOR_ID' is not an available simulator (xcrun simctl list devices available)"
  { IFS= read -r UDID; IFS= read -r DEVICE; } <<EOF
$MATCH
EOF
else
  case "$KIND" in
    iphone)     DEVICE="Driverr iPhone 17" ;;
    ipad)       DEVICE="Driverr iPad" ;;
    iphone-max) DEVICE="Driverr iPhone 17 Pro Max" ;;
    *) die "unknown --kind '$KIND' (iphone|ipad|iphone-max)" ;;
  esac
  UDID="$(xcrun simctl list devices available --json \
    | DEVICE="$DEVICE" python3 -c '
import json, os, sys
name = os.environ["DEVICE"]
hits = [d["udid"] for rt in json.load(sys.stdin)["devices"].values()
        for d in rt if d["name"] == name]
print(hits[0] if len(hits) == 1 else "")
')"
  [ -n "$UDID" ] || die "no single available simulator named '$DEVICE' — create it with simctl, or check for duplicates across runtimes"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-.build-logs/look-$STAMP}"

# `$OUT` is deleted and recreated before the export, so delete only what this script
# made: an existing directory must be empty or hold the marker written below. Checked
# here, before the build, so a refusal costs nothing.
MARKER=".look-sh-output"
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  OUT_REAL="$(CDPATH= cd -- "$OUT" 2>/dev/null && pwd -P)"
  [ -n "$OUT_REAL" ] \
    || die "--out '$OUT' exists and is not a directory the script can read; remove it or pick another"
  HOME_REAL=""
  [ -z "${HOME:-}" ] || HOME_REAL="$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd -P)"
  case "$OUT_REAL" in
    /|"$HOME_REAL"|"$(pwd -P)")
      die "--out '$OUT' cannot be /, your home directory or the repo root" ;;
  esac
  if [ ! -e "$OUT_REAL/$MARKER" ]; then
    FOUND="$(ls -A "$OUT_REAL" 2>/dev/null)" \
      || die "--out '$OUT' cannot be listed; remove it or pick another"
    [ -z "$FOUND" ] \
      || die "--out '$OUT' is not empty and has no $MARKER file, so this script did not make it; remove it or pick another"
  fi
fi

# **One run per checkout and per simulator.** A second run in one checkout shares its
# DerivedData, and a second run on one simulator installs over the first; either way a
# run can execute a bundle the other is mid-way through rebuilding, and the failure's line
# number does not match the source.
#
# The script takes no lock. Without `--simulator-id` it refuses to start while any
# `xcodebuild` or `swiftpm-testing-helper` is live, on any project, because it cannot tell
# which checkout or simulator that run holds. `pgrep -x` matches the process name exactly,
# so it cannot match its own invocation. With `--simulator-id` the caller named the
# simulator and is taken to hold it and this checkout, so the check is skipped.
if [ -z "$SIMULATOR_ID" ]; then
  if pgrep -x xcodebuild >/dev/null 2>&1 \
    || pgrep -x swiftpm-testing-helper >/dev/null 2>&1; then
    die "an xcodebuild or swiftpm-testing-helper run is live. One run per checkout and per simulator (CONTRIBUTING.md, \"Two runs in one checkout or on one simulator give a wrong result\"). Wait for it to finish (pgrep -xl xcodebuild), or pass --simulator-id <udid> for a simulator you hold"
  fi
fi

CLASS="LookUITests"
GENERATED="DriverrUITests/${CLASS}.swift"
[ -e "$GENERATED" ] && die "$GENERATED already exists — a previous run left it behind; delete it and retry"

# Deleted however this exits. A generated class left in the tree would join the
# next `simulator test` run as a test that asserts nothing.
# Set once the device's appearance has been read, so `cleanup` can put it back.
# Declared here because `set -u` is on and the trap below can fire before it is
# worked out.
PRIOR_APPEARANCE=""

cleanup() {
  rm -f "$GENERATED"
  # Leave the device in the appearance it was found in. Best-effort on purpose:
  # this runs from a trap, and a failure here would mask the run's own exit
  # status, which is the thing the caller is waiting on.
  if [ -n "$PRIOR_APPEARANCE" ] && [ "$PRIOR_APPEARANCE" != "$APPEARANCE" ]; then
    xcrun simctl ui "$UDID" appearance "$PRIOR_APPEARANCE" >/dev/null 2>&1 || true
  fi
}
# `cleanup` runs on EXIT only, and a signal exits. A handler that only returned would let
# the script go on after Ctrl-C with the generated class already deleted.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# **A quoted heredoc, with the step list substituted afterwards.** The two other
# routes both fail silently, which is the worst way for a looking tool to fail:
#
# - passing the steps as `TEST_RUNNER_*` build settings — extra arguments reach
#   `xcodebuild` through a word-split string, so a value containing a space
#   (`--args` nearly always has one) breaks apart and the test walks nowhere;
# - an *unquoted* heredoc, which would let the shell expand `\(...)` string
#   interpolation and `$0` in the Swift body below.
cat > "$GENERATED" <<'SWIFT'
import UIKit
import XCTest

/// Generated by `scripts/look.sh` and deleted when it finishes. Do not commit.
///
/// It drives the app through a step list and photographs it. Nothing here
/// asserts anything: the point is to *look*, and a picture of the wrong screen
/// answers "why didn't that work" better than a failed assertion does.
@MainActor
final class LookUITests: XCTestCase {
  func testLook() {
    let steps = __STEPS__.split(separator: ",").map(String.init)
    let extra = __ARGS__.split(separator: " ").map(String.init).filter { !$0.isEmpty }

    XCUIDevice.shared.orientation = .portrait
    // **And put it back on the way out, because the device's orientation outlives this
    // process** — `CLAUDE.md`'s "simulator orientation is not test state". A look that ends
    // on a `rotate:` verb would otherwise leave the device in landscape for whatever runs
    // next, and the hosted probes in the *unit* tier then inherit the scene's side insets and
    // fail on an unmodified tree.
    // `defer` rather than `tearDown`, which is nonisolated and warns under strict concurrency.
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments += ["-uiTesting", "-uiTestingSeedHost"] + extra
    app.launch()

    var shotIndex = 0
    for (index, step) in steps.enumerated() {
      let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
      guard let verb = parts.first, !verb.isEmpty else { continue }
      // `back`, `home` and `activate` take no value, and `split` drops the empty half — so a
      // missing value is an empty string rather than a reason to skip the step.
      //
      // **A value-less verb missing from this list is silently skipped**, and the run then
      // photographs a walk that never took that step — which reads as the app not doing the
      // thing rather than as the tool not asking for it. Add the verb here in the same edit
      // that adds its `case` below.
      let value = parts.count > 1 ? parts[1] : ""
      guard !value.isEmpty || verb == "back" || verb == "home" || verb == "activate"
      else { continue }

      switch verb {
      case "tap":
        let element = find(app, value)
        if element.waitForExistence(timeout: 20) {
          element.tap()
        } else {
          // Photographed rather than failed: seeing the screen it *did* reach is
          // the whole reason this tool exists.
          shotIndex += 1
          attach("\(pad(shotIndex))-missing-\(value)")
          print("look: no '\(value)' — carried on")
        }
      case "wait":
        _ = find(app, value).waitForExistence(timeout: 20)
      case "type":
        app.typeText(value)
      case "keys":
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        let keys = value.map { app.keyboards.keys[String($0)] }
        if keys.allSatisfy(\.exists) {
          for key in keys { key.tap() }
        } else {
          print("look: the keyboard lacks a key of '\(value)' — typed it instead")
          app.typeText(value)
        }
      case "swipe":
        let chat = find(app, "pane.chat")
        let target: XCUIElement = chat.exists ? chat : app
        // **A swipe on the chat with the keyboard up lands on the keys and scrolls nothing.**
        // The scroll view's frame runs the whole way down the window, so the centre that
        // `swipeUp`/`swipeDown` start from is at or below the top of the keyboard. Measured on
        // `Driverr iPhone 17`: chat (0, 216.7, 402, 657.3) against a keyboard starting at 590.
        // A look pass that photographs an inert gesture is one of the three ways `CLAUDE.md`
        // says a capture proves nothing, so the drag is clipped to the visible conversation.
        let frame = target.frame
        let keyboardTop =
          app.keyboards.count > 0 ? app.keyboards.firstMatch.frame.minY : frame.maxY
        let visible = min(frame.maxY, keyboardTop) - frame.minY
        // 40 pt, not a comfortable scrolling distance: the landscape collapsed state leaves
        // the conversation about 46 pt tall, and a short drag inside it is still a better
        // gesture than a swipe whose centre is on the keys.
        if visible > 40, visible < frame.height - 1 {
          let near = target.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: (visible * 0.15) / frame.height))
          let far = target.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: (visible * 0.85) / frame.height))
          if value == "up" {
            far.press(forDuration: 0.1, thenDragTo: near)
          } else {
            near.press(forDuration: 0.1, thenDragTo: far)
          }
        } else if value == "up" {
          target.swipeUp()
        } else {
          target.swipeDown()
        }
      case "sleep":
        usleep(UInt32((Double(value) ?? 1) * 1_000_000))
      case "shot":
        shotIndex += 1
        attach("\(pad(shotIndex))-\(value)")
      case "rotate":
        rotate(app, value)
      case "focus":
        focus(app, value)
      case "press":
        press(app, value)
      case "doubletap":
        doubleTap(app, value)
      case "drag":
        drag(app, value)
      case "swipeleft":
        swipeLeft(app, value, revealing: revealedBy(steps, after: index))
      case "home":
        goHome(app)
      case "activate":
        activate(app)
      case "back":
        back(app)
      default:
        print("look: unknown step '\(step)'")
      }
    }
  }

  /// Taps the navigation bar's back button, which is the phone's way out of the
  /// pane scene and carries no identifier of its own — so it is
  /// found by position rather than by name. `firstMatch` on the bar rather than
  /// on every button in the app: a stack can hold more than one bar in the tree,
  /// and `find` matches identifiers only.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`.
  private func back(_ app: XCUIApplication) {
    let button = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
    if button.waitForExistence(timeout: 20) {
      button.tap()
    } else {
      attach("missing-back-button")
      print("look: no back button in the navigation bar — carried on")
    }
  }

  /// Sets the device orientation, then waits for the *window's own frame* to
  /// confirm the rotation actually reached the interface rather than just the
  /// device — copying `PaneSwitchUITests.rotateToLandscape`'s assertion shape.
  ///
  /// `CLAUDE.md`'s wedged-device tell is a missing "Interface orientation
  /// changed" automation log line, but a generated `look.sh` class has no way
  /// to read that log — so the window's aspect ratio is the tell available
  /// here: a wedged simulator logs the device-orientation change and then
  /// never resizes the window at all.
  ///
  /// This is the one verb that fails outright (`XCTFail`, not a photographed
  /// miss) rather than carrying on: every later `shot:` in a wedged run would
  /// be silently portrait, which reads as an app layout bug rather
  /// than the simulator problem it is.
  private func rotate(_ app: XCUIApplication, _ value: String) {
    let orientation: UIDeviceOrientation
    switch value {
    case "landscapeLeft": orientation = .landscapeLeft
    case "landscapeRight": orientation = .landscapeRight
    case "portrait": orientation = .portrait
    default:
      print("look: unknown rotate target '\(value)' (landscapeLeft|landscapeRight|portrait)")
      return
    }

    XCUIDevice.shared.orientation = orientation
    let window = app.windows.firstMatch
    let wantsLandscape = orientation != .portrait
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let frame = window.frame
      let isLandscape = frame.width > frame.height
      if isLandscape == wantsLandscape && frame.width > 0 && frame.height > 0 {
        // A short settle past the frame flip, for any in-flight rotation animation.
        usleep(400_000)
        return
      }
      _ = window.waitForExistence(timeout: 0.2)
    }

    let frame = window.frame
    attach("rotate-failed-\(value)")
    XCTFail(
      "The scene never rotated to '\(value)' — the window is still \(frame). That is the "
        + "simulator and not the app: erase this device (`xcrun simctl erase <udid>`) "
        + "and run again."
    )
  }

  /// Taps the identifier, then waits for a software keyboard to come up. On
  /// timeout this carries on (like every other verb but `rotate`) rather than
  /// failing — a hardware keyboard connected to the simulator is a common,
  /// harmless reason for `app.keyboards.count` to stay 0.
  private func focus(_ app: XCUIApplication, _ value: String) {
    let element = find(app, value)
    guard element.waitForExistence(timeout: 20) else {
      attach("missing-\(value)")
      print("look: no '\(value)' to focus — carried on")
      return
    }
    element.tap()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && app.keyboards.count == 0 { usleep(200_000) }
    if app.keyboards.count == 0 {
      attach("missing-keyboard-\(value)")
      print(
        "look: no keyboard came up after focusing '\(value)' — carried on. Likely cause: a "
          + "hardware keyboard is connected to the simulator (Simulator's I/O > Keyboard, or "
          + "XcodeBuildMCP's toggle_connect_hardware_keyboard)."
      )
    }
  }

  /// Holds a finger on the element — `press:<identifier>[:<seconds>]`, 1.0 s by default.
  ///
  /// **The gesture no other verb can make.** `tap:` lifts immediately, and SwiftTerm arms
  /// the terminal's text selection off a `UILongPressGestureRecognizer` whose
  /// `minimumPressDuration` is 0.7 s (`iOS/iOSTerminalView.swift`, `setupGestures`). Without
  /// this verb no capture can show what a long press on the terminal does.
  ///
  /// The duration is the last `:`-separated component *only when it parses as a number*,
  /// so an identifier carrying a colon, or a `|label` filter carrying one, is still passed
  /// whole to `find`.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`.
  private func press(_ app: XCUIApplication, _ value: String) {
    var identifier = value
    var seconds = 1.0
    if let cut = value.lastIndex(of: ":"), let parsed = Double(value[value.index(after: cut)...]) {
      identifier = String(value[..<cut])
      seconds = parsed
    }
    let element = find(app, identifier)
    guard element.waitForExistence(timeout: 20) else {
      attach("missing-\(identifier)")
      print("look: no '\(identifier)' to press — carried on")
      return
    }
    element.press(forDuration: seconds)
  }

  /// Two taps in one place — `doubletap:<identifier>`.
  ///
  /// **Not the same as two `tap:` steps.** Those are two independent single taps, each
  /// taking the single-tap path; a double tap is its own recogniser. In SwiftTerm the two
  /// go to different places entirely — `singleTap` reports a mouse click or offers the
  /// context menu, `doubleTap` selects a word and turns on the selection pan gesture.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`.
  private func doubleTap(_ app: XCUIApplication, _ value: String) {
    let element = find(app, value)
    guard element.waitForExistence(timeout: 20) else {
      attach("missing-\(value)")
      print("look: no '\(value)' to double tap — carried on")
      return
    }
    element.doubleTap()
  }

  /// Swipes the element left — `swipeleft:<identifier>` — to reveal a row's trailing
  /// swipe actions.
  ///
  /// **One settle and one retry.** A swipe made while the list is still settling after
  /// launch can land and reveal nothing, so when the next step names an element (a
  /// `wait:` or `tap:`) and it has not appeared within 3 s, the row is swiped once more.
  /// Only once: a second miss is photographed by the next step like any other.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`.
  private func swipeLeft(_ app: XCUIApplication, _ value: String, revealing next: String?) {
    let element = find(app, value)
    guard element.waitForExistence(timeout: 20) else {
      attach("missing-\(value)")
      print("look: no '\(value)' to swipe — carried on")
      return
    }
    element.swipeLeft()
    if let next, !find(app, next).waitForExistence(timeout: 3) {
      print("look: no '\(next)' after swiping '\(value)' — swiping once more")
      element.swipeLeft()
    }
  }

  /// The identifier the step after `index` waits for or taps, if it is one of those.
  private func revealedBy(_ steps: [String], after index: Int) -> String? {
    guard index + 1 < steps.count else { return nil }
    let parts = steps[index + 1].split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0] == "wait" || parts[0] == "tap" else { return nil }
    return parts[1]
  }

  /// Presses, then drags downward inside the element — `drag:<identifier>`.
  ///
  /// **A held drag, not a flick.** `swipe:` is a fast gesture clipped to the chat's visible
  /// region and it cannot hold before it moves; a terminal reads a held drag as scrollback
  /// or as a selection extension depending on state, and this verb shows which one it
  /// does. **0.6 s is deliberately under SwiftTerm's own 0.7 s long-press threshold**
  /// (`setupGestures`, `minimumPressDuration`): the hold is there to let a pan recogniser
  /// claim the touch, and going over 0.7 s would arm a selection first and photograph a
  /// different gesture than the one asked for. Use `press:` when a long press is what you
  /// want.
  ///
  /// Downward, from a quarter of the height to three quarters: on a scroll view that walks
  /// *back* through history.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`.
  private func drag(_ app: XCUIApplication, _ value: String) {
    let element = find(app, value)
    guard element.waitForExistence(timeout: 20) else {
      attach("missing-\(value)")
      print("look: no '\(value)' to drag — carried on")
      return
    }
    let from = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
    let to = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
    from.press(forDuration: 0.6, thenDragTo: to)
  }

  /// Presses Home and waits for the app to leave the foreground.
  ///
  /// **The one way to photograph a Live Activity from here.** The Lock
  /// Screen card and the compact Dynamic Island presentation are drawn by
  /// SpringBoard, not by the app, so `XCUIScreen.main.screenshot()` has to be
  /// taken on a frame the app is not filling. `XCUIScreen.main` keeps working
  /// after the app backgrounds — it reads the whole display rather than the
  /// app's own layer tree, which is also why `XCUIApplication.screenshot()`
  /// cannot be used here at all.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`:
  /// a run that stayed in the foreground still hands back the frame it got, and
  /// a frame that is plainly the app is a readable answer.
  private func goHome(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && app.state == .runningForeground { usleep(200_000) }
    if app.state == .runningForeground {
      print("look: the app is still in the foreground after Home — carried on")
    }
    // SpringBoard needs a moment to draw the Home Screen and whatever the app
    // left on it. Without this the next `shot:` catches the app's own last
    // frame mid-dismissal, which reads as the card never having appeared.
    usleep(2_500_000)
  }

  /// Brings the app back to the foreground, which is the other half of `home`.
  ///
  /// **The re-layout a resume produces is one no other verb walks.** Going away and coming
  /// back takes the scene through `inactive` and `background` and out again, the app-switcher
  /// snapshot is taken and restored, and the safe-area insets and the keyboard are both
  /// re-presented against a scroll view that was already built. A layout defect can show on
  /// that transition and on no other, so a tool that can only leave cannot photograph it.
  ///
  /// `app.activate()` rather than tapping the app's icon on the Home Screen: the icon's
  /// position is a fact about SpringBoard's grid rather than about Driverr, and a tap that
  /// misses launches nothing and says nothing.
  ///
  /// Photographed rather than failed on a miss, like every verb but `rotate`: a run that never
  /// came back still hands back the frame it got, and a Home Screen is a readable answer.
  private func activate(_ app: XCUIApplication) {
    app.activate()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && app.state != .runningForeground { usleep(200_000) }
    if app.state != .runningForeground {
      print("look: the app never came back to the foreground — carried on")
    }
    // The resumed layout passes run after the process is foreground, so a `shot:` taken the
    // instant `state` flips catches the app-switcher snapshot rather than the resumed frame.
    // Short on purpose — a walk that wants the settled state asks for it with its own
    // `sleep:`, and this one is only about not photographing the snapshot.
    usleep(600_000)
  }

  /// Zero-padded so the exported files sort in the order they were taken.
  private func pad(_ index: Int) -> String {
    index < 10 ? "0\(index)" : "\(index)"
  }

  /// `identifier`, or `identifier|label substring` to pick a row out of several
  /// that share one identifier.
  ///
  /// `firstMatch` alone picks whichever element the app happens to have put
  /// first, which for the blocked-pane rows is whichever agent went blocked most
  /// recently — so the pane a step means is not reliably the one it gets.
  /// The filter is a `CONTAINS` predicate on the label, because a row's label is
  /// a whole sentence and matching it exactly would mean copying one.
  private func find(_ app: XCUIApplication, _ value: String) -> XCUIElement {
    let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
    let query = app.descendants(matching: .any).matching(identifier: parts[0])
    guard parts.count == 2 else { return query.firstMatch }
    return query.matching(NSPredicate(format: "label CONTAINS %@", parts[1])).firstMatch
  }

  /// `XCUIScreen.main.screenshot()`, never `app.screenshot()` — `CLAUDE.md`
  /// records the latter compositing a rotated scene at its pre-rotation width,
  /// leaving a black band that is an artifact of the capture rather than a bug.
  private func attach(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
SWIFT

# **Swift string literals, not JSON ones.** `json.dumps` escapes every
# non-ASCII character as `\uXXXX`, which Swift rejects: it spells the escape
# `\u{XXXX}`, a character above U+FFFF becomes a surrogate pair, and JSON's `\b`
# and `\f` are not Swift escapes at all. The whole step list is one literal, so
# a single `type:⏺` would break the build for every verb in it.
STEPS="$STEPS" EXTRA_ARGS="$EXTRA_ARGS" GENERATED="$GENERATED" python3 <<'PY'
import os

def swift_literal(s):
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\\" or ch == '"':
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif 0x20 <= code <= 0x7E:
            out.append(ch)
        else:
            out.append("\\u{%X}" % code)
    return '"' + "".join(out) + '"'

path = os.environ["GENERATED"]
source = open(path, encoding="utf-8").read()
source = source.replace("__STEPS__", swift_literal(os.environ["STEPS"]))
source = source.replace("__ARGS__", swift_literal(os.environ["EXTRA_ARGS"]))
open(path, "w", encoding="utf-8").write(source)
PY

# Parse the generated class before handing it to xcodebuild, so a literal the
# helper above gets wrong fails here, in a second, naming the file, rather than
# as one error buried in a build log.
xcrun swiftc -parse "$GENERATED" \
  || die "the generated $GENERATED does not parse; the step list or --args produced an invalid Swift literal"

device_state() {
  xcrun simctl list devices --json | UDID="$UDID" python3 -c '
import json, os, sys
udid = os.environ["UDID"]
for rt in json.load(sys.stdin)["devices"].values():
    for d in rt:
        if d["udid"] == udid:
            print(d["state"])
            sys.exit(0)
print("")
'
}

# **The appearance is booted for, set unsuppressed, and read back.**
#
# `xcrun simctl ui <udid> appearance <value>` fails on a device that is not
# booted (`Unable to lookup in current state: Shutdown`). If that failure is
# discarded, `--dark` on a cold device prints `appearance: dark` and photographs
# a light-mode app, and a light capture that says dark on it reads as "dark
# verified".
#
# Reading it back is what makes the claim true rather than reported: the set can
# also fail to take on a booted device, and `xcrun simctl ui <udid> appearance`
# on a shut-down device answers `unknown` with exit 0, so neither the exit
# status alone nor the read alone is enough. The run dies on a mismatch instead
# of handing back screenshots of the wrong appearance.
if [ -n "$APPEARANCE" ]; then
  STATE="$(device_state)"
  if [ "$STATE" != "Booted" ]; then
    note "booting $DEVICE ($UDID) — it is ${STATE:-unknown}, and the appearance cannot be set on a device that is not booted"
    # The same boot XcodeBuildMCP does for the test run below, just earlier.
    npx -y xcodebuildmcp@2.7.0 simulator boot --simulator-id "$UDID" >/dev/null \
      || die "could not boot $DEVICE ($UDID) to set the appearance"
    for _ in $(seq 1 60); do
      [ "$(device_state)" = "Booted" ] && break
      sleep 1
    done
    [ "$(device_state)" = "Booted" ] \
      || die "$DEVICE ($UDID) did not reach Booted, so the appearance cannot be set"
  fi

  FOUND="$(xcrun simctl ui "$UDID" appearance 2>/dev/null | tr -d '[:space:]')"
  case "$FOUND" in light|dark) PRIOR_APPEARANCE="$FOUND" ;; esac
  note "appearance: $APPEARANCE (was ${FOUND:-unknown})"

  xcrun simctl ui "$UDID" appearance "$APPEARANCE" \
    || die "could not set the appearance to '$APPEARANCE' on $DEVICE ($UDID)"

  READ_BACK="$(xcrun simctl ui "$UDID" appearance 2>/dev/null | tr -d '[:space:]')"
  [ "$READ_BACK" = "$APPEARANCE" ] \
    || die "asked $DEVICE ($UDID) for appearance '$APPEARANCE' and it reads '${READ_BACK:-unknown}' — the screenshots would be the wrong appearance"
fi

note "walking: $STEPS"
RESULT_JSON="$(mktemp)"
# **The project is named absolutely, and the answer is checked against it.**
#
# `.xcodebuildmcp/config.yaml` gives `projectPath` as `./Driverr.xcodeproj`, and that
# relative path is resolved against a cached session default rather than against the calling
# process — so a run started in one linked worktree has been observed building and testing a
# *different* worktree's tree, intermittently, and reporting a healthy green count for
# another checkout's code. For a looking tool that is the worst possible failure: the
# screenshots are of another branch's app and look exactly like evidence.
PROJECT="$PWD/Driverr.xcodeproj"
npx -y xcodebuildmcp@2.7.0 simulator test \
  --project-path "$PROJECT" \
  --scheme Driverr \
  --simulator-id "$UDID" \
  --extra-args -only-testing:"DriverrUITests/$CLASS" \
  --output json > "$RESULT_JSON"
STATUS=$?

# The run reports its own result bundle, so there is nothing to go hunting for.
BUNDLE="$(RESULT_JSON="$RESULT_JSON" PROJECT="$PROJECT" python3 -c '
import json, os, sys
d = json.load(open(os.environ["RESULT_JSON"])).get("data", {})
asked = os.path.realpath(os.environ["PROJECT"])
got = d.get("request", {}).get("projectPath") or ""
if got and os.path.realpath(os.path.expanduser(got)) != asked:
    sys.exit("that run built " + got + ", not " + asked)
# **Expanded, because the path comes back with a literal `~` in it.** `xcresulttool` is
# handed this straight, and a shell never sees it — so an unexpanded tilde failed the export
# with nothing but "could not export", which reads like a broken result bundle rather than a
# path that was never resolved.
print(os.path.expanduser(d.get("artifacts", {}).get("xcresultPath", "")))
' 2>&1)" || die "$BUNDLE"
[ -n "$BUNDLE" ] || die "that run produced no result bundle — read $RESULT_JSON"

rm -rf "$OUT"
mkdir -p "$OUT" && : > "$OUT/$MARKER" || die "could not create $OUT"
xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$OUT" >/dev/null 2>&1 \
  || die "could not export attachments from $BUNDLE"

# `xcresulttool` names the exported files by uuid and puts the readable name in
# `manifest.json`. Renaming them is the difference between a folder you can read
# in order and one you have to cross-reference.
OUT="$OUT" python3 <<'PY'
import json, os

out = os.environ["OUT"]
manifest = os.path.join(out, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            exported = attachment.get("exportedFileName")
            readable = attachment.get("suggestedHumanReadableName") or exported or ""
            if not exported:
                continue
            # "03-chat_0_<uuid>.png" -> "03-chat.png"
            stem = readable.split("_")[0] or exported
            source = os.path.join(out, exported)
            target = os.path.join(out, stem + ".png")
            if os.path.exists(source) and not os.path.exists(target):
                os.rename(source, target)
PY

SHOTS="$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SHOTS" = "0" ]; then
  note "no screenshots — does the step list include a 'shot:' step?"
else
  note "$SHOTS screenshot(s) in $OUT"
  ls "$OUT"/*.png
fi

exit $STATUS

# Driverr — repo conventions

Native iOS/iPadOS SSH client built around [herdr](https://github.com/herdrdev/herdr).
Monorepo: SwiftUI app in `Driverr/`, shared kit in `DriverrKit/` (SwiftPM package, five
modules). `DriverrCore` holds dependency-free domain types. `DriverrSSH` confines
swift-nio-ssh, `DriverrTerm` confines SwiftTerm, `DriverrHerdr` confines herdr's wire
format, and `DriverrTranscript` reads agent session files. No backend of our own: Driverr
talks directly to the user's own machines over SSH.

**Not a config surface.** Global settings are theme, font, font size, whether a captured
pane screen wraps its long lines, and whether Driverr draws Live Activities. The last of
those is on the list because a card drawn outside the app has to be refusable from inside
it. A sixth setting still has to argue its case. Driverr is **not a paid product**. It is
described as an SSH client everywhere: herdr's own persistence covers reattachment, so
there is no mosh support and none is planned.

[`CONTRIBUTING.md`](CONTRIBUTING.md) owns the workflow: issues, labels, branches, pull
requests, the test commands, which tests to run, and the warnings check. **Read its
"Tests, and where they belong" section before you run a test or open a pull request.**
This file holds the rules and traps on top of that.

## Ground rules

- **Layering: SwiftNIO SSH types never leave `DriverrSSH`; herdr wire types never leave
  `DriverrHerdr`.** Both map to plain `DriverrCore` structs at the module boundary. This
  keeps stores testable without a live SSH connection or herdr socket, and it confines
  upstream churn to one file each. In `DriverrSSH` the only production file that may
  `import NIOSSH` is `NIOSSHTransport.swift`, which is also where every NIOSSH error is
  mapped to `AppError`. Verify with
  `grep -rn --include='*.swift' '^import NIOSSH' Driverr DriverrKit/Sources`: exactly one
  hit, `DriverrKit/Sources/DriverrSSH/NIOSSHTransport.swift`, is the passing result.
- **`DriverrTerm` must not import `DriverrSSH`.** It renders a `TerminalFeed`, a struct of
  closures over a byte stream, so a PTY channel, a herdr pane or a recorded transcript can
  drive it. The adapter is in the app target, `Driverr/TerminalFeed+PTYChannel.swift`, the
  one place allowed to know both. Test session behaviour in `TerminalSessionTests` against
  a headless SwiftTerm `Terminal`, which keeps the terminal off the expensive tier.
- **Keep `TerminalOptions(cursorStyle: .steadyBlock)` in `DriverrTerminalView`.** A
  blinking caret is an endless animation, so XCUITest never sees the app idle and every
  interaction waits out a 60 s timeout. Do not make cursor style a setting.
- **The phone authors its own `NavigationStack`, and the pane scene is pushed onto it.**
  `ContentView` branches at its root: regular width is the `NavigationSplitView`, compact
  width is a two-level stack. **Both levels are one typed path**, `PhoneStackPath.Route`
  (`.host(id)` then `.pane`), derived from `selectedHostID` and
  `TerminalPresenter.request` and resolved by one `navigationDestination(for:)` at the
  stack's root. The rule is in `DriverrCore`, so `swift test` asserts it.
  - Do not hang the pane level off a `navigationDestination(isPresented:)` inside the host
    screen. It loses the pane on a cross-host pick from the pane switcher, because the
    destination is recreated with `isPresented` already `true` and SwiftUI pushes nothing.
    `PaneSwitchUITests.testTheSwitcherListsAnotherConnectedHostAndGoesThere` catches it.
  - **On iPad, do not push from `HostDetailView`.** A second push from a split view's
    detail column pops back to the host list instead of navigating.
  - `ContentView.phonePath`'s setter must not guard on the route; its doc comment says why.
  - The system back button draws as a bare chevron. Keep `navigationSubtitle` on the pane
    screen, or the host name disappears from it.
  - Put nothing custom in the leading nav slot. Replacing the back button disables the
    edge-swipe pop. The UI-test helper `leavePaneScene` finds the system back button by
    position, because it carries no identifier.
- **Two environment rules, with different cures.**
  - `.environment(…)` does not reach a sheet or cover attached above it. Inject **on the
    presented content**. Never fix it by reordering modifiers: that works until someone
    tidies the chain. A push is not a presentation, so everything on the phone stack
    inherits normally.
  - A `ViewModifier`'s own `@Environment` resolves above the point where it is applied, so
    applying it after `.environment(…)` does not help. Pass the instance in as an argument,
    as `TerminalSceneSheets` does.
- **Never present from inside a presentation.** A sheet or alert belongs to the screen
  that owns the presentation, not to a row, a menu or a cover's content. It fails
  silently: a settings sheet in the iPad detail column never appeared, and a composer
  sheet in a `List` row tapped and showed nothing. Where the owner cannot present it,
  render the prompt inline, as `PanePromptBar` does. Confirm the cause before filing a new
  symptom under this rule: one "cannot dismiss after an alert" bug turned out to be a
  wrong `TerminalPresenter`, and filing it here ended the investigation.
- **`DriverrCore.Host` collides with `Foundation.Host`, and `DriverrCore.Tab` with
  SwiftUI's `Tab`.** Qualify them in any file that imports both, or the compiler reports
  "'Host' is ambiguous for type lookup".
- **The Xcode project is hand-authored, not generated.** `Driverr.xcodeproj` uses
  folder-synced groups (`PBXFileSystemSynchronizedRootGroup`), so a new file needs no
  project edit. A new target or package product dependency needs a direct
  `project.pbxproj` edit and a build. Do not add a generate step or `ci_scripts/`.
- **The scheme is committed** at `Driverr.xcodeproj/xcshareddata/xcschemes/Driverr.xcscheme`.
  Edit it by hand. Do not add an empty `<TestPlans></TestPlans>` element: xcodebuild then
  says the scheme "is not currently configured for the test action".
- **Keep the build warning-free.** A new warning is a bug. After the kit and
  `DriverrTests` runs, grep their build logs for `warning:` and fix any in files you
  touched (CONTRIBUTING.md, "The warnings check"). Swift only emits diagnostics for files
  it recompiles, so that grep proves the diff, not the tree. A clean build proves the tree.
- **SwiftTerm needs the Metal toolchain.** `missing Metal Toolchain` on a fresh machine is
  fixed once with `xcodebuild -downloadComponent MetalToolchain` (see README).

## Running tests

The commands, the three tiers and the cadence are in CONTRIBUTING.md. The rules an agent
most often gets wrong:

- **Every edit:** the kit tier, whole. It compiles `DriverrKit` only, so it never proves an
  app-target file (anything under `Driverr/`) compiles. Use the app build or `DriverrTests`.
- **Before a pull request:** `DriverrTests`, whole, plus **only the UI classes your diff
  can reach**, named from the diff and not from caution. Add the iPad for a layout change,
  filtered the same way. Say in the pull request which UI classes you ran and which you
  did not.
- **Never filter the kit or unit tier.** Both are dominated by invocation overhead, so a
  filter saves nothing and risks an empty run. Do not use `test-without-building`: it adds
  a stale-bundle risk and skips nothing that costs time.
- **The unfiltered UI suite, on either simulator, and a clean warnings sweep** are for a
  release cut or a maintainer's request only.
- **No durations are written in this repo, deliberately.** A written number gets believed
  and goes stale as the suite grows. Measure a recent run when you need a cost.
- **`xcodebuild` exits 0 when an `-only-testing` filter matches nothing**, and one typo
  beside a good filter runs only the good one. Check what ran before calling a run green.
- **One run per checkout and per simulator.** A second run can execute a bundle the first
  is rebuilding, and the failure's line number will not match the source.
- **Hosted CI runs the kit tier on every pull request and nothing else**
  (`.github/workflows/tests.yml`). `DriverrTests` failed on a hosted runner for reasons
  unrelated to the commit, on time limits and one layout assertion, so it is not there.
  `DriverrTests` and the UI classes a diff reaches are still a local run before a pull
  request. A green claim must come from output you read.

**Three named simulators.** `Driverr iPhone 17` (device type `iPhone-17`) is the default.
`Driverr iPad` (`iPad-Pro-13-inch-M4-8GB`) is the iPad pass. `Driverr iPhone 17 Pro Max`
(`iPhone-17-Pro-Max`) is for App Store screenshots only, because App Store Connect requires
a 6.9" set. Keep the name and device type together when you create one: an iPad name on an
iPhone type lets the iPad checks pass against a phone. Keep exactly one available device
per name, and remove a duplicate by UDID, never with `delete unavailable`.

**Nothing here names an Xcode or an iOS version, deliberately. Do not add one.** Runs use
whatever Xcode is active and whatever runtime the named device sits on. `README.md` states
the toolchain a fresh clone needs to install, which is a different claim.

**A slow or failing UI run is not always the diff.**
- A killed `xcodebuild` poisons DerivedData. The symptom is `Timed out while evaluating UI
  query` at several times the class's usual duration. An assertion fails fast and a wedged
  query subsystem does not, so the duration is the tell. Erase the simulator before
  believing the next run.
- `App animations complete notification not received` has two causes. An animating view
  (see the steady-caret rule) stalls every run on that screen. A simulator stall hits one
  run and not the next, on no particular screen, at 60 s each. Count the line in the log
  and re-run the class before reading the diff for a cause.
- A simulator can run a stale install while the build is current: green run, zero files
  compiled, wrong content. The tell is behaviour that differs between the phone and iPad
  simulators on one commit. Erase the device.
- A home indicator in every phone capture means the device stopped delivering attention
  events, and SpringBoard hides the indicator on those. Shut that device down and boot it,
  and never erase it for this.

## Test design

**A new UI test has to justify why it cannot be a `DriverrKit` test.** `DriverrCore` has
no dependencies and `FakeControl` needs no network, so sorting, snapshot-to-tree mapping,
`AppError` mapping and store state transitions are all `swift test`, with no simulator. UI
tests cover **wiring, navigation and rendering** only.

**New layout work belongs in the hosted tier.** `DriverrTests` is app-hosted, so
`DriverrTests/HostedProbe.swift` lays a SwiftUI view out in a real `UIWindow` at
`HostedProbe.phone` or `.pad` and reads resolved frames back, for a fraction of the cost
of a UI test.
- The window must be key and visible and the run loop pumped. Without it every
  `GeometryReader` reports `.zero`, which reads like a layout bug.
- There is no accessibility-identifier lookup in-process, so a view opts in with
  `measuredFrame(into:)`. Porting a UI test is not mechanical.
  `HostedAccessibilityLimitTests` pins that limit and fails the day Apple lifts it.
- A hosted test does not replace looking. The two most expensive layout defects here were
  device-only.

**Delete a UI test only when it has never failed and a cheaper test covers the same
claim.** Open that cheaper test and confirm it covers the claim. Do not assume.

### When a UI test class may share one app launch

A class may share **one launch across all its tests** if and only if:

1. **No test changes anything that outlives it**: no host added or deleted, no setting
   changed, no key generated, no trust decision recorded.
2. **Every test restores the navigation state it started from**, in `tearDown` if need be.
3. **No test asserts on something a previous test in the class established.**

If any test mutates, the whole class relaunches per test and carries a comment saying why.
Do not mix the two in one class; split it, as `SettingsUITests` (shared) and
`SettingsMutationUITests` (per test) are. Order-dependence only shows in a full run, so
verify a converted class alone, in the full UI run and on both simulators. That needs a
full run, so **propose a conversion in an issue rather than start one**. Today only
`SettingsUITests` qualifies: the other classes connect, which records a trust decision, and
leave a terminal open.

- **Prefer seeding to sharing.** `-uiTestingSeedHost` gives every test a fresh process
  with `Host.uiTestSeed` already in the list.
- **`-uiTestingConnected`** also seeds the host key and the password, so the connect
  screen needs neither the password field nor the trust prompt. Enter through
  `XCTestCase.connectedHostApp` in `DriverrUITests/UITestSupport.swift`. It does not
  auto-connect, and the app must not gain an affordance that exists only for tests.
- **Four classes stay hand-driven on purpose**: `HostConnectUITests`, `ToggleUITests`,
  `TerminalReconnectUITests` and `ScreenshotTourUITests`. They are what fails if the
  connect path breaks. Seeding one of them deletes its subject.
- **Wait for an element before you scroll for it.** Removing slow setup exposes waits it
  was hiding. "Not arrived yet" and "below the fold" are different problems, and only the
  second is fixed by swiping.

## Test traps

**Never block a cooperative thread in a Kit test.** Swift Testing runs tests on the
cooperative pool, which is `activeProcessorCount` threads wide and never grows. Once that
many tests block at once, every other test waits forever. The run parks at 0 % CPU with no
final tally, across suites that have nothing to do with the cause. Use NIO's async forms
(`try await group.shutdownGracefully()`, `try await channel.close().get()`,
`try await bootstrap.bind(...).get()`), never `.wait()` or `syncShutdownGracefully()`.
Diagnose with `sample <pid>` on the wedged `swiftpm-testing-helper`.

- **XCUITest sees through a presented cover and through a push**, so an element still
  existing does not prove you left the screen. Wait for absence: copy the private
  `requireGone` helper from the class you are editing.
- **A `Toggle` cannot be driven by tapping its identifier.** The tap hits the row, the
  value never changes, and nothing reports it. Use `setSwitch` in `UITestSupport.swift`,
  which taps the switch and asserts the value changed.
- **`typeText` into a `SecureField` leaves the terminal's key row out of every later
  capture on the iPad.** The row stays in the accessibility tree at the right frame,
  hittable, and is not drawn until the app has been to the background and back. Tap the
  keys in `app.keyboards` one by one, as `ScreenshotTourUITests` does, or enter through
  `-uiTestingConnected`.
- **A container's accessibility identifier overwrites its children's.** Put it on the
  header or the leaf, never on a `VStack` or `Section`.
- **Simulator orientation is not test state.** It survives relaunch, so pin it at the start
  of a rotation test, not in `setUp` (nonisolated, so it warns under strict concurrency).
- **A simulator can stop rotating without saying so.** The log shows
  `Device orientation changed` with no `Interface orientation changed` line after it, and
  every rotation assertion compares portrait with itself. It happens on phone and iPad.
  Erase the device. Assert rotation and never skip it: copy `rotateToLandscape` from
  `PaneSwitchUITests`, which fails with the erase remedy.
- **`XCUIApplication.screenshot()` clips a rotated scene** to its pre-rotation width. Use
  `XCUIScreen.main.screenshot()` for evidence about layout.
- **App-side `print` never reaches xcodebuild's log.** Only the test runner's output does.
  Surface values through the accessibility tree, on an element outside any container that
  carries an identifier, or print them from the test.
- **Fakes answer instantly and the device does not.** `FakeTranscriptHost` returns with no
  delay, so the chat is ready on its first frame; on a phone the transcript arrives after
  the view is up. Pass `-uiTestingSlowTranscript` (900 ms) for anything that depends on the
  transcript's arrival; `PaneChatUITests.testTheChatOpensAtTheEndOfATallNewestTurn` only
  fails with it. Treat any other instant fake with the same suspicion.

## UI and layout traps

- **The keyboard's safe area does not include the accessory row above it.** Subtract
  `max(0, regionBottom − accessoryRowTop)`, with `regionBottom` read from layout, not from
  the keyboard notification. See `KeyboardNoticeModel.obstruction(forRegionEndingAt:)`.
  Do not measure the view you are about to pad. A `.keyboard` toolbar row declared
  unconditionally is laid out at y ≈ 0 with no keyboard up, so gate it on focus.
- **A `safeAreaInset` or `safeAreaBar`'s content cannot paint outside the safe area**,
  while the view it insets can draw there. Attach the composer's `safeAreaBar` to the chat
  surface only: on the whole surface stack it also insets the terminal and resizes the
  remote pane.
- **A `UIViewRepresentable` is not told about a `safeAreaBar`.** SwiftUI shrinks its frame
  instead of passing an inset. `ChatCollectionView` documents the workaround.
- **A `GeometryReader` probe reports the safe region it was placed in, not a scroll view's
  own frame.** Read `UIScrollView.adjustedContentInset` instead. Several wrong conclusions
  came from that instrument; `ChatComposerSafeAreaBarLayoutTests` keeps the measurements.
- **`onScrollGeometryChange` can report a `contentOffset` the `UIScrollView` does not
  hold.** When the number matters, read the scroll view directly, as `ScrollViewProbe`
  does in tests.
- **Scroll APIs generic over `Hashable` accept an `Optional` id and match nothing.**
  `turns.last?.id` scrolls nowhere, silently.
- **Bound any correction driven by a scroll or visibility signal.** An unbounded one is a
  loop between the scroll and the change it causes. Drive it from a signal, not a fixed
  `Task.sleep`, which lands on a layout that has not settled.

## Verify by looking

**Verify UI work by looking at it on a simulator, not only by asserting geometry.** Several
rounds of layout work shipped green on assertions and wrong on screen. `scripts/look.sh`
generates a throwaway test from a step list, runs it, and hands back named PNGs; `--help`
lists the verbs, and `--dark` sets the appearance and restores it afterwards.

```
scripts/look.sh --dark --args '-uiTestingBoundedTranscript -uiTestingSlowTranscript'
scripts/look.sh --steps 'tap:hosts.row,shot:hosts,swipe:down,shot:scrolled' --kind ipad
```

By hand it is a throwaway `XCTestCase` with
`XCTAttachment(screenshot: XCUIScreen.main.screenshot())` at each step, exported with
`xcrun xcresulttool export attachments`; delete the class before merging. A capture proves
nothing if the fixture cannot fail (use the slow transcript), if it skips the reported
steps, or if the captured state cannot show the thing. Open the images; do not trust a
printed value instead.

## Style

- Swift 6, strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`). SwiftUI and
  `@Observable` stores (`@MainActor`), not MVVM delegates.
- No service locator. Repositories and controls are protocols. An environment struct holds
  the live or fake instances and is injected through the SwiftUI environment, the shape
  `HerdrControl`'s conformances (`CLIControl` live, `FakeControl` for tests and previews)
  are designed around.
- **The theme's ANSI 4 is the seed of the accent colour; semantic colours govern
  everything else.** `Theme.accent(for:)` derives it, so no theme can ship without one, and
  `ThemeTests` checks the bundled set. In light the accent is ANSI 4 unchanged. In dark,
  ANSI 4 is lifted toward white on its own hue until it reads 4.5:1 on the grouped row
  colour `#2C2C2E`; a seed that already clears is unchanged. The terminal palette never
  changes. No hard-coded brand hex. Read `\.themeAccent`, never `Color.accentColor`, which
  is the system accent and ignores `.tint`. Text buttons in a toolbar take
  `.tint(Color.primary)`, because no usable blue reads 4.5:1 on the toolbar glass; glyphs
  keep the accent. A label on an accent fill takes `\.themeAccentForeground` (black or white
  by measured contrast; a fixed white reads at 3.42:1 on the default light blue). Never dim
  the accent or fall back to the system one; switch the foreground instead.
- Tests accompany domain-logic changes in `DriverrCore`: formatters, `AppError` mapping,
  store state transitions, wire-type to domain mapping.

## Identifiers

The sources are `Driverr.xcodeproj/project.pbxproj`, the two `.entitlements` files and
`Driverr/Info.plist`. Check a value there before changing it.

- **Do not commit a change to `DEVELOPMENT_TEAM`.** Sign locally with your own team. The
  bundle identifiers and the app group are registered to this project's team, so a device
  build under another team also needs its own app and widget bundle identifiers (the
  widget's keeps the app's as its prefix) and its own app group, in both entitlements
  files and in `WidgetThemeSnapshot.appGroupID`. `WidgetThemeSnapshotTests` pins the app
  group string, so that test fails on the local change. Commit none of it. Simulator
  builds and the tests need none of it. README.md, "Signing and identifiers", has the steps.
- **App group `group.com.cunderw.driverr`** is declared in both entitlements files and read
  back by `DriverrCore.WidgetThemeSnapshot.appGroupID`. It is how the app and the widget
  share the theme snapshot. Change all three together.
- **`DriverrWatch` is the Live Activity widget extension.** Its bundle identifier ends in
  `.watch`, the same string as the background task identifier
  `BackgroundWatch.taskIdentifier`. The two are not related.
- **URL scheme `driverr`.** The routes are in `DriverrCore.BlockedPaneActivityRoute`.
- **`BGTaskSchedulerPermittedIdentifiers` carries a reserved `.watch.*` entry that nothing
  registers.** See `BackgroundWatch.wildcardTaskIdentifier` before touching it.
  `DriverrTests` reads the plist array back, so the Swift side and the plist cannot drift.
- **`UIBackgroundModes` holds `fetch` and nothing else.** A `BGContinuedProcessingTask`
  needs no mode, and a declared mode the app does not use is an App Review rejection cause.

## Releases

The release procedure lives outside this repo. These are only the facts about the tree.

- **A push to `main` that changes the app uploads a TestFlight build**
  (`.github/workflows/testflight.yml`). A manual run of that workflow validates only,
  unless it is told to upload. `scripts/testflight.mjs` holds its App Store Connect calls.
- **`MARKETING_VERSION` appears twice** in `project.pbxproj`, Debug and Release. Change
  both; nothing warns about a mismatch.
- **Never commit a `CURRENT_PROJECT_VERSION` bump.** The build number is supplied on the
  archive command line.
- **The whole App Store listing is `docs/appstore/copy.json`.** There is no prose mirror.
- **Screenshots** are in `docs/app-store-assets/iphone-max` and
  `docs/app-store-assets/ipad`. Regenerate with `scripts/screenshots.sh`, which checks the
  pixel sizes and the image count per kind. It shuts each device down and boots it before
  the tour, and it fails the phone set if an image draws the home indicator
  (`scripts/home-indicator.sh`). The store images have none. They upload in filename
  order. The phone set is `01-` to `06-`. The iPad set is `02-` to `06-`, five images with
  no `01-hosts`, because on the split view the host list is never a separate screen.
- Before a release, the full UI suite on both simulators and the clean warnings sweep are
  worth running.

## Project management

GitHub Issues track all work. CONTRIBUTING.md has the workflow: how to take an issue,
branch names, squash pull requests with `Closes #<n>`, the label table, and the two files
that collide between branches.

**An issue that contradicts a decision in this file is a decision to revisit, not a ticket
to implement.** Say so on the issue rather than changing the rule in passing.

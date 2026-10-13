# Contributing to Driverr

Thanks for looking. Driverr is a small, opinionated app, and the fastest way to have a
change accepted is to know which of those two words applies to it.

This file is the whole workflow: what to open before you write code, how to branch and
open a pull request, which tests to run, and what evidence a pull request is expected to
carry. [`README.md`](README.md) has the build setup. [`CLAUDE.md`](CLAUDE.md) is the long
list of traps this project has already paid for, written for coding agents and worth
skimming before your first change; you do not need it to get started. Everyone who takes
part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you write code

**Open an issue first**, unless the change is a typo or a one-line obvious fix. Driverr has
a set of deliberate non-goals; a pull request that argues with them is a hard
conversation to have after the code exists.

Two things are settled and not up for relitigation:

- **Driverr is not a configuration surface.** Global settings are theme, font, font size,
  whether a captured pane screen wraps its long lines, and whether Driverr draws Live
  Activities. A sixth one still has to argue its case, in an issue, before the code exists.
- **Driverr is free and has no backend.** It talks directly to the machines you name.

## Filing an issue

Use a template — bug, feature, chore or design — and fill in every section. The bar is
that **someone with no context can implement and verify it**: what the deliverable is, why
it matters, and acceptance criteria concrete enough to test against. "Works correctly" is
not a criterion; "never fires twice a day" is.

Every issue carries **exactly one `area:` label and exactly one `type:` label**. This table
is the one copy; other files link here rather than repeat it.

| `area:` | |
| --- | --- |
| `area:ios` | The app, its screens, its tests |
| `area:ssh` | `DriverrSSH` — transport, auth, host keys |
| `area:herdr` | `DriverrHerdr` — the wire format and the control surface |
| `area:infra` | Build, release, tooling, the local gates |
| `area:design` | Product and interaction decisions |

| `type:` | |
| --- | --- |
| `type:feature` | New capability |
| `type:bug` | Something is wrong |
| `type:chore` | Maintenance, tooling, tests, docs |
| `type:design` | A decision to be made, not code to be written |

The issue templates apply the `type:` label and ask you for the area. A maintainer applies
the `area:` label from your answer.

## Working on an issue

- **Comment on the issue before you start, to say you are taking it.** A maintainer
  assigns it to you. An issue with no assignee is free to take.
- **Outside contributors work from a fork** and open the pull request from it.
- **One issue per branch**, named `feat/`, `fix/` or `chore/` plus the issue number and a
  short slug.
- **Everything merges to `main` via a squash pull request whose body contains
  `Closes #<n>`.** That is what keeps issues honest.
- **Don't touch files outside the issue's scope.** Two files collide between branches more
  than any others — `Driverr.xcodeproj/project.pbxproj` and `DriverrKit/Package.swift`. If
  one genuinely has to change, say so on the issue.
- **Reproduce before you fix.** Write the failing test first and watch it fail as an
  assertion, not as a compile error. A test that has never been red proves nothing about
  the bug it claims to cover.

## Setting up

[`README.md`](README.md#building-it) has the requirements, the one-time Metal toolchain
download, the `simctl create` for Driverr's named simulator, and the build command. Do that
first; every command below assumes it.

## Tests, and where they belong

**A new UI test has to justify why it cannot be a `DriverrKit` test.** This one rule decides
how long the UI suite grows, and it is cheap to hold now and expensive to retrofit.

There are three tiers, cheapest first:

| Tier | What it is | What belongs there |
| --- | --- | --- |
| Kit | SwiftPM tests in `DriverrKit`, no simulator | Sorting, mapping, `AppError` translation, store state transitions — the correctness core |
| Hosted | `DriverrTests`, app-hosted, with `DriverrTests/HostedProbe.swift` laying a SwiftUI view out in a real `UIWindow` | Layout: "is this the wrong size or in the wrong place" |
| UI | `DriverrUITests`, XCUITest on a simulator | Wiring, navigation and rendering — that a screen appears, that a tap routes somewhere |

`DriverrCore` has no dependencies and the fakes need no network, so the first tier needs no
simulator and no remote host. A hosted frame assertion costs far less than the same claim
as XCUITest, which costs a full app launch. The UI tier does not cover logic either of the
cheaper tiers can assert.

A few `DriverrSSH` kit tests start an in-process SSH server on a loopback port. It accepts a
username and password written in the test. Some of those tests ask it to run the commands it
receives as real processes with `/bin/sh`, as you, while the test runs.

### Which tests to run

Define `xbm` once in each shell you open. It holds the version pin, and it works in zsh
and in bash:

```sh
xbm() { npx -y xcodebuildmcp@2.7.0 "$@"; }
```

The kit tier, `DriverrTests`, one UI class, and the Release build:

```sh
xbm swift-package test --package-path DriverrKit --output json
xbm simulator test --extra-args -only-testing:DriverrTests --output json
xbm simulator test --extra-args -only-testing:DriverrUITests/TheClassYouTouched --output json
xbm simulator build --configuration Release --output json
```

- **Every edit, the whole kit tier.**
- **Before a pull request — `DriverrTests`, whole, plus only the UI classes your diff can
  actually reach.** Name them from the diff rather than from caution: a change to
  `PaneChatView` runs `PaneChatUITests`, not every `Pane*` class.
- **Add the iPad when a screen's layout changes**: `--simulator-name "Driverr iPad"`. Two
  layout defects were found that way and nowhere else. Filter it to the classes the layout
  change reaches.
- **Add a Release build when the diff touches `#if DEBUG` code, or calls something declared
  inside one.** The three tiers build Debug only. A `DEBUG`-only symbol used from Release
  code passes all of them and fails at the archive. This is a simulator build and needs no
  signing.

**Never filter the kit or the unit tier.** Both are dominated by invocation overhead, not
by tests: the unit tier's tests are a small part of a much longer invocation. A
targeted unit run buys nothing and risks the empty-run trap below. For the same reason,
`test-without-building` saves nothing and adds a stale-bundle risk.

**The unfiltered UI suite is the most expensive thing in this repo.** It is for a release
cut or a deliberate request, not for routine verification, and not for "make sure nothing
else broke". Run the classes your diff reaches, then **say which ones you ran and which you
did not** in the pull request. An honest "I ran `PaneChatUITests`; the other classes are
unverified" is worth more than a full-suite wait.

**No durations are written down here, on purpose.** A number in a doc gets believed rather
than checked, and it goes stale as the suite grows. Measure a recent run when you need one.

### A green run is not a pass until you check what ran

`xcodebuild` prints `** TEST SUCCEEDED **` and exits 0 when an `-only-testing:` filter
matches nothing, so one mistyped class name silently turns a gate into a no-op.
`-only-testing:DriverrTests/NoSuchClass/nope` reports `SUCCEEDED` with
`{passed: 0, failed: 0, skipped: 0}`. One good filter beside one typo does the same, which
no count can catch.

**The check:** run with `--output json`, read `request.onlyTesting`, and confirm every
filter in it appears in `tests.selected`. A class that was never compiled cannot be listed.
The tell is also speed: an empty run comes back noticeably faster than a real one.

`.xcodebuildmcp/config.yaml`'s `projectPath` is relative, so a run started from a linked
worktree can build and test a different checkout. Pass an absolute `--project-path` from a
worktree, and check that the run's `request.projectPath` is your worktree and that your own
new tests appear in `tests.selected`.

### Two runs in one checkout or on one simulator give a wrong result

Two runs in one checkout share DerivedData, and two runs on one simulator install over each
other. Either way a run can execute a test bundle the other is mid-way through rebuilding.
The symptom is a failure message and line number that do not match the source on disk,
which reads exactly like "my edit didn't take". Run one at a time, and check that nothing
is running first:

```sh
pgrep -xl xcodebuild
pgrep -xl swiftpm-testing-helper
```

`pgrep -x` matches the process name exactly, so it cannot match its own invocation. A hit
is a run in progress. Wait for it to finish, because a killed `xcodebuild` poisons
DerivedData.

### Look at user-visible changes

Geometry assertions can pass while the screen is wrong. `scripts/look.sh` drives the app
and hands back PNGs, and asserts nothing — that is the point:

```sh
scripts/look.sh --dark --steps 'tap:hosts.row,shot:hosts,swipe:down,shot:scrolled'
scripts/look.sh --kind ipad
```

`--help` lists the step verbs. Open the images at full size; a screenshot of the wrong
state is indistinguishable from a screenshot of a fixed one.

## The warnings check

The build is kept **warning-free**. A new warning is a bug, not noise.

The kit tier and `DriverrTests` between them compile everything that matters, so the routine
check is a grep of the logs those two runs already wrote. Each run with `--output json`
reports its own log at `artifacts.buildLogPath`. A simulator run prints that path with a
leading `~`, which a shell does not expand inside quotes, so the second line expands it:

```sh
LOG="<artifacts.buildLogPath from the run>"
grep -n 'warning:' "${LOG/#\~/$HOME}"
```

A compiler warning starts with a source path, `File.swift:LINE:COLUMN: warning:`. Two
kinds of line can appear in a clean log and name no source file. Both are expected, and
neither is a compiler diagnostic:

- `appintentsmetadataprocessor[…] warning: Metadata extraction skipped, no
  AppIntents.framework dependency found`, in a simulator log.
- `warning: missing creator for mutated node: ('…/SwiftTerm_SwiftTerm.bundle/…')`, in the
  kit log. SwiftPM's build system prints it.

Fix every other hit in a file your diff touches. **That grep only proves the files that got
recompiled** — Swift emits a file's diagnostics only when it recompiles that file, so a warm
build directory can hide warnings in files your diff never touched. The full sweep,
`simulator build --build-for-testing`, is the one that proves the whole tree, and it is
expensive enough to be a deliberate choice rather than a habit.

## Things that have already cost someone a day

[`CLAUDE.md`](CLAUDE.md) is the honest list. A few that bite newcomers immediately:

- **Never present a sheet or alert from inside another presentation** — from a `List` row,
  a `Menu`, or a cover's content. Two features were lost to this, each failing differently
  and neither at compile time. Render the prompt inline instead; `PanePromptBar` is what
  that looks like.
- **A container's accessibility identifier overwrites its children's.** SwiftUI propagates
  `.accessibilityIdentifier` down, so one on a `VStack` or `Section` renames every button
  inside it and the tests stop finding them. Put it on the header or the leaf.
- **A `Toggle` cannot be driven by tapping its identifier** from XCUITest.
  `matching(identifier:).tap()` hits the row, not the switch, and the binding never changes
  while nothing reports a problem. Use the free function `setSwitch` in
  `DriverrUITests/UITestSupport.swift`, which taps the control's trailing edge and then
  asserts the value changed.
- **XCUITest sees through a presented cover and through a push**, so an element still
  existing does not prove you navigated away. Wait for absence rather than asserting it
  once — copy the `requireGone` helper in `DriverrUITests/PaneActionsUITests.swift`.
- **`XCUIApplication.screenshot()` clips a rotated scene.** It crops content to the
  pre-rotation width and leaves a black band that is an artifact of the capture. Use
  `XCUIScreen.main.screenshot()` for any evidence about layout.

## Comments

A comment says why the code that exists now has its shape. A reader must understand it
without the issue tracker, the git history or the conversation that produced the code.

Write a comment for:

- an invariant the type system does not enforce
- a protocol or wire-format constraint
- a security property, and what breaks it
- a platform behaviour that was measured, with the number when the number matters
- a deliberate tradeoff, and what the other choice would cost
- a regression trap: the change that looks like a cleanup and is not, and what it breaks

Do not write:

- the history of the change: who asked, dates, issue slices, review rounds, earlier drafts,
  what was tried first, or how the bug was found
- a description of code that no longer exists
- a restatement of the next line
- a copy of a rule this file or `CLAUDE.md` already states. Name the rule if the reader
  needs a pointer.

Keep a comment as short as its reason. One to three sentences is usual. A longer comment
has to earn its length with a trap whose mechanism the reader needs before they change the
code. Say the reason once, in the place where it applies. Other places point to it.

An issue number is not an explanation. State the reason in the comment, and keep the link
only when the issue adds context the comment cannot hold. A measured number stays when it
justifies the code, for example a timeout.

## Pull requests

Scan your commits for secrets before you push. Get gitleaks from its
[repository](https://github.com/gitleaks/gitleaks), then run this from the repository root:
`gitleaks git --redact --log-opts=origin/main..HEAD`. `.gitleaks.toml` extends the default
rules and allows two test fixtures by path and exact text. Do not widen it. A new key in
one of those files must still fail the scan.

Fill in the pull request template. Its four verification lines and four evidence lines each
want a fact, not a reassurance:

| Template line | What to write |
| --- | --- |
| `DriverrKit` | The command you ran and the counts you saw |
| `DriverrTests` | The same, unfiltered |
| UI tests | The classes you ran with their counts, **and the classes you did not run** |
| Warning check | Which log you grepped and what it found |
| Visual inspection | What you looked at, on which simulator and in which appearance |
| Accessibility coverage | The identifiers and labels new or changed UI carries, on leaves rather than containers |
| Assertion coverage | Which test now fails if this regresses, and that you watched it fail before the fix |
| Screenshots or recordings | Attach them for anything user-visible |

Write "Not applicable" where a line genuinely does not apply, rather than leaving it blank.

Hosted CI runs the kit tier on every pull request and nothing else. So `DriverrTests` and
the UI classes your diff reaches are still yours to run, and a green claim about them is
only as good as the output you actually read. Please don't open a pull request you already
know is red.

Say what changed and why. If you found something surprising on the way, put it in the pull
request body — that is how the list above got written.

import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// A value two closures share, since Swift 6 rejects a `var` captured by an escaping closure.
@MainActor
private final class Box<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// A herdr that succeeds at everything and has nothing to say about any pane.
///
/// `FakeControl` either answers with fixture lines or throws. This one exits 0 with the empty
/// string, which a real `pane read` has done.
private struct SilentControl: HerdrControl {
  let binaryPath = "herdr"
  func snapshot() async throws -> SessionTree { .empty }
  func attachCommand(for pane: Pane) -> String { "herdr terminal attach \(pane.id)" }
  func availability() async -> HerdrAvailability { .ready(version: "0.8.2", protocolVersion: 20) }
  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}

  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
  }

  /// The pane sheet reads the batch, so this is stubbed, and blank so a stray call is visible.
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen { .blank }
}

/// Where each tile in the pane sheet gets its picture, and what that costs.
///
/// A warm pane already has a live emulator, so its lines are free. A batch that included it
/// anyway would look identical on screen while costing a `pane read` per tile per tick on the
/// host. `FakeControl.reads` makes the difference visible.
@MainActor
@Suite("PaneThumbnailModel", .timeLimit(.minutes(1)))
struct PaneThumbnailModelTests {
  private let panes: [TerminalTarget] = [
    .pane(id: "w1:p1"),
    .pane(id: "w1:p2"),
    .pane(id: "w1:p3"),
  ]

  /// What `FakeControl` says the blocked pane is showing — the three lines a cold tile
  /// draws when the batch answers for it.
  private let blockedPaneLines = ["$ cd ~/dev/driverr", "$ herdr pane w1:p2", "Claude is blocked"]

  private func makeModel(
    control: any HerdrControl,
    targets: [TerminalTarget]? = nil,
    warm: [TerminalTarget: [String]] = [:],
    interval: Duration = .milliseconds(20)
  ) -> PaneThumbnailModel {
    PaneThumbnailModel(
      control: { control },
      targets: { targets ?? self.panes },
      warmLines: { warm[$0] },
      interval: interval
    )
  }

  /// Several ticks long, used only where the claim is that something did not happen, which a
  /// slow machine makes hold. Waits for something that does happen use
  /// `FakeControl.waitForReads`, with no clock.
  private let settle = Duration.milliseconds(150)

  // MARK: - Where a tile's lines come from

  @Test("a warm pane's lines come from its own emulator, and are never asked for over the wire")
  func warmPanesCostNothing() async throws {
    let control = FakeControl()
    let model = makeModel(
      control: control,
      warm: [.pane(id: "w1:p2"): ["$ swift test", "42 tests passed"]]
    )

    model.open()
    await control.waitForReads(1)

    #expect(model.lines(for: .pane(id: "w1:p2")) == ["$ swift test", "42 tests passed"])
    let asked = await control.reads.flatMap { $0 }
    #expect(!asked.contains("w1:p2"), "a pane with a live emulator must not be read again")
    model.close()
  }

  @Test("a cold pane's lines come from the batch")
  func coldPanesComeFromOneBatch() async throws {
    let control = FakeControl()
    let model = makeModel(control: control, warm: [.pane(id: "w1:p1"): ["warm"]])

    model.open()
    // Two: the waiter resumes inside the read, so a batch is known to be applied only once the
    // next one is asked for.
    await control.waitForReads(2)

    #expect(model.lines(for: .pane(id: "w1:p2")) == blockedPaneLines)
    // One request for the whole sheet, not one per tile.
    #expect(await control.reads.first == ["w1:p2", "w1:p3"])
    model.close()
  }

  @Test("a pane nothing has said anything about yet draws nothing rather than guessing")
  func unknownPanesAreEmpty() {
    let model = makeModel(control: FakeControl())

    #expect(model.lines(for: .pane(id: "w1:p2")).isEmpty)
    #expect(model.lines(for: .shell).isEmpty)
  }

  @Test("the shell's tile is its own emulator's, and it is never in the batch")
  func theShellIsNeverRead() async throws {
    // The shell is Driverr's own pty, which herdr has never heard of.
    let control = FakeControl()
    let model = makeModel(
      control: control,
      targets: [.shell, .pane(id: "w1:p2")],
      warm: [.shell: ["carson@workbox ~ %"]]
    )

    model.open()
    // Two batches, because the claim below is about every one of them.
    await control.waitForReads(2)

    #expect(model.lines(for: .shell) == ["carson@workbox ~ %"])
    // Every batch, not just the first.
    #expect(await control.reads.allSatisfy { $0 == ["w1:p2"] })
    model.close()
  }

  // MARK: - When the batch runs

  @Test("the batch runs on open and again on every tick, while the sheet is open")
  func readsRepeatWhileOpen() async throws {
    let control = FakeControl()
    let model = makeModel(control: control)

    #expect(await control.reads.isEmpty, "nothing is read before the sheet is opened")

    model.open()
    await control.waitForReads(3)

    #expect(await control.reads.count >= 3, "the sheet is live, not a snapshot")
    model.close()
  }

  @Test("closing the sheet stops the reads")
  func closingStopsTheReads() async throws {
    // A closed sheet must not keep running `pane read` against the host every three seconds.
    let control = FakeControl()
    let model = makeModel(control: control)

    model.open()
    await control.waitForReads(1)
    model.close()
    let afterClosing = await control.reads.count

    try await Task.sleep(for: settle)

    #expect(await control.reads.count == afterClosing)
  }

  @Test("opening a sheet that is already open does not start a second loop")
  func openIsIdempotent() async throws {
    // `.onChange` can fire more than once for one state change, and two loops double the
    // traffic.
    let control = FakeControl()
    let model = makeModel(control: control, interval: .seconds(30))

    model.open()
    model.open()
    await control.waitForReads(1)
    try await Task.sleep(for: settle)

    #expect(await control.reads.count == 1)
    model.close()
  }

  @Test("a pane that has warmed up since the last tick drops out of the batch")
  func warmthIsRecheckedEveryTick() async throws {
    // Switching from the sheet moves the warm set: the pane left becomes an observer.
    let control = FakeControl()
    let warm = Box<[TerminalTarget: [String]]>([:])
    let model = PaneThumbnailModel(
      control: { control },
      targets: { self.panes },
      warmLines: { warm.value[$0] },
      interval: .milliseconds(20)
    )

    model.open()
    await control.waitForReads(1)
    #expect(await control.reads.first == ["w1:p1", "w1:p2", "w1:p3"])

    warm.value[.pane(id: "w1:p1")] = ["now warm"]
    // One more read is the first that can have seen the warm set move.
    let beforeWarming = await control.reads.count
    await control.waitForReads(beforeWarming + 1)

    #expect(await control.reads.last == ["w1:p2", "w1:p3"])
    model.close()
  }

  @Test("a batch that fails leaves the last picture up rather than blanking every tile")
  func aFailedBatchKeepsWhatItHad() async throws {
    // A stale picture says more than an empty rectangle, and one failed tick is retried in
    // three seconds.
    let failing = FakeControl.failing(.herdrCommandFailed(reason: "herdr went away"))
    let working = FakeControl()
    let control = Box<any HerdrControl>(working)
    let model = PaneThumbnailModel(
      control: { control.value },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .milliseconds(20)
    )

    model.open()
    await working.waitForReads(2)
    let drawn = model.lines(for: .pane(id: "w1:p2"))
    control.value = failing
    // A refused batch is recorded before it throws, so there is a count to wait on. Two: the
    // waiter resumes inside `readPanes`, and the loop is sequential, so the second read proves
    // the first refusal was handled.
    await failing.waitForReads(2)

    #expect(model.lines(for: .pane(id: "w1:p2")) == drawn)
    #expect(drawn == blockedPaneLines)
    model.close()
  }

  // MARK: - Telling a blip from a read that can never work

  @Test("the first failed batch says nothing at all")
  func oneFailureIsQuiet() async throws {
    // One failure says nothing: the picture on screen is still the best answer, and a notice
    // gone in three seconds is worse than none.
    let model = makeModel(control: FakeControl.failing(.herdrCommandFailed(reason: "went away")))

    await model.refresh()

    #expect(model.readFailure == nil)
  }

  @Test("a batch that keeps failing stops being silent about it")
  func aRunOfFailuresIsReported() async throws {
    // A read that can never succeed must say so eventually. `refresh()` is driven a tick at a
    // time, because the claim is which tick it starts speaking on.
    let model = makeModel(control: FakeControl.failing(.herdrCommandFailed(reason: "went away")))

    for _ in 0..<PaneThumbnailModel.failedReadsBeforeReporting { await model.refresh() }

    let failure = try #require(model.readFailure)
    #expect(failure.contains("went away"), "the notice has to say what herdr said")
  }

  @Test("no herdr to ask is a failed read, not a skipped one")
  func aMissingControlCountsAsAFailure() async throws {
    // `TerminalScreen` hands the model `model.liveHerdr`, which is `nil` while the link is
    // down. An outage and a read that throws look the same on the sheet, so both count.
    let model = PaneThumbnailModel(
      control: { nil },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .seconds(30)
    )

    await model.refresh()
    #expect(model.readFailure == nil, "one tick of an outage is still a blip")

    await model.refresh()

    let failure = try #require(model.readFailure)
    #expect(failure.contains("isn't connected"), "got: \(failure)")
  }

  @Test("the tiles stop being placeholders once a batch has come back, however it went")
  func theFirstBatchEndsThePlaceholders() async throws {
    // Until the first `readPanes` answers, a cold tile's six empty rows look like an empty
    // pane. The sheet redacts while this is false.
    let model = makeModel(control: FakeControl())
    #expect(model.hasRead == false, "nothing has been asked yet")

    await model.refresh()

    #expect(model.hasRead, "a batch came back, so the tiles are showing what there is")

    // A batch that could not run counts too, and `readFailure` explains a sheet that has
    // stopped moving.
    let failing = makeModel(control: FakeControl.failing(.herdrCommandFailed(reason: "gone")))
    await failing.refresh()
    #expect(failing.hasRead)
  }

  @Test("a batch that works again takes the notice away with it")
  func recoveryClearsTheNotice() async throws {
    let working = FakeControl()
    let control = Box<any HerdrControl>(
      FakeControl.failing(.herdrCommandFailed(reason: "went away"))
    )
    let model = PaneThumbnailModel(
      control: { control.value },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .seconds(30)
    )

    for _ in 0..<PaneThumbnailModel.failedReadsBeforeReporting { await model.refresh() }
    #expect(model.readFailure != nil)

    control.value = working
    await model.refresh()

    #expect(model.readFailure == nil)
    #expect(model.lines(for: .pane(id: "w1:p2")) == blockedPaneLines)
  }

  @Test("a run of failures does not blank the tiles it already drew")
  func aReportedFailureStillKeepsThePicture() async throws {
    // The notice replaces the silence, not the pictures.
    let control = Box<any HerdrControl>(FakeControl())
    let model = PaneThumbnailModel(
      control: { control.value },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .seconds(30)
    )

    await model.refresh()
    control.value = FakeControl.failing(.herdrCommandFailed(reason: "went away"))
    for _ in 0..<PaneThumbnailModel.failedReadsBeforeReporting { await model.refresh() }

    #expect(model.readFailure != nil)
    #expect(model.lines(for: .pane(id: "w1:p2")) == blockedPaneLines)
  }

  @Test("a batch that answers, and answers nothing, over and over is noticed")
  func readingNothingIsNoticed() async throws {
    // `pane read --source recent --lines 6` can exit 0 with the empty string, leaving tiles
    // blank with nothing thrown. It is logged, not shown: a quiet session looks identical.
    let model = makeModel(control: SilentControl())

    for _ in 0..<(PaneThumbnailModel.emptyReadsBeforeReporting - 1) { await model.refresh() }
    #expect(model.isReadingNothing == false, "a quiet tick or two is just a quiet session")

    await model.refresh()

    #expect(model.isReadingNothing)
  }

  @Test("one pane with something in it is enough to say the read is working")
  func contentClearsIt() async throws {
    let control = Box<any HerdrControl>(SilentControl())
    let model = PaneThumbnailModel(
      control: { control.value },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .seconds(30)
    )

    for _ in 0..<PaneThumbnailModel.emptyReadsBeforeReporting { await model.refresh() }
    #expect(model.isReadingNothing)

    control.value = FakeControl()
    await model.refresh()

    #expect(model.isReadingNothing == false)
  }

  @Test("nothing is asked of a host that has no herdr on it")
  func noControlIsNoRequest() async throws {
    // A disconnect while the sheet is open reaches this state, and must not crash.
    let model = PaneThumbnailModel(
      control: { nil },
      targets: { self.panes },
      warmLines: { _ in nil },
      interval: .milliseconds(20)
    )

    model.open()
    try await Task.sleep(for: settle)

    #expect(model.lines(for: .pane(id: "w1:p2")).isEmpty)
    model.close()
  }

  // MARK: - Whose panes get read at all

  /// A session on a host that shares no pane id with `FakeControl.seededTree`. herdr's ids are
  /// per host, so with shared ids a read that wandered onto another host would be invisible.
  private static let treeOnTheOtherHost = SessionTree(
    workspaces: [
      Workspace(
        id: "z9",
        number: 1,
        label: "beta",
        isFocused: true,
        status: .working,
        tabs: [
          Tab(
            id: "z9:t1",
            workspaceID: "z9",
            number: 1,
            label: "build",
            isFocused: true,
            status: .working,
            panes: [
              Pane(
                id: "z9:p9",
                tabID: "z9:t1",
                workspaceID: "z9",
                title: "kernel build",
                agent: Agent(name: "claude", status: .working),
                terminalID: "term_z9p9",
                directory: "~/src",
                isFocused: true
              )
            ]
          )
        ]
      )
    ],
    focusedPaneID: "z9:p9"
  )

  /// A connected host whose herdr is `control` — everything a scene needs behind it.
  private func connection(
    to host: DriverrCore.Host,
    herdr control: any HerdrControl
  ) async -> ConnectionModel {
    var environment = AppEnvironment.ephemeral
    // Seeded, or TOFU raises a prompt nobody answers.
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in control }
    let model = ConnectionModel(host: host, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    // The switcher lists the tree and the thumbnails read it; the screen loads it first.
    await model.session?.refresh()
    return model
  }

  /// The sheet lists other hosts' panes and never reads them.
  ///
  /// A batched `pane read` per tick for every cold tile would put traffic on hosts nobody is
  /// looking at. The model's `targets` closure is `strip.targets`, built from the current
  /// host's tree alone, so the cross-host sections have to sit beside that value, not in it.
  ///
  /// A read that crossed hosts would also come back keyed by a bare pane id and merge into
  /// `cold`, putting the wrong picture under the right title.
  @Test("the switcher offers other hosts' panes and the thumbnails never ask for one")
  func thumbnailsAreGatedToTheHostOnScreen() async throws {
    let onScreen = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
    let elsewhere = DriverrCore.Host(name: "beta", hostname: "10.1.0.42", username: "carson")
    let hereControl = FakeControl(tree: FakeControl.seededTree)
    let thereControl = FakeControl(tree: Self.treeOnTheOtherHost)
    let here = await connection(to: onScreen, herdr: hereControl)
    let there = await connection(to: elsewhere, herdr: thereControl)

    // What the sheet is handed: the mapping `ConnectionRegistry.paneSwitcherHosts` feeds.
    let offered = CrossHostPanes(
      currentHostID: onScreen.id,
      hosts: [
        PaneSwitcherHost(
          id: onScreen.id,
          name: onScreen.displayName,
          isConnected: true,
          tree: here.session?.tree ?? .empty
        ),
        PaneSwitcherHost(
          id: elsewhere.id,
          name: elsewhere.displayName,
          isConnected: true,
          tree: there.session?.tree ?? .empty
        ),
      ]
    )
    let offeredElsewhere = Set(offered.sections.flatMap { $0.panes.map(\.id) })
    #expect(
      offeredElsewhere.contains("z9:p9"),
      "the switcher is not offering the other host, so the read below proves nothing"
    )

    let scene = TerminalSceneModel(
      host: onScreen,
      model: here,
      initialTarget: .pane(id: "w1:p1")
    )
    scene.showPaneSheet()
    // The poll loop stops and the batch is driven by hand, so this asserts one tick's worth.
    scene.hidePaneSheet()
    await scene.paneThumbnails?.refresh()

    let asked = Set(await hereControl.reads.flatMap { $0 })
    #expect(
      asked == Set(FakeControl.seededTree.allPanes.map(\.id)),
      "the batch is the host on screen's panes, whole"
    )
    #expect(asked.isDisjoint(with: offeredElsewhere))
    #expect(
      await thereControl.reads.isEmpty,
      "a `pane read` ran against a machine nobody is looking at"
    )
  }
}

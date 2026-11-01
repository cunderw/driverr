import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTerm
import Foundation
import Testing
import UIKit

@testable import Driverr

/// The terminal scene: one presentation per host, with the pane it shows a value inside it
/// rather than a new presentation.
///
/// What makes a switch correct is which commands go down the wire and in what order: one
/// controller at a time, an observer opened before the controller it replaces is released, a
/// scroll sent home before the pane is handed back. A simulator cannot see that.
/// `FakeSSHTransport` logs every streamed command, stdin line and close in one timeline.
///
/// `.serialized` because `TerminalSceneModel` observes
/// `UIApplication.didReceiveMemoryWarningNotification`, and scenes in parallel would evict each
/// other's warm sets. A warning is app-wide, so a suite running in parallel could also reach a
/// scene here; every scene listens on a centre of its own, and tests post warnings there.
@MainActor
@Suite("TerminalSceneModel", .serialized, .timeLimit(.minutes(1)))
struct TerminalSceneModelTests {
  private let host = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  // MARK: - Fixtures

  /// One `terminal.frame` record, as herdr's bridge sends the first frame: always `full`,
  /// always `seq: 1`.
  ///
  /// `nonisolated` because the stream responders below are `@Sendable` closures the fake
  /// transport calls from its own actor, not from the main one this suite runs on.
  fileprivate nonisolated static func frame(_ text: String) -> Data {
    let encoded = Data(text.utf8).base64EncodedString()
    let record = """
      {"type":"terminal.frame","seq":1,"full":true,"encoding":"ansi",\
      "width":80,"height":24,"bytes":"\(encoded)"}
      """
    return Data((record + "\n").utf8)
  }

  /// A `terminal.closed` record carrying herdr's own wording, so the decoding under test
  /// is the one that ships. `nonisolated` for the same reason `frame` is.
  fileprivate nonisolated static func closed(_ reason: String) -> Data {
    Data(("{\"type\":\"terminal.closed\",\"reason\":\"\(reason)\"}\n").utf8)
  }

  /// herdr's refusal for one terminal, verbatim (`src/server/headless.rs:2859`, 0.8.2).
  fileprivate nonisolated static func refusal(of terminalID: String) -> Data {
    closed(
      "terminal attach failed: terminal \(terminalID) already has an attached client; "
        + "retry with --takeover"
    )
  }

  /// herdr `v0.8.0`'s refusal, verbatim (`src/server/headless.rs:2622`).
  private nonisolated static let refusal =
    "terminal attach failed: terminal term_w1p1 already has an attached client; "
    + "retry with --takeover"

  /// Answers observers with a frame and controllers with nothing, so the promotion gap —
  /// controller open, first frame not home yet — is a state a test can stand still in.
  private static let observersOnly: @Sendable (String) -> Data? = { command in
    command.contains("terminal session observe") ? frame("observed\r\n") : nil
  }

  /// Answers everything with a frame: a controller that paints as soon as it opens.
  private static let everythingPaints: @Sendable (String) -> Data? = { command in
    command.contains("terminal session") ? frame("live\r\n") : nil
  }

  /// A connected host, with bridge commands answered by `responder`.
  ///
  /// Split out of `makeScene` so a test can hold the connection while letting the scene go, as
  /// the app does: `ConnectionRegistry` owns the `ConnectionModel`, the presentation the scene.
  private func makeConnection(
    ptyGreeting: String? = nil,
    herdr: (any HerdrControl)? = nil,
    responder: @escaping @Sendable (String) -> Data?
  ) async -> (ConnectionModel, FakeSSHTransport) {
    // The hook wakes every `waitUntilSignalled` below. Actor state such as `streamLog` is out
    // of observation's reach.
    let transport = FakeSSHTransport(
      ptyGreeting: ptyGreeting,
      streamResponder: responder,
      onActivity: { Waker.signalShared() }
    )
    var environment = AppEnvironment.ephemeral
    // Seeded for the reason `ConnectionRegistryTests` seeds it: `FakeSSHTransport`'s key
    // is unknown to a fresh store, so TOFU raises a prompt a test has nobody to answer.
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { transport }
    let control = herdr ?? FakeControl()
    environment.makeHerdrControl = { _ in control }

    let model = ConnectionModel(host: host, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    // The tree is what turns a pane id into a terminal id, and the screen that presents a
    // scene has always loaded it first.
    await model.session?.refresh()
    return (model, transport)
  }

  /// A connected host, and a scene on `initialTarget`, with bridge commands answered by
  /// `responder`.
  ///
  /// - Parameter surface: which side of the `Chat | Terminal` segment the scene opens on, or
  ///   `nil` for the scene's own choice (`.chat` for an agent pane). It defaults to `.terminal`
  ///   because most of this suite is about the controller's lifetime. Set before `start()`, as
  ///   the screen does.
  private func makeScene(
    initialTarget: TerminalTarget = .pane(id: "w1:p1"),
    surface: PaneSurface? = .terminal,
    ptyGreeting: String? = nil,
    herdr: (any HerdrControl)? = nil,
    notifications: NotificationCenter = NotificationCenter(),
    wait: @escaping ReconnectWaiter = { try? await Task.sleep(for: $0) },
    openSettlingWindow: Duration = TerminalSession.defaultOpenSettlingWindow,
    coreSizeDeadline: Duration = DeferredPaneBridge.defaultSizeDeadline,
    responder: @escaping @Sendable (String) -> Data?
  ) async -> (TerminalSceneModel, FakeSSHTransport) {
    let (model, transport) = await makeConnection(
      ptyGreeting: ptyGreeting,
      herdr: herdr,
      responder: responder
    )
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: initialTarget,
      wait: wait,
      openSettlingWindow: openSettlingWindow,
      coreSizeDeadline: coreSizeDeadline,
      notifications: notifications
    )
    if let surface { scene.show(surface) }
    return (scene, transport)
  }

  // MARK: - Waiting
  //
  // The waits here are `waitUntil` and `waitUntilSignalled` from `TestWaker.swift`; neither
  // consults a clock. `waitUntil` covers everything reached through `scene` and `session` by
  // observation. `waitUntilSignalled` is for `FakeSSHTransport`'s actor state, woken by its
  // `onActivity` hook. `HerdrAttachTokens.responder` and `PaintedOutput.append` signal the
  // waker themselves.
  //
  // Wait on something that stays true. A transient condition can begin and end between two
  // wake-ups.

  /// The text of every `terminal.input` a caller wrote, decoded out of its base64 payload.
  ///
  /// `TerminalFeed(bridge:)` sends base64 bytes, so the raw line never contains the typed text.
  private func inputTexts(_ log: [String]) -> [String] {
    log.compactMap { line -> String? in
      guard line.hasPrefix("input: "), line.contains("terminal.input") else { return nil }
      let json = String(line.dropFirst("input: ".count))
      guard let data = json.data(using: .utf8),
        let raw = try? JSONSerialization.jsonObject(with: data),
        let object = raw as? [String: Any],
        let encoded = object["bytes"] as? String,
        let bytes = Data(base64Encoded: encoded)
      else { return nil }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  // MARK: - A host that stops answering

  /// A herdr command that never comes back must not park every later switch.
  ///
  /// Every operation on the scene queues behind the one before it, so one unanswered
  /// `execStream` would leave the app drawing normally at 0 % CPU with every control doing
  /// nothing. The only assertion is that the chain moves on.
  ///
  /// Awaiting `settle()` directly would wedge the suite for the reason under test, so it is
  /// awaited through a `Flag`, and the suite's `.timeLimit` catches a chain that never moves.
  @Test("a herdr command that never answers does not park every later switch")
  func anUnansweredCommandDoesNotParkTheChain() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      // Short, because the recovery is under test, not the number.
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // The link stays up and the host stops answering. See `FakeSSHTransport.stopAnswering`.
    await transport.stopAnswering()
    // Demotes the controller and opens an observer, which never answers.
    scene.show(.chat)
    // The switch queued behind it.
    scene.select(.pane(id: "w1:p2"))

    let settled = Flag()
    Task { [scene] in
      await scene.settle()
      settled.raise()
    }
    await settled.wait()
  }

  // MARK: - A core pane

  /// The seeded session with a core terminal beside it, as `CombinedControl` merges them.
  private var treeWithACorePane: SessionTree { tree(withCorePane: "core:t7") }

  /// Two terminals with no agent, so each opens on its terminal surface.
  private var treeWithTwoCorePanes: SessionTree {
    let panes = ["t7", "t8"].map {
      Pane(
        id: CorePaneID.id(forAddress: $0), tabID: "core:tab", workspaceID: "core:workspace",
        title: $0, terminalID: $0)
    }
    let tab = DriverrCore.Tab(
      id: "core:tab", workspaceID: "core:workspace", number: 1, label: "Terminals",
      isAutoNamed: true, panes: panes)
    let workspace = Workspace(
      id: "core:workspace", number: 1, label: "herdr-core", tabs: [tab])
    return SessionTree(workspaces: [workspace])
  }

  /// `agent` is what gives a pane a chat surface.
  private func tree(withCorePane id: String, agent: Agent? = nil) -> SessionTree {
    let pane = Pane(
      id: id, tabID: "core:tab", workspaceID: "core:workspace", title: "t7", agent: agent,
      terminalID: CorePaneID.address(of: id))
    let tab = DriverrCore.Tab(
      id: "core:tab", workspaceID: "core:workspace", number: 1, label: "Terminals",
      isAutoNamed: true, panes: [pane])
    let workspace = Workspace(
      id: "core:workspace", number: 1, label: "herdr-core", tabs: [tab])
    return SessionTree(workspaces: FakeControl.seededTree.workspaces + [workspace])
  }

  private func coreScene(
    _ attacher: FakeCoreAttacher,
    surface: PaneSurface? = .terminal,
    agent: Agent? = nil,
    wait: @escaping ReconnectWaiter = { _ in },
    coreSizeDeadline: Duration = DeferredPaneBridge.defaultSizeDeadline
  ) async -> (TerminalSceneModel, FakeSSHTransport) {
    await makeScene(
      initialTarget: .pane(id: "core:t7"),
      surface: surface,
      herdr: FakeControl(tree: tree(withCorePane: "core:t7", agent: agent), attacher: attacher),
      wait: wait,
      openSettlingWindow: .zero,
      coreSizeDeadline: coreSizeDeadline,
      responder: Self.everythingPaints
    )
  }

  /// What the hosted terminal view measures on a phone, and not `viewportSize`'s default.
  private static let measured = TerminalSize(columns: 52, rows: 48)

  /// A viewer's far end is a test's to hold, so nothing here waits on a clock. No view is laid
  /// out here, so a terminal's first attach is told its size as a view would.
  private func opened(
    _ scene: TerminalSceneModel,
    _ attacher: FakeCoreAttacher
  ) async throws -> FakeCoreViewer {
    scene.start()
    await scene.settle()
    if attacher.log.isEmpty {
      try #require(scene.currentSession).resize(to: Self.measured)
      await waitUntilSignalled("the attach") { !attacher.viewers.isEmpty }
    }
    return try #require(attacher.latest)
  }

  // Pinned, because the deferral below must not reach it.
  @Test("a herdr pane still opens at once, at the default size, with no view up")
  func aHerdrPaneDoesNotWaitForASize() async {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    #expect((await transport.streamLog).contains { $0.contains("--cols 80 --rows 24") })
  }

  /// At the default the desk reflows twice, and the history arrives at the wrong width.
  @Test("a scene's first core attach waits for the view, and attaches at what it measured")
  func theFirstAttachWaitsForTheMeasuredSize() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    scene.start()
    await scene.settle()

    #expect(attacher.log.isEmpty)
    #expect(scene.currentRole == .controller, "no entry, so no view to measure")

    try #require(scene.currentSession).resize(to: Self.measured)
    await waitUntilSignalled("the attach") { !attacher.viewers.isEmpty }

    #expect(attacher.sizes == [Self.measured])
    #expect(try #require(attacher.latest).resizes.isEmpty, "the attach carried the size")
  }

  /// SwiftTerm's own `sizeChanged`, through `DriverrTerminalView`, with no hand on the session.
  @Test("a real view's first layout is what the attach gets", arguments: [
    (CGSize(width: 402, height: 874), 52, 48),
    // SwiftTerm's default grid, where it reports nothing of its own.
    (CGSize(width: 620, height: 460), 80, 25),
  ])
  func aRealViewSizesTheAttach(window size: CGSize, columns: Int, rows: Int) async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    scene.start()
    await scene.settle()

    let session = try #require(scene.currentSession)
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false), size: size)
    await waitUntilSignalled("the attach") { !attacher.viewers.isEmpty }

    #expect(attacher.sizes.map(\.columns) == [columns])
    #expect(attacher.sizes.map(\.rows) == [rows])
    withExtendedLifetime(window) {}
  }

  /// The emulator, the session and the scene's feed in one path, because a stream that painted
  /// on the alternate screen depends on all three to get the normal screen back.
  @Test("a real view leaving the alternate screen tells the viewer, once per exit")
  func aRealViewReportsLeavingTheAlternateScreen() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    scene.start()
    await scene.settle()
    let session = try #require(scene.currentSession)
    let window = HostedProbe.window(
      DriverrTerminalView(session: session, wantsKeyboardFocus: false))
    await waitUntilSignalled("the attach") { !attacher.viewers.isEmpty }
    let viewer = try #require(attacher.latest)

    // A paint goes through the normal screen on its way to the alternate one.
    viewer.paint("\u{1b}[?1047l\u{1b}[?1049h")
    viewer.paint("top")
    viewer.paint("\u{1b}[?1049l$ ")
    await waitUntilSignalled("the exit") { viewer.leftAlternateScreenCount == 1 }

    viewer.paint("more")
    await waitUntilSignalled("the credit") { viewer.consumedByteCount >= 26 }
    #expect(viewer.leftAlternateScreenCount == 1)
    withExtendedLifetime(window) {}
  }

  @Test("what is typed while the attach waits goes out behind it")
  func typingAheadOfTheAttach() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    scene.start()
    await scene.settle()
    let session = try #require(scene.currentSession)

    session.send(text: "ls")
    session.resize(to: Self.measured)
    await waitUntilSignalled("the keys") { attacher.latest?.sent == Data("ls".utf8) }
  }

  @Test("a size carried from the last pane attaches at once")
  func aCarriedSizeAttachesAtOnce() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await makeScene(
      herdr: FakeControl(tree: treeWithACorePane, attacher: attacher),
      responder: Self.everythingPaints
    )
    scene.start()
    await scene.settle()
    try #require(scene.currentSession).resize(to: Self.measured)

    scene.select(.pane(id: "core:t7"))
    await scene.settle()

    #expect(attacher.sizes == [Self.measured])
  }

  /// The failure a view that never lays out has: it must end, and in words.
  @Test("a view that reports no size ends in the open's own sentence, and Retry starts over")
  func noSizeInTime() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher, coreSizeDeadline: .milliseconds(10))
    scene.start()
    await waitUntil("the sentence") { scene.notice != nil }
    await scene.settle()

    #expect(scene.notice == .failed(.channelFailed(reason: "The pane could not be opened.")))
    #expect(attacher.log.isEmpty)
    #expect(scene.currentRole == .ended)
    #expect(scene.model.phase == .connected)

    // Installed, not left in `pending`, where it would have no view to hear from. Nothing here
    // reports a size, so this attach is waiting on a deadline of its own, and at the first one's
    // 10 ms the role can end before it is read.
    scene.coreSizeDeadline = .seconds(60)
    scene.retryOpen()
    await scene.settle()
    #expect(scene.currentRole == .controller)
  }

  @Test("leaving before the size comes attaches nothing")
  func leavingBeforeTheSize() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    scene.start()
    await scene.settle()
    let session = try #require(scene.currentSession)

    scene.close()
    await scene.settle()
    session.resize(to: Self.measured)

    #expect(attacher.log.isEmpty)
  }

  /// Bridge commands go through the control's binary, past `CombinedControl`'s routing, so
  /// this is what would reach `herdr terminal session control` with a core's address.
  @Test("a core pane opens through its attacher with no bridge command, and a herdr pane beside it still does")
  func aCorePaneOpensThroughItsAttacher() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, transport) = await coreScene(attacher)
    _ = try await opened(scene, attacher)

    #expect(attacher.log == ["open t7"])
    #expect(scene.notice == nil)
    #expect(scene.currentRole == .controller)
    #expect(!(await transport.streamLog).contains { $0.contains("t7") })

    // The same scene on the same host still reaches herdr, so the empty log means the routing.
    // `w1:p1` is an agent pane, which would otherwise open on chat, with an observer.
    scene.select(.pane(id: "w1:p1"))
    scene.show(.terminal)
    await scene.settle()
    #expect((await transport.streamLog).contains { $0.contains("terminal session control") })
    #expect(!(await transport.streamLog).contains { $0.contains("t7") })
  }

  @Test("a core pane on the chat surface observes through its attacher")
  func aCorePaneObservesThroughItsAttacher() async throws {
    let attacher = FakeCoreAttacher()
    let agent = FakeControl.seededTree.pane(id: "w1:p1")?.agent
    let (scene, transport) = await coreScene(attacher, surface: .chat, agent: agent)
    _ = try await opened(scene, attacher)

    #expect(attacher.log == ["observe t7"])
    #expect(scene.notice == nil)
    #expect(scene.currentRole == .observer)
    #expect(!(await transport.streamLog).contains { $0.contains("terminal session") })
  }

  /// A core's stream is a pty's: the history is in the emulator, and a tap is encoded locally.
  @Test("a core pane scrolls and clicks locally, and types through its viewer")
  func aCorePaneIsLocal() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)
    let session = try #require(scene.currentSession)

    #expect(!session.scrollsRemotely)
    #expect(!session.clicksRemotely)

    session.send(text: "ls\r")
    await waitUntilSignalled("the keys") { viewer.sent == Data("ls\r".utf8) }
  }

  /// The burst test's other half. The scene's own pump sits between the attachment and the
  /// session, and crediting there would leave an unbounded stream ahead of the main thread.
  @Test("bytes are credited as the session renders them, through the scene's own feed")
  func creditPassesThroughTheScene() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)
    let session = try #require(scene.currentSession)

    var creditedBeforeRendering: Int?
    session.attach { _ in creditedBeforeRendering = viewer.consumedByteCount }

    viewer.paint("12345")
    await waitUntilSignalled("the credit") { viewer.consumedByteCount == 5 }

    #expect(creditedBeforeRendering == 0)
  }

  @Test("a core feed tells its viewer about focus, and a focus report is not typed")
  func focusReachesTheViewer() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)
    let session = try #require(scene.currentSession)

    session.send(text: "\u{1b}[I")
    session.focus(true)
    await waitUntilSignalled("the focus") { viewer.focusChanges == [true] }
    #expect(viewer.sent.isEmpty)
  }

  /// A paint carrying `?1004h` makes the emulator report focus at once. Held, it would be
  /// typed into the program as soon as a controller opened.
  @Test("an observer's focus report is not held for the controller")
  func observerFocusReportIsNotHeld() async throws {
    let attacher = FakeCoreAttacher()
    let agent = FakeControl.seededTree.pane(id: "w1:p1")?.agent
    let (scene, _) = await coreScene(attacher, surface: .chat, agent: agent)
    let observer = try await opened(scene, attacher)
    let session = try #require(scene.currentSession)
    session.resize(to: Self.measured)

    session.send(text: "\u{1b}[I")
    session.send(text: "k")
    // Both must be held, not on their way, or the report reaches the controller's own session
    // on its own, and that session drops it. Nothing signals a write reaching `held`.
    try await Task.sleep(for: .milliseconds(100))
    scene.show(.terminal)
    await scene.settle()

    let controller = try #require(attacher.latest)
    #expect(controller !== observer)
    await waitUntilSignalled("the held key") { !controller.sent.isEmpty }
    #expect(controller.sent == Data("k".utf8))
  }

  /// An observer's bytes are at the terminal's width, so its frame is not worth keeping up.
  @Test("promoting a core observer swaps at once, not on the controller's first frame")
  func aCoreObserverPromotesAtOnce() async throws {
    let attacher = FakeCoreAttacher()
    let agent = FakeControl.seededTree.pane(id: "w1:p1")?.agent
    let (scene, _) = await coreScene(attacher, surface: .chat, agent: agent)
    let observer = try await opened(scene, attacher)
    // A warm view is laid out behind the chat, so it has already measured.
    try #require(scene.currentSession).resize(to: Self.measured)

    scene.show(.terminal)
    await scene.settle()

    #expect(attacher.log == ["observe t7", "open t7"])
    #expect(attacher.sizes == [Self.measured])
    #expect(scene.currentRole == .controller)
    #expect(observer.releaseCount == 1)
  }

  @Test("demoting a core controller opens the observer before the CLOSE")
  func demotingAKeepsWatching() async throws {
    let attacher = FakeCoreAttacher()
    let agent = FakeControl.seededTree.pane(id: "w1:p1")?.agent
    let (scene, _) = await coreScene(attacher, agent: agent)
    let controller = try await opened(scene, attacher)

    scene.show(.chat)
    await scene.settle()

    #expect(attacher.log == ["open t7", "observe t7"])
    #expect(scene.currentRole == .observer)
    #expect(controller.releaseCount == 1)
  }

  @Test("leaving the scene hands every core viewer back")
  func leavingReleases() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    scene.close()
    await scene.settle()

    #expect(viewer.releaseCount == 1)
  }

  /// One terminal refusing an attach says nothing about the host, and `.failed` would.
  @Test("a core open that fails leaves the connection alone, and offers a Retry")
  func aFailedCoreOpen() async throws {
    let attacher = FakeCoreAttacher(refusals: 2)
    let (scene, _) = await coreScene(attacher)
    let refused = TerminalSceneModel.Notice.failed(
      .channelFailed(reason: "The pane could not be opened."))
    scene.start()
    await scene.settle()

    // The first attach is held for its size, so it fails from the stream.
    try #require(scene.currentSession).resize(to: Self.measured)
    await waitUntil("the sentence") { scene.notice != nil }
    #expect(scene.model.phase == .connected)
    #expect(scene.notice == refused)

    // A Retry has the size, so it fails from the open.
    scene.retryOpen()
    await scene.settle()
    #expect(scene.model.phase == .connected)
    #expect(scene.notice == refused)

    scene.retryOpen()
    await scene.settle()
    #expect(scene.notice == nil)
    #expect(attacher.log == ["open t7", "open t7", "open t7"])
  }

  @Test("a program that finished gets the closed banner and no retry")
  func aFinishedTerminalCloses() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    viewer.end()
    await waitUntil("the banner") { scene.notice == .closed }
    await scene.settle()

    #expect(attacher.log == ["open t7"])
    #expect(scene.currentRole == .ended)
  }

  @Test("a core that stopped says so, and no retry follows")
  func aStoppedCore() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    viewer.end(.serverShuttingDown)
    await waitUntil("the sentence") { scene.notice != nil }
    await scene.settle()

    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.serverStoppedMessage)))
    #expect(attacher.log == ["open t7"])
  }

  // MARK: - A kept terminal that lost its program

  private var waitingForAShell: TerminalSceneModel.Notice {
    .failed(.channelFailed(reason: TerminalEndDisposition.awaitingRestartMessage))
  }

  /// One tick of the wait a loss starts, released by the test.
  @MainActor
  private final class Ticks {
    private(set) var asked: [Duration] = []
    private var granted = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    func grant(_ count: Int) {
      granted += count
      while granted > 0, !parked.isEmpty {
        granted -= 1
        parked.removeFirst().resume()
      }
    }

    func wait(_ delay: Duration) async {
      asked.append(delay)
      Waker.signalShared()
      guard granted == 0 else {
        granted -= 1
        return
      }
      await withCheckedContinuation { parked.append($0) }
    }
  }

  @Test("a loss waits for the new shell, quietly through refusals, then reattaches on the paint")
  func aLostTerminalReattaches() async throws {
    let attacher = FakeCoreAttacher()
    let ticks = Ticks()
    let (scene, _) = await coreScene(attacher, wait: { await ticks.wait($0) })
    let first = try await opened(scene, attacher)

    attacher.refuseNext(2)
    first.end(.lost)
    await waitUntil("the sentence") { scene.notice == waitingForAShell }
    await waitUntil("the first wait") { ticks.asked.count == 1 }
    #expect(ticks.asked == [.seconds(2)])
    #expect(scene.currentRole == .ended)

    ticks.grant(2)
    await waitUntil("the third wait") { ticks.asked.count == 3 }
    await waitUntilSignalled("two refusals") { attacher.log.count == 3 }
    #expect(scene.notice == waitingForAShell, "a refusal said something")
    #expect(scene.model.phase == .connected)

    ticks.grant(1)
    await waitUntilSignalled("the new shell") { attacher.log.count == 4 }
    await waitUntilSignalled("a viewer") { attacher.viewers.count == 2 }
    #expect(scene.notice == waitingForAShell, "cleared before anything painted")

    try #require(attacher.latest).paint("$ ")
    await waitUntil("the paint") { scene.currentRole == .controller }
    #expect(scene.notice == nil)
    #expect(Set(attacher.sizes) == [Self.measured], "a retry fell back to the default size")
    // The next tick finds it painted, and stops there. Every tick is granted, because `settle`
    // waits for this task, and a regression must fail here rather than park past the limit.
    ticks.grant(61)
    await scene.settle()
    #expect(attacher.log.count == 4, "an attempt after the paint")
    #expect(ticks.asked.count == 4, "the retries went on after the paint")
  }

  /// `.onChange` fires only on a change, and a restart can fall inside one poll, so nothing
  /// from the tree can be what ends this.
  @Test("a lost terminal that leaves the tree is closed, and the retries stop")
  func aLostTerminalLeaves() async throws {
    let attacher = FakeCoreAttacher()
    let ticks = Ticks()
    let control = FakeControl(tree: treeWithACorePane, attacher: attacher)
    let (scene, _) = await makeScene(
      initialTarget: .pane(id: "core:t7"), herdr: control, wait: { await ticks.wait($0) },
      openSettlingWindow: .zero, responder: Self.everythingPaints)
    let viewer = try await opened(scene, attacher)

    attacher.refuseNext(100)
    viewer.end(.lost)
    await waitUntil("the first wait") { ticks.asked.count == 1 }

    await control.update(to: FakeControl.seededTree)
    await scene.model.session?.refresh()
    ticks.grant(61)
    await waitUntil("the banner") { scene.notice == .closed }
    await scene.settle()

    #expect(attacher.log == ["open t7"])
  }

  /// The scene on a core pane with an agent, read from its chat, and the control that can take
  /// the agent away.
  private func watchedAgentScene(
    _ attacher: FakeCoreAttacher
  ) async throws -> (TerminalSceneModel, FakeControl, FakeCoreViewer) {
    let agent = FakeControl.seededTree.pane(id: "w1:p1")?.agent
    let control = FakeControl(
      tree: tree(withCorePane: "core:t7", agent: agent), attacher: attacher)
    let (scene, _) = await makeScene(
      initialTarget: .pane(id: "core:t7"), surface: .chat, herdr: control,
      openSettlingWindow: .zero, responder: Self.everythingPaints)
    let observer = try await opened(scene, attacher)
    #expect(scene.currentRole == .observer)
    return (scene, control, observer)
  }

  private func agentReturns(_ scene: TerminalSceneModel, _ control: FakeControl) async {
    await control.update(
      to: tree(withCorePane: "core:t7", agent: FakeControl.seededTree.pane(id: "w1:p1")?.agent))
    await scene.model.session?.refresh()
    scene.treeChanged()
    await scene.settle()
  }

  private func agentQuits(_ scene: TerminalSceneModel, _ control: FakeControl) async {
    await control.update(to: tree(withCorePane: "core:t7"))
    await scene.model.session?.refresh()
    scene.treeChanged()
    await scene.settle()
  }

  /// With no agent the pane has no chat, so the keyboard comes up on a terminal an observer
  /// cannot type into. Every keystroke would be held for a controller nothing is opening.
  @Test("an observer whose agent quits starts typing where it stands")
  func anObserverLeftOnTheTerminalIsPromoted() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)
    let session = try #require(scene.currentSession)

    session.send(text: "before")
    await agentQuits(scene, control)

    #expect(observer.promotionCount == 1)
    #expect(scene.currentRole == .controller)
    #expect(scene.currentSession === session, "a new view would take the size from a desk")
    #expect(attacher.log == ["observe t7"])

    session.send(text: "after")
    await waitUntilSignalled("the keys") { observer.sent == Data("beforeafter".utf8) }
    session.resize(to: TerminalSize(columns: 52, rows: 22))
    await waitUntilSignalled("the size") { !observer.resizes.isEmpty }
  }

  @Test("a tree change with the observer already promoted, or still on chat, does nothing")
  func promotionHappensOnce() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)

    scene.treeChanged()
    await scene.settle()
    #expect(observer.promotionCount == 0)

    await agentQuits(scene, control)
    scene.treeChanged()
    await scene.settle()
    #expect(observer.promotionCount == 1)
  }

  @Test("a refused promotion says so, and Retry opens the terminal")
  func aRefusedPromotion() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)
    observer.refusePromotion()

    await agentQuits(scene, control)

    #expect(scene.notice == .failed(.channelFailed(reason: "The pane could not be opened.")))
    #expect(scene.currentRole == .observer)

    scene.treeChanged()
    await scene.settle()
    #expect(observer.promotionCount == 1, "asked again on a tree change")

    // What the view behind the chat measured, so the Retry attaches at once.
    try #require(scene.currentSession).resize(to: Self.measured)
    scene.retryOpen()
    await scene.settle()
    #expect(attacher.log == ["observe t7", "open t7"])
    #expect(scene.currentRole == .controller)
  }

  /// `status` clears ahead of `finished`, measured at 50 to 600 ms, so the attach that follows
  /// can reach a terminal that has gone. The close on the old channel is the true word, and it
  /// can land on either side of the refusal.
  @Test("a promotion the terminal's end refuses says the pane closed, in either order")
  func aPromotionRefusedByTheEnd() async throws {
    let attacher = FakeCoreAttacher()
    var (scene, control, observer) = try await watchedAgentScene(attacher)
    observer.gatePromotion()
    observer.refusePromotion()
    await control.update(to: tree(withCorePane: "core:t7"))
    await scene.model.session?.refresh()
    scene.treeChanged()
    await waitUntilSignalled("the promotion") { observer.promotionCount == 1 }

    observer.end()
    await waitUntilSignalled("the close") { scene.notice == .closed }
    observer.openPromotionGate()
    await scene.settle()
    #expect(scene.notice == .closed)

    let attacherAfter = FakeCoreAttacher()
    (scene, control, observer) = try await watchedAgentScene(attacherAfter)
    observer.refusePromotion()
    await agentQuits(scene, control)
    #expect(scene.notice == .failed(.channelFailed(reason: "The pane could not be opened.")))

    observer.end()
    await waitUntilSignalled("the close") { scene.notice == .closed }
  }

  /// The chat is what is on screen again, so a controller behind it would hold the size for
  /// nothing.
  @Test("a promoted pane whose agent comes back is watched again")
  func aSecondAgentDemotesThePromotedViewer() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)
    await agentQuits(scene, control)
    #expect(scene.currentRole == .controller)

    await agentReturns(scene, control)

    #expect(scene.currentRole == .observer)
    #expect(attacher.log == ["observe t7", "observe t7"])
    #expect(observer.releaseCount == 1)
  }

  /// The step waits its turn in the chain, and the agent can be back by then.
  @Test("a promotion still queued when the agent comes back does not run")
  func aQueuedPromotionRechecksTheSurface() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)
    observer.gatePromotion()
    observer.refusePromotion()

    await control.update(to: tree(withCorePane: "core:t7"))
    await scene.model.session?.refresh()
    scene.treeChanged()
    await waitUntilSignalled("the first promotion") { observer.promotionCount == 1 }
    // Behind the first in the chain, because the notice that would stop it is not up yet.
    scene.treeChanged()
    await control.update(
      to: tree(withCorePane: "core:t7", agent: FakeControl.seededTree.pane(id: "w1:p1")?.agent))
    await scene.model.session?.refresh()
    observer.openPromotionGate()
    await scene.settle()

    #expect(observer.promotionCount == 1)
  }

  /// Nobody is looking at it, and every pane on a host can lose its agent at once.
  @Test("a warm observer whose agent quits stays an observer")
  func aWarmObserverIsNotPromoted() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, control, observer) = try await watchedAgentScene(attacher)
    scene.select(.pane(id: "w1:p1"))
    await scene.settle()

    await control.update(to: tree(withCorePane: "core:t7"))
    await scene.model.session?.refresh()
    scene.treeChanged()
    await scene.settle()

    #expect(observer.promotionCount == 0)
    #expect(scene.role(for: .pane(id: "core:t7")) == .observer)
  }

  @Test("a shell that never comes ends in a sentence and a Retry")
  func aLostTerminalGivesUp() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    attacher.refuseNext(1000)
    viewer.end(.lost)
    await waitUntil("the wait") { scene.notice == waitingForAShell }
    await scene.settle()

    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.reattachFailedMessage)))
    #expect(attacher.log.count == 61)
  }

  @Test("leaving a lost terminal stops the retries")
  func leavingStopsTheRetries() async throws {
    let attacher = FakeCoreAttacher()
    let ticks = Ticks()
    let (scene, _) = await coreScene(attacher, wait: { await ticks.wait($0) })
    let viewer = try await opened(scene, attacher)

    attacher.refuseNext(100)
    viewer.end(.lost)
    await waitUntil("the first wait") { ticks.asked.count == 1 }

    scene.close()
    ticks.grant(61)
    await scene.settle()

    #expect(attacher.log == ["open t7"])
  }

  /// `surface(for:)` is `.terminal` for a pane with no agent, whether or not anyone is looking,
  /// so a warm pane must not take that as leave to open a typing viewer. A core crash ends
  /// every warm pane at once, and each would take the size and hold it.
  @Test(
    "a warm core pane comes back watching, whichever way it ended",
    arguments: [TerminalCloseReason.lost, .streamEnded]
  )
  func aWarmPaneComesBackAsAnObserver(ending reason: TerminalCloseReason) async throws {
    let attacher = FakeCoreAttacher()
    let ticks = Ticks()
    let (scene, _) = await makeScene(
      initialTarget: .pane(id: "core:t7"),
      herdr: FakeControl(tree: treeWithTwoCorePanes, attacher: attacher),
      wait: { await ticks.wait($0) },
      openSettlingWindow: .zero,
      responder: Self.everythingPaints
    )
    _ = try await opened(scene, attacher)

    scene.select(.pane(id: "core:t8"))
    await scene.settle()
    #expect(attacher.log == ["open t7", "observe t7", "open t8"])

    try #require(attacher.viewers.dropFirst().first).end(reason)
    await waitUntil("the entry ending") { scene.role(for: .pane(id: "core:t7")) == .ended }
    ticks.grant(61)
    await waitUntilSignalled("the way back") { attacher.log.count == 4 }
    await scene.settle()

    #expect(attacher.log.last == "observe t7")
    #expect(scene.role(for: .pane(id: "core:t7")) == .observer)
  }

  /// A bridge command opens a stream, so a reattach that fails ends again and meets
  /// `TerminalEndDisposition`'s bound. A refused core attach opens nothing, so there is no
  /// second end, and without this the pane would say "The session ended." with nothing to tap.
  @Test("a reattach the core refuses says so, with a Retry that works")
  func aRefusedReattachSaysSo() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    attacher.refuseNext(1)
    viewer.end(.streamEnded)
    await waitUntilSignalled("the attempt") { attacher.log.count == 2 }
    await scene.settle()

    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.reattachFailedMessage)))
    #expect(scene.model.phase == .connected)

    scene.retryOpen()
    await scene.settle()
    #expect(scene.notice == nil)
    #expect(attacher.log.count == 3)
  }

  @Test("a stream the connection dropped reattaches once, as a TUI pane does")
  func aDroppedConnectionReattaches() async throws {
    let attacher = FakeCoreAttacher()
    let (scene, _) = await coreScene(attacher)
    let viewer = try await opened(scene, attacher)

    viewer.end(.streamEnded)
    await waitUntilSignalled("the reattach") { attacher.log.count == 2 }
    await scene.settle()
    try #require(attacher.latest).paint("$ ")
    await waitUntil("the paint") { scene.currentRole == .controller }

    #expect(scene.notice == nil)
  }

  /// A bounded step goes on running into a scene that has moved past it. `demote` opens a
  /// replacement observer, and if the scene is left while it is suspended, that stream opens
  /// into a scene `close()` has already emptied, and nothing hands it back: a leaked `observe`
  /// stream on the host. `handBack` is `static` because the scene is gone by then.
  ///
  /// A stall, not silence: only a step given up on that then finishes can leak.
  @Test("a switch abandoned mid-flight leaves nothing open on the host")
  func anAbandonedSwitchLeavesNothingOpenOnTheHost() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // Long enough that the switch is abandoned, short enough that it then finishes while
    // the test is still watching.
    await transport.stopAnswering(for: .milliseconds(200))
    // Demotes the controller and opens an observer: the step that gets abandoned.
    scene.show(.chat)
    await scene.settle()
    // Leave the scene while that demote is still in flight.
    scene.close()
    await scene.settle()

    // Every stream this connection opened has been given back. Counted, because a leaked
    // stream is one no list holds.
    //
    // The first two conditions make the third mean something. When `close()` returns the
    // counts are already equal, before the abandoned step opens its stream, so `opened ==
    // closed` alone passes with the guards removed. `releasedStalls` is monotonic, and the
    // observe open has to be present.
    await waitUntilSignalled {
      let released = await transport.releasedStalls
      let log = await transport.streamLog
      let opened = log.filter { $0.hasPrefix("open: ") }
      let closed = log.filter { $0.hasPrefix("close: ") }
      return released >= 1
        && opened.contains { $0.contains("observe") }
        && opened.count == closed.count
    }
  }

  /// An abandoned step must say so, rather than leaving the scene silent.
  ///
  /// `reconcile`, the demote of the pane being left and the open of the one chosen, is one
  /// bounded operation, abandoned here inside `demote`, so `openSurface(for:)` is never reached.
  /// Without the notice the tap would do nothing and say nothing. It is the same
  /// `Notice.failed` and `retryOpen()` an outright open failure uses.
  @Test("an abandoned switch leaves a notice on the target it was about, with a retry")
  func anAbandonedSwitchLeavesANoticeWithRetry() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // The switch to w1:p2 is abandoned inside the demote of w1:p1, the interleaving
    // `anUnansweredCommandDoesNotParkTheChain` exercises, asserted here for what it leaves.
    await transport.stopAnswering()
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    #expect(scene.current == .pane(id: "w1:p2"))
    #expect(scene.notice == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)))
    #expect(scene.currentSession == nil)

    // Once the host answers again, the ordinary retry path opens the pane. The fixture has no
    // "un-stall", so `stopAnswering(for: .zero)` makes future commands answer promptly.
    await transport.stopAnswering(for: .zero)
    scene.retryOpen()
    await scene.settle()

    #expect(scene.notice == nil)
    #expect(scene.currentSession != nil)
  }

  /// A notice written for an abandoned step must not outlive that step landing.
  ///
  /// Here the host answers late rather than never, so the open that missed its deadline goes
  /// on to install under its own failure notice. `enqueue(on:)` watches the abandoned step's
  /// completion and clears the notice, whichever way the step lands; see
  /// `anAbandonedSwitchToChatClearsItsOwnNotice` for a second landing shape.
  @Test("a notice from an abandoned step clears itself once that step lands")
  func anAbandonedStepThatLandsClearsItsOwnNotice() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // Long enough to miss the 50 ms deadline and write the failure notice, short enough
    // that the original open then finishes while the test is still watching.
    await transport.stopAnswering(for: .milliseconds(200))
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    #expect(scene.notice == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)))

    // The abandoned open lands about 150 ms after the deadline gave up on it.
    await waitUntil { scene.notice == nil && scene.currentSession != nil }
  }

  /// The same self-clearing notice, reached through `demote`'s direct swap.
  ///
  /// `show(.chat)` on a controller goes through `readOnly(_:)` and `demote(_:)`, which installs
  /// its replacement observer at `entries[index] = replacement` rather than through
  /// `install(_:)`. A clear scoped to `install(_:)` would leave this notice stuck.
  @Test("an abandoned switch to chat clears its own notice once the observer lands")
  func anAbandonedSwitchToChatClearsItsOwnNotice() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // Long enough to miss the 50 ms deadline and write the failure notice, short enough
    // that the demote's replacement observer then lands while the test is still watching.
    await transport.stopAnswering(for: .milliseconds(200))
    scene.show(.chat)
    await scene.settle()

    #expect(scene.notice == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)))

    // The replacement observer lands about 150 ms after the deadline gave up on the demote.
    await waitUntil { scene.notice == nil && scene.currentSession != nil }
  }

  /// `close()` bounds each hand-back separately, so a first one that hangs does not starve the
  /// rest.
  ///
  /// One `stepDeadline` around the whole loop stops the chain waiting, but the abandoned loop
  /// stays parked on its first iteration, and the second hand-back never starts. Each entry
  /// needs its own deadline.
  ///
  /// A hand-back closes an already-open stream, so `FakeExecStream.close()` has to stall; see
  /// `FakeSSHTransport.awaitCloseStallIfAny(for:)`.
  @Test("close() bounds each hand-back separately, so a first hang does not starve the rest")
  func closeBoundsEachHandBackSeparately() async {
    let (model, transport) = await makeConnection(responder: Self.everythingPaints)
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      stepDeadline: .milliseconds(50),
      notifications: NotificationCenter()
    )
    scene.show(.terminal)
    scene.start()
    await scene.settle()

    // A second warm entry, so `close()` has two hand-backs to bound independently: w1:p1
    // demotes to an observer and w1:p2 becomes the controller.
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    // Only now, once both entries are open: every `close()` after this is under test.
    await transport.stopAnswering()
    scene.close()
    await scene.settle()

    // Both hand-backs were attempted, not one and then the other after the first's stall.
    await waitUntilSignalled {
      let log = await transport.streamLog
      return log.filter { $0.hasPrefix("unanswered: close") }.count >= 2
    }
  }

  // MARK: - Switching

  @Test("switching to an observed pane paints from its observer and swaps on the first frame")
  func switchingToAnObservedPaneSwapsOnTheFirstFrame() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()

    // Leave w1:p1 — it becomes an observer — then come back to it.
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)

    let observerSession = try #require(scene.session(for: .pane(id: "w1:p1")))
    scene.select(.pane(id: "w1:p1"))

    // Instantly: the emulator that was already warm is what is on screen, before any
    // await has had the chance to run.
    #expect(scene.currentSession === observerSession)
    #expect(scene.isOpening == false, "a warm pane must never show the opening beat")

    await scene.settle()
    // The controller is open but has not painted, so the observer is still the view.
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)
    let controls = await transport.streamedCommands.filter {
      $0.contains("terminal session control") && $0.contains("term_w1p1")
    }
    #expect(controls.count == 2, "one controller for the first open, one for the return")

    await transport.emitOnStreams(Self.frame("live\r\n"))
    await waitUntil { scene.role(for: .pane(id: "w1:p1")) == .controller }
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)
    #expect(scene.currentSession !== observerSession, "the views never swapped")
    #expect(scene.entries.filter { $0.target == .pane(id: "w1:p1") }.count == 1)

    // And the observer it was painting from is handed back.
    await waitUntilSignalled {
      await transport.streamLog.contains {
        $0.hasPrefix("close:") && $0.contains("observe") && $0.contains("term_w1p1")
      }
    }
    let log = await transport.streamLog
    #expect(
      log.contains {
        $0.hasPrefix("close:") && $0.contains("observe") && $0.contains("term_w1p1")
      },
      "the observer is still streaming a pane nobody reads it for"
    )
  }

  @Test("leaving a pane opens an observer and only then releases the controller")
  func leavingOpensAnObserverBeforeReleasing() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()

    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    let log = await transport.streamLog
    let observed = try #require(
      log.firstIndex {
        $0.hasPrefix("open:") && $0.contains("observe") && $0.contains("term_w1p1")
      }
    )
    let released = try #require(log.firstIndex { $0.contains("terminal.release") })
    #expect(
      observed < released,
      "a pane with neither an observer nor a controller open is a pane nobody is reading"
    )
  }

  /// The session's write queue is not the bridge, so the scene lets it drain before
  /// `terminal.release`. Keystrokes on a slow link must not land after the hand-back, where
  /// herdr no longer takes them from this client.
  @Test("keystrokes typed before leaving a pane reach herdr before its release")
  func queuedInputGoesOutBeforeTheRelease() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    let session = try #require(scene.currentSession)

    await transport.delayInput(by: .milliseconds(50))
    for key in ["a", "b", "c", "d", "e"] { session.send(text: key) }
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()
    await waitUntilSignalled {
      await transport.streamLog.contains { $0.contains("terminal.release") }
    }
    // A keystroke still in flight at the release is refused by the closed stream and leaves
    // no line at all, so there is no event to wait for. Wait out the delay instead, with room
    // to spare: five 50 ms writes in a row take 250 ms.
    try? await Task.sleep(for: .milliseconds(500))

    let log = await transport.streamLog
    #expect(inputTexts(log).joined() == "abcde", "keystrokes were dropped at the release")
    let lastKey = try #require(log.lastIndex { $0.contains("terminal.input") })
    let released = try #require(log.firstIndex { $0.contains("terminal.release") })
    #expect(lastKey < released, "a keystroke sent after the release reaches nobody")
  }

  /// The wait for the write queue is bounded. A write that never finishes must not keep
  /// herdr's attach token, which would lock the pane on the user's own desk.
  @Test("a stuck keystroke does not hold the release past the drain bound")
  func aStuckWriteDoesNotHoldTheRelease() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    let session = try #require(scene.currentSession)

    await transport.delayInput(by: .seconds(3600))
    session.send(text: "x")
    let left = ContinuousClock.now
    scene.select(.pane(id: "w1:p2"))
    await waitUntilSignalled {
      await transport.streamLog.contains { $0.contains("terminal.release") }
    }

    // Three times `TerminalSession.defaultWriteDrainLimit`, the bound this is about.
    #expect(ContinuousClock.now - left < .seconds(3))
  }

  @Test("the warm set never exceeds K + 1 and never evicts the current target")
  func theWarmSetStaysBounded() async {
    let (scene, _) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()

    for id in ["w1:p2", "w1:p3", "w2:p1", "w3:p1"] {
      scene.select(.pane(id: id))
      await scene.settle()
      #expect(scene.warm.observers.count <= WarmPaneSet.defaultK)
      #expect(scene.warm.observers.contains(scene.current) == false)
    }

    #expect(scene.current == .pane(id: "w3:p1"))
    #expect(scene.warm.observers == [.pane(id: "w1:p3"), .pane(id: "w2:p1")])
    // One live terminal per warm entry and no more: the first two panes were evicted.
    #expect(scene.entries.count == WarmPaneSet.defaultK + 1)
  }

  @Test("switching to a cold pane shows nothing rather than another pane's frame")
  func aColdPaneNeverShowsAStaleFrame() async throws {
    let (scene, _) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    let first = try #require(scene.currentSession)

    scene.select(.pane(id: "w2:p1"))
    // Driven, not read: the opening beat is about a terminal that has not painted yet, and a
    // pane opened on its chat is not waiting on one.
    scene.show(.terminal)
    #expect(
      scene.currentSession == nil,
      "a cold pane already showing a session would be showing the pane you just left"
    )
    #expect(scene.isOpening)

    await scene.settle()
    #expect(scene.currentSession !== first)
  }

  // MARK: - The promotion gap

  @Test("text typed while the controller is opening reaches it, in order")
  func heldInputReachesTheController() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    // Back to an observed pane: its observer is on screen and its controller is not open
    // yet, which is exactly the gap. `select` is synchronous, so this is typed into it.
    scene.select(.pane(id: "w1:p1"))
    scene.currentSession?.send(text: "who")
    scene.currentSession?.send(text: "ami\n")

    await scene.settle()
    await waitUntilSignalled {
      inputTexts(await transport.streamLog).joined().count >= "whoami\n".count
    }

    // Joined, because how the bytes split into writes is not what the user sees. The write
    // queue delivers the sends one at a time, so the controller can come up between them.
    let typed = inputTexts(await transport.streamLog).joined()
    #expect(typed == "whoami\n", "held keystrokes must arrive, once, in the order typed")
  }

  // MARK: - Scroll, and the desk

  @Test("leaving a scrolled pane scrolls it back, and returning restores the place")
  func scrollIsHandedBackAndRestored() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()

    // Scroll the pane up five rows and let herdr answer: only an *answered* scroll counts,
    // which is what `TerminalSession.scrolledRows` is careful about.
    let session = try #require(scene.currentSession)
    session.scroll(.up, lines: 5)
    await waitUntilSignalled {
      await transport.streamLog.contains { $0.contains("terminal.scroll") }
    }
    await transport.emitOnStreams(Self.frame("scrolled\r\n"))
    await waitUntil { session.scrolledRows == 5 }
    #expect(session.scrolledRows == 5)

    scene.select(.pane(id: "w1:p2"))
    await scene.settle()

    let log = await transport.streamLog
    let downs = log.filter { $0.contains("terminal.scroll") && $0.contains("\"down\"") }
    #expect(downs.count == 1, "the desk must be put back where it was found, and once")
    // `#require`, not `downs[0]`: `#expect` does not stop the test, so a subscript on an
    // empty array traps and takes the whole bundle down.
    #expect(try #require(downs.first).contains("\"lines\":5"))
    let scrolledBack = try #require(
      log.firstIndex { $0.contains("terminal.scroll") && $0.contains("\"down\"") }
    )
    let released = try #require(log.firstIndex { $0.contains("terminal.release") })
    #expect(scrolledBack < released, "a scroll sent after the release reaches nobody")

    // And coming back re-issues one scroll of the rows it had.
    scene.select(.pane(id: "w1:p1"))
    await scene.settle()
    await waitUntilSignalled {
      await transport.streamLog.filter {
        $0.contains("terminal.scroll") && $0.contains("\"up\"") && $0.contains("\"lines\":5")
      }.count == 2
    }
    let ups = await transport.streamLog.filter {
      $0.contains("terminal.scroll") && $0.contains("\"up\"") && $0.contains("\"lines\":5")
    }
    #expect(ups.count == 2, "one scroll up from the drag, one to put the phone back")
  }

  // MARK: - What the navigation bar is allowed to say

  /// The chat side must not borrow the terminal's OSC title. That title is whatever the running
  /// program last wrote, and says nothing true about a conversation; the strip and the sheet use
  /// the pane's own title.
  @Test("the chat's title is the pane's own, never the session's OSC title")
  func chatTitleIgnoresTheSessionTitle() async throws {
    let (scene, _) = await makeScene(surface: .terminal, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    // Asserts the pane's own title on the chat, so the two sides cannot agree by accident.
    scene.show(.chat)
    await scene.settle()
    #expect(scene.title == "terminal wiring")
    #expect(scene.title == scene.currentPane?.title)
  }

  /// The subtitle is the host alone. The segment is a band under the bar, so the title slot is
  /// free for the pane's name.
  @Test("the subtitle names the host, with the pane's name left to the title")
  func subtitleNamesTheHostAlone() async throws {
    let (scene, _) = await makeScene(surface: .chat, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    #expect(scene.title == "terminal wiring")
    #expect(scene.subtitle == host.displayName)
  }

  /// A shell scene is already titled with the host, so a subtitle would add no fact.
  @Test("a scene already titled with the host has no subtitle to add")
  func subtitleIsAbsentWhenItWouldRepeatTheTitle() async throws {
    let (scene, _) = await makeScene(
      initialTarget: .shell,
      surface: nil,
      responder: Self.observersOnly
    )

    #expect(scene.title == host.displayName)
    #expect(scene.subtitle == nil)
  }

  // MARK: - Reading a pane versus driving it

  /// Asserted against the wire: a controller opened and handed back looks identical on screen
  /// to one never opened.
  ///
  /// A bridge controller is exclusive and resizes the pane's PTY to the phone on the user's
  /// desk while held. An `observe` stream does neither and costs the same per byte. That price
  /// is accepted for driving a pane, not for reading its chat.
  @Test("an agent pane opened on its chat takes no controller, only a read-only observer")
  func readingAPaneTakesNoController() async throws {
    let (scene, transport) = await makeScene(surface: nil, responder: Self.everythingPaints)

    scene.start()
    await scene.settle()

    #expect(scene.surface == .chat, "an agent pane opens on the side that reads it")
    let commands = await transport.streamedCommands
    #expect(
      commands.contains { $0.contains("terminal session control") } == false,
      "reading a conversation took the pane's attach token: \(commands)"
    )
    #expect(
      commands.contains { $0.contains("terminal session observe") && $0.contains("term_w1p1") },
      "the pane being read is not being watched at all: \(commands)"
    )
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)
  }

  @Test("switching to the terminal takes the controller, and the pane is typeable")
  func showingTheTerminalTakesTheController() async throws {
    let (scene, transport) = await makeScene(surface: nil, responder: Self.observersOnly)
    scene.start()
    await scene.settle()

    scene.show(.terminal)
    await scene.settle()

    let controls = await transport.streamedCommands.filter {
      $0.contains("terminal session control") && $0.contains("term_w1p1")
    }
    #expect(controls.count == 1, "the Terminal side is what asks for the token")

    // Typed in the promotion gap, when somebody who just asked for the terminal is most
    // likely to type.
    scene.currentSession?.send(text: "ls\n")
    await transport.emitOnStreams(Self.frame("live\r\n"))
    await waitUntil { scene.role(for: .pane(id: "w1:p1")) == .controller }
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)

    await waitUntilSignalled { !inputTexts(await transport.streamLog).isEmpty }
    #expect(inputTexts(await transport.streamLog) == ["ls\n"], "the pane is not typeable")
  }

  @Test("switching back to the chat hands the controller back and keeps the emulator")
  func showingTheChatHandsTheControllerBack() async throws {
    let (scene, transport) = await makeScene(
      surface: .terminal,
      responder: Self.everythingPaints
    )
    scene.start()
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)

    scene.show(.chat)
    await scene.settle()

    let log = await transport.streamLog
    #expect(
      log.contains { $0.contains("terminal.release") },
      "the desk is still locked and reflowed while somebody is only reading: \(log)"
    )
    // The observer opens before the release: a pane with neither open is one nobody reads.
    let observed = try #require(
      log.firstIndex {
        $0.hasPrefix("open:") && $0.contains("observe") && $0.contains("term_w1p1")
      }
    )
    let released = try #require(log.firstIndex { $0.contains("terminal.release") })
    #expect(observed < released)

    // Nothing was torn down. What goes back is the desk, not the terminal.
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)
    #expect(scene.session(for: .pane(id: "w1:p1")) != nil, "the emulator went with the token")
    #expect(scene.entries.count == 1)
    // The hand-back ends the controller's stream from this side. Read as a close, it would
    // draw "This pane was closed." over a live chat.
    #expect(scene.notice == nil, "a pane handed back to read it is not a pane that closed")
  }

  @Test("a switch away and straight back leaves no closed banner on a pane still live")
  func aSwitchAwayAndBackLeavesNoClosedBanner() async throws {
    let (scene, _) = await makeScene(surface: .terminal, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)

    // Both taps before either is served, so the first tap's hand-back runs after the second
    // has put the first pane back on screen, and a stale close lands after `select`'s own
    // notice clear. An A, B, A that settles in between cannot show this.
    scene.select(.pane(id: "w1:p2"))
    scene.select(.pane(id: "w1:p1"))
    await scene.settle()

    #expect(scene.current == .pane(id: "w1:p1"))

    // Waited for, because coming back goes through the promotion gap. A stale end that cannot
    // tell its target's next stream from the one it ended would drop the new controller and
    // leave the pane read-only.
    await waitUntil { scene.role(for: .pane(id: "w1:p1")) == .controller }
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller, "the pane came back live")
    #expect(scene.notice == nil, "a pane the scene handed back and took again is not closed")
  }

  @Test("a pane with no agent has no chat to read, so it still gets its terminal at once")
  func aPaneWithNoAgentIsUnaffected() async throws {
    // The plain shell first: its own pty.
    let (shell, _) = await makeScene(
      initialTarget: .shell,
      surface: nil,
      ptyGreeting: "carson@workbox:~$ ",
      responder: Self.everythingPaints
    )
    shell.start()
    await shell.settle()
    #expect(shell.showsSurfaceSegment == false, "the plain shell has no conversation")
    #expect(shell.surface == .terminal)
    #expect(shell.role(for: .shell) == .local, "the shell did not get its pty")

    // And `w1:p3`, the fixture's agentless `swift test` pane: no segment, straight into the
    // terminal, controller immediately.
    let (pane, transport) = await makeScene(
      initialTarget: .pane(id: "w1:p3"),
      surface: nil,
      responder: Self.everythingPaints
    )
    pane.start()
    await pane.settle()
    #expect(pane.showsSurfaceSegment == false)
    #expect(pane.surface == .terminal)
    #expect(pane.role(for: .pane(id: "w1:p3")) == .controller)
    let commands = await transport.streamedCommands
    #expect(
      commands.contains { $0.contains("terminal session control") && $0.contains("term_w1p3") },
      "a shell pane must open the way it always has: \(commands)"
    )
  }

  /// `w1:p2` is the fixture's blocked agent, which the host screen's Needs you row routes to.
  @Test("a pane opened from Needs you while blocked shows its conversation, holding nothing")
  func aBlockedPaneOpensReadOnly() async throws {
    let (scene, transport) = await makeScene(
      initialTarget: .pane(id: "w1:p2"),
      surface: nil,
      responder: Self.everythingPaints
    )
    scene.start()
    await scene.settle()

    #expect(scene.showsSurfaceSegment)
    #expect(scene.surface == .chat)
    let commands = await transport.streamedCommands
    #expect(
      commands.contains { $0.contains("terminal session control") } == false,
      "answering a blocked agent locked its pane against the desk it is blocked on"
    )
    #expect(scene.role(for: .pane(id: "w1:p2")) == .observer)
  }

  /// A refusal is herdr's answer to a controller nobody could be given, so it can only
  /// happen where a controller was actually asked for. Reading a pane somebody else is
  /// driving must therefore say nothing at all — and Take over has to still work from the
  /// side that does ask.
  @Test("a pane another device holds is only refused where the controller was asked for")
  func onlyTheTerminalSideCanBeRefused() async throws {
    let (scene, transport) = await makeScene(
      surface: nil,
      responder: { command in
        guard command.contains("terminal session control") else { return Self.frame("read\r\n") }
        return command.contains("--takeover")
          ? Self.frame("taken\r\n") : Self.refusal(of: "term_w1p1")
      }
    )
    scene.start()
    await scene.settle()

    // Asserted on the wire first. A refusal arrives on the stream's own task, so `notice`
    // read right after `settle()` can be `nil` only because the record has not landed. The
    // command log only grows, so it cannot answer early.
    let whileReading = await transport.streamedCommands
    #expect(
      whileReading.contains { $0.contains("terminal session control") } == false,
      "a pane being read asked for a controller, so it can be refused one: \(whileReading)"
    )
    #expect(scene.notice == nil, "reading a pane somebody else drives said it was unavailable")

    scene.show(.terminal)
    await waitUntil { scene.notice == .refused }
    #expect(scene.notice == .refused, "the Take over prompt is unreachable")

    scene.takeOver()
    await scene.settle()
    let afterTheTap = await transport.streamedCommands
    #expect(afterTheTap.contains { $0.contains("--takeover") })
    await waitUntil { scene.notice == nil }
    #expect(scene.notice == nil)
  }

  @Test("a link that drops while a pane is being read gets it back with no controller")
  func aReconnectWhileReadingTakesNoController() async throws {
    let (scene, _, supply) = await makeReconnectingScene(surface: nil)
    scene.start()
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)

    await dropLink(scene, supply)
    await scene.settle()

    #expect(
      scene.role(for: .pane(id: "w1:p1")) == .observer,
      "coming back took the token the way in deliberately did not"
    )
    let controls = await supply.latest?.streamedCommands.filter {
      $0.contains("terminal session control")
    }
    #expect(controls?.isEmpty == true, "the reconnect opened \(controls ?? [])")
  }

  /// The one pane the bridge cannot open at all: a herdr too old to report a terminal id.
  ///
  /// `observe` needs a terminal id too, so reading it holds nothing, and driving it means a pty
  /// with `agent attach` typed into it, which holds the pane as hard as a controller. So the way
  /// back to the chat ends it rather than demoting it: the desk matters more than the emulator.
  @Test("an agent pane with no terminal id is read without attaching to it")
  func aPaneWithNoTerminalIDIsNeverAttachedJustToBeRead() async throws {
    let control = FakeControl()
    await control.update(to: Self.treeWithNoTerminalID)
    let (scene, _) = await makeScene(
      initialTarget: .pane(id: "w9:p9"),
      surface: nil,
      ptyGreeting: "carson@workbox:~$ ",
      herdr: control,
      responder: Self.everythingPaints
    )

    scene.start()
    await scene.settle()

    #expect(scene.showsSurfaceSegment, "an agent pane has a conversation whatever herdr is")
    #expect(scene.role(for: .pane(id: "w9:p9")) == nil, "reading it attached to it")
    #expect(scene.isOpening == false, "the chat is not waiting on a terminal")

    scene.show(.terminal)
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w9:p9")) == .local, "the Terminal side has no terminal")

    scene.show(.chat)
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w9:p9")) == nil, "the pane is still attached")
    #expect(scene.session(for: .pane(id: "w9:p9")) == nil)
  }

  /// One agent pane on a herdr too old to name a terminal for it.
  private static let treeWithNoTerminalID = SessionTree(
    workspaces: [
      Workspace(
        id: "w9",
        number: 9,
        label: "old",
        tabs: [
          Tab(
            id: "w9:t1",
            workspaceID: "w9",
            number: 1,
            label: "agent",
            panes: [
              Pane(
                id: "w9:p9",
                tabID: "w9:t1",
                workspaceID: "w9",
                title: "old herdr",
                agent: Agent(name: "Claude", kind: "claude", status: .blocked),
                terminalID: nil,
                directory: "~"
              )
            ]
          )
        ]
      )
    ],
    focusedPaneID: "w9:p9"
  )

  // MARK: - Closed reasons

  @Test("a refused open offers Take over, and only a tap uses --takeover")
  func aRefusalOffersTakeOver() async throws {
    let (scene, transport) = await makeScene(responder: { command in
      guard command.contains("terminal session control") else { return nil }
      return command.contains("--takeover")
        ? Self.frame("taken\r\n") : Self.closed(Self.refusal)
    })

    scene.start()
    await waitUntil { scene.notice == .refused }
    #expect(scene.notice == .refused, "the user is not told another device has this pane")
    let before = await transport.streamedCommands
    #expect(
      before.contains { $0.contains("--takeover") } == false,
      "evicting whoever holds the pane — most likely the user's own desk — takes a tap"
    )

    scene.takeOver()
    await scene.settle()
    let after = await transport.streamedCommands
    #expect(after.contains { $0.contains("--takeover") })
    await waitUntil { scene.notice == nil }
    #expect(scene.notice == nil)
  }

  @Test("losing the controller to another device shows the take-back banner")
  func aTakeoverElsewhereShowsTheBanner() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    #expect(scene.notice == nil)

    await transport.emitOnStreams(Self.closed("terminal attach taken over"))

    await waitUntil { scene.notice == .takenOver }
    #expect(scene.notice == .takenOver)
    // The last frame stays on screen under the banner: it is what the pane looked like.
    #expect(scene.currentSession != nil)
  }

  @Test("an ordinary close keeps today's closed banner")
  func anOrdinaryCloseKeepsTheBanner() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await transport.emitOnStreams(Self.closed("terminal term_w1p1 exited"))

    await waitUntil { scene.notice == .closed }
    #expect(scene.notice == .closed)
  }

  /// `select` returns early for the pane already on screen, so it cannot be the only thing
  /// that clears a notice. A later stream's first frame proves the pane is answering, so it
  /// clears the closed banner.
  @Test("a later stream that paints clears the closed banner")
  func aLaterStreamThatPaintsClearsTheClosedBanner() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await transport.emitOnStreams(Self.closed("terminal target term_w1p1 not found"))
    await waitUntil { scene.notice == .closed }
    #expect(scene.notice == .closed, "the premise: the stream's close drew the banner")

    scene.show(.chat)
    await scene.settle()
    await waitUntil("the chat never re-observed the pane") {
      scene.role(for: .pane(id: "w1:p1")) == .observer
    }
    await waitUntil { scene.notice == nil }
    #expect(scene.notice == nil, "a painting pane still says it was closed")
  }

  /// The same rule, from a stream the scene has put down. `AsyncThrowingStream` still
  /// hands over what it had buffered after its consumer is cancelled. So a controller that
  /// was waiting for its first frame, and was cancelled when the observer's close arrived,
  /// can still deliver that frame afterwards. The frame is stale, and the cancelled pump
  /// never reports an end, so clearing the close for it leaves no banner at all.
  ///
  /// The order has to be forced. The main actor is held while both records are buffered,
  /// so the observer's close is queued ahead of the controller's frame and the frame
  /// arrives at a pump that the close has already cancelled.
  @Test("a frame from a controller the scene put down does not clear the closed banner")
  func aCancelledControllersFrameKeepsTheClosedBanner() async throws {
    // Leave w1:p1 and come back: the observer is on screen and the return's controller is
    // open with no frame yet.
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()
    scene.select(.pane(id: "w1:p1"))
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer, "the premise: the promotion gap")
    #expect(await transport.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2)

    let emitted = Task.detached {
      let closes = await transport.emitOnStreams(
        Self.closed("terminal term_w1p1 exited"),
        matching: Self.isObserveOf("term_w1p1")
      )
      try? await Task.sleep(for: .milliseconds(100))
      let frames = await transport.emitOnStreams(
        Self.frame("stale\r\n"),
        matching: Self.isControlOf("term_w1p1")
      )
      return (closes, frames)
    }
    Self.holdTheMainActor(for: 0.5)
    let (closes, frames) = await emitted.value
    #expect(closes == 1 && frames == 1, "the fixture has to write both records")

    await waitUntil { scene.notice == .closed }
    await scene.settle()
    #expect(scene.notice == .closed, "a stale frame cleared the pane's closed banner")
  }

  /// Blocks the calling thread without suspending, so nothing queued on the main actor runs
  /// until it returns. Synchronous because `Thread.sleep` is unavailable in async code.
  private static func holdTheMainActor(for seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }

  /// `.refused` and `.takenOver` say another device holds the pane. An observer paints
  /// beside that controller, so its frames do not make either notice untrue. Here the
  /// observer opens after the take-over, so its first frame reaches `streamPainted` while
  /// the notice stands.
  @Test("an observer that paints leaves a take-over notice standing")
  func anObserverThatPaintsKeepsTheTakeOverNotice() async throws {
    let (scene, transport) = await makeScene(responder: { command in
      command.contains("terminal session control")
        ? Self.frame("live\r\n") : Self.frame("observed\r\n")
    })
    scene.start()
    await scene.settle()
    await waitUntil { scene.role(for: .pane(id: "w1:p1")) == .controller }

    let written = await transport.emitOnStreams(
      Self.closed("terminal attach taken over"),
      matching: Self.isControlOf("term_w1p1")
    )
    #expect(written == 1, "the fixture has to end the controller")
    await waitUntil { scene.notice == .takenOver }
    #expect(scene.notice == .takenOver, "the premise: another device took the pane")

    scene.show(.chat)
    await scene.settle()
    await waitUntil("the chat never observed the pane") {
      scene.role(for: .pane(id: "w1:p1")) == .observer
    }
    await scene.settle()
    #expect(scene.notice == .takenOver, "an observer's frame took away the Take back offer")
  }

  /// herdr's own close carries a `terminal.closed` record. A bare end carries nothing: the link
  /// died while the phone was suspended, herdr restarted, the remote command exited. None of
  /// those closed the pane, and a closed banner would send the user away from a live session.
  @Test("a stream that ends with no record is reattached, not reported as a close")
  func aBareStreamEndReattachesInsteadOfClosing() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    let opensBefore = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opensBefore.count == 1, "the premise: one controller open on this pane")

    // The link stays authenticated and herdr says nothing: only this pane's stream stops.
    let ended = await transport.endStreams { $0.contains("term_w1p1") }
    #expect(ended == 1, "the fixture has to end a stream, or this test asserts nothing")

    await waitUntilSignalled {
      await transport.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2
    }
    let opensAfter = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opensAfter.count == 2, "the pane was not reattached")
    // The settle lets the notice assertion fail. The wait above wakes on the log append,
    // before the scene has handled the open.
    await scene.settle()
    #expect(scene.notice == nil, "a channel ending was reported to the user as a pane closing")
  }

  @Test("a second bare end with no frame between gives up rather than saying it was closed")
  func aSecondBareStreamEndFailsRatherThanClosing() async throws {
    // Nothing paints, so the reattach's stream is the second consecutive silence: a herdr
    // that kills every control stream, which `TerminalEndDisposition`'s bound stops looping on.
    let (scene, transport) = await makeScene(responder: { _ in nil })
    scene.start()
    await scene.settle()

    await transport.endStreams { $0.contains("term_w1p1") }
    await waitUntilSignalled {
      await transport.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2
    }
    await transport.endStreams { $0.contains("term_w1p1") }

    await waitUntil { scene.notice != nil }
    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.reattachFailedMessage)),
      "giving up has to say so, with a Retry — never the closed banner"
    )
    #expect(scene.notice != .closed)
    let opens = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opens.count == 2, "the bound is one automatic attempt, and it was exceeded")
  }

  /// The inverse of `aBareStreamEndReattachesInsteadOfClosing`: the bridge process exits
  /// nonzero and says why on stderr. A process that answered is not reattached, and the bar
  /// carries herdr's own sentence.
  ///
  /// The wiring end to end: `FakeSSHTransport`, `ExecStreamBridge`'s stderr drain,
  /// `HerdrStream.end`, `BridgeFramePump`, `TerminalEndDisposition`, the notice. Each layer has
  /// its own cheap test; only this shows they are connected.
  @Test("a bridge process that exits with a reason says it, and reattaches nothing")
  func aFailedBridgeProcessReportsItsReasonWithoutReattaching() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    let opensBefore = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opensBefore.count == 1, "the premise: one controller open on this pane")

    let failed = await transport.failStreams(
      matching: { $0.contains("term_w1p1") },
      exitStatus: 1,
      standardError: "herdr: failed to request terminal attach: pane not found\n"
    )
    #expect(failed == 1, "the fixture has to fail a stream, or this test asserts nothing")

    await waitUntil { scene.notice != nil }
    #expect(
      scene.notice
        == .failed(
          .channelFailed(
            reason: "herdr said: failed to request terminal attach: pane not found"
          )
        ),
      "the bar has to carry herdr's own words, attributed and with the prefix off"
    )
    #expect(scene.notice != .closed, "a process that refused did not close the pane")

    let opensAfter = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(
      opensAfter.count == 1,
      "a command that ran and refused answers the same way again — Retry is the way back"
    )
  }

  @Test("a bridge process that exits saying nothing still gets a sentence and no reattach")
  func aSilentBridgeFailureStillReportsSomething() async throws {
    // The status alone. herdr wrote nothing, so the fixed sentence is what is left, and it
    // still must not be the closed banner: the pane behind the process may be running.
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await transport.failStreams(matching: { $0.contains("term_w1p1") }, exitStatus: 127)

    await waitUntil { scene.notice != nil }
    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.paneFailedMessage))
    )
    let opens = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opens.count == 1)
  }

  /// A pane herdr's own snapshot no longer lists is closed, whatever its stream did or did
  /// not manage to say on the way out — the one thing that keeps a real close reportable
  /// when its record is the thing that got lost.
  @Test("a bare end on a pane that has left the tree still reports the close")
  func aBareStreamEndOnAVanishedPaneStillCloses() async throws {
    let control = FakeControl(tree: FakeControl.seededTree)
    let (scene, transport) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await control.update(to: .empty)
    await scene.model.session?.refresh()
    await transport.endStreams { $0.contains("term_w1p1") }

    await waitUntil { scene.notice == .closed }
    #expect(scene.notice == .closed)
  }

  /// The chat's half. A pane being read holds only an `observe` stream, so the entry's role has
  /// to move to `.ended` for an observer too, and `openObserver`'s guard must not count a dead
  /// entry as open. With either missing, nothing reopens.
  @Test("a bare end on a pane being read reattaches its observer")
  func aBareStreamEndOnTheChatReattachesTheObserver() async throws {
    let (scene, transport) = await makeScene(surface: .chat, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer, "the premise: the pane is read")
    let before = await transport.streamedCommands.filter(Self.isObserveOf("term_w1p1"))
    #expect(before.count == 1)

    let ended = await transport.endStreams { $0.contains("term_w1p1") }
    #expect(ended == 1, "the fixture has to end a stream, or this test asserts nothing")

    await waitUntilSignalled("the pane being read was never re-observed") {
      await transport.streamedCommands.filter(Self.isObserveOf("term_w1p1")).count == 2
    }
    // A second wait, for the entry rather than the wire. The signal above fires on
    // `execStream`'s log append, before the scene has installed the replacement entry.
    await waitUntil("the re-observed pane never went back to being read") {
      scene.role(for: .pane(id: "w1:p1")) == .observer
    }
    let after = await transport.streamedCommands.filter(Self.isObserveOf("term_w1p1"))
    #expect(after.count == 2, "the pane being read was not re-observed")
    #expect(scene.notice == nil, "a channel ending was reported to the reader as a close")
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer, "and it is being read again")
  }

  /// herdr's `paneClosed` finishes an observe stream cleanly, and the observer pump has to
  /// report it, or a pane closed on the desk leaves no banner on the chat. A stated close does
  /// not reattach.
  @Test("a pane herdr closes under a reader still says so on the chat")
  func aStatedCloseOnTheChatIsReported() async throws {
    let (scene, transport) = await makeScene(surface: .chat, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await transport.emitOnStreams(Self.closed("terminal term_w1p1 exited"))

    await waitUntil { scene.notice == .closed }
    #expect(scene.notice == .closed)
    let opens = await transport.streamedCommands.filter(Self.isObserveOf("term_w1p1"))
    #expect(opens.count == 1, "a pane herdr said was gone was silently re-opened")
  }

  // MARK: - The two ends herdr states that are not a pane closing

  /// herdr answers a shutdown with a `terminal.closed` record whose reason is `server is
  /// shutting down`. Read as `.other`, it would draw "This pane was closed." over a pane
  /// nobody closed.
  @Test("a herdr that stops says so, and never says the pane was closed")
  func aHerdrShutdownIsNotAClose() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    let written = await transport.emitOnStreams(
      Self.closed("server is shutting down"),
      matching: Self.isControlOf("term_w1p1")
    )
    #expect(written == 1, "the fixture has to reach a live stream, or this test asserts nothing")

    await waitUntil { scene.notice != nil }
    #expect(
      scene.notice
        == .failed(.channelFailed(reason: TerminalEndDisposition.serverStoppedMessage)),
      "a herdr that stopped has to say so, with a Retry — never the closed banner"
    )
    #expect(scene.notice != .closed)
    // Nothing is retried on its own until herdr is back. The way back is the bar's Retry or
    // the link's reconnect, which clears `reattachAttempts`.
    let opens = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opens.count == 1, "a pane was reattached to a herdr that had just stopped")
  }

  /// A `detached` this scene did not ask for: herdr tearing the client down for a reason of
  /// its own. The pane is still running, so it gets the bare end's rule: one bounded reattach,
  /// never the closed banner.
  @Test("a detached nobody asked for reattaches rather than reporting a close")
  func anUnsolicitedDetachedReattaches() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    let before = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(before.count == 1, "the premise: one controller open on this pane")

    let written = await transport.emitOnStreams(
      Self.closed("detached"),
      matching: Self.isControlOf("term_w1p1")
    )
    #expect(written == 1, "the fixture has to reach a live stream, or this test asserts nothing")

    await waitUntilSignalled {
      await transport.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2
    }
    let after = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(after.count == 2, "the pane was not reattached")
    // The settle lets the notice assertion fail; see `aBareStreamEndReattachesInsteadOfClosing`.
    await scene.settle()
    #expect(scene.notice == nil, "a client being detached was reported as a pane closing")
  }

  /// Switching to Chat hands the controller back. `handBack` cancels the feed's pump and then
  /// writes `terminal.release`, and herdr answers with a `terminal.closed` record whose reason
  /// is `detached`. Reported, that receipt would re-take the token the user just gave up and
  /// reflow the pane on their desk. The fake answers every release this way, as herdr does.
  ///
  /// This pins the ordering, not the `catch` branch's `Task.isCancelled` guard. With the cancel
  /// first, the feed exits through its clean-finish branch, and a test cannot force the other
  /// order. Reverse `handBack`'s two statements and this fails.
  @Test("a hand-back herdr answers with detached opens no second controller")
  func aHandBackAnsweredWithDetachedIsNotNews() async throws {
    let (scene, transport) = await makeScene(
      surface: .terminal,
      responder: Self.everythingPaints
    )
    scene.start()
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller, "the premise: we hold it")

    scene.show(.chat)
    await scene.settle()

    let log = await transport.streamLog
    #expect(
      log.contains { $0.contains("terminal.release") },
      "the fixture has to see a release to answer one: \(log)"
    )
    #expect(scene.notice == nil, "a hand-back the user asked for is not news about the pane")
    let opens = await transport.streamedCommands.filter(Self.isControlOf("term_w1p1"))
    #expect(opens.count == 1, "the receipt for a hand-back re-took the token it gave up")
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer, "and the pane is being read")
  }

  /// The pane's last frame stays on screen across the reattach.
  ///
  /// A new `Entry.id` is a new SwiftUI identity and an empty terminal view, with no banner to
  /// explain the blank. Routing an `.ended` entry through `pending` keeps the old one until
  /// herdr's first frame, as for an observer being promoted.
  @Test("a reattach keeps the pane's last frame until the new stream paints")
  func aReattachKeepsTheLastFrameUntilTheNewOnePaints() async throws {
    // Controllers are answered with nothing, so the test can stand still in the reattach.
    let (scene, transport) = await makeScene(surface: .terminal, responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    let original = try #require(scene.entries.first { $0.target == .pane(id: "w1:p1") }?.id)

    await transport.endStreams { $0.contains("term_w1p1") }
    await waitUntilSignalled {
      await transport.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2
    }
    await scene.settle()

    let held = try #require(scene.entries.first { $0.target == .pane(id: "w1:p1") })
    #expect(held.id == original, "the reattach replaced the emulator before anything painted")
    #expect(held.role == .ended)
    #expect(scene.currentSession != nil, "the pane went blank while it was being reattached")
    // The screen stays quiet for that window. The session behind this entry is `.closed`, so
    // `statusBanner` would otherwise print "The session ended." over the last frame.
    #expect(scene.isReattaching, "the pane says its session ended while it is being reattached")

    // And the swap happens on the frame, not before it.
    await transport.emitOnStreams(Self.frame("back\r\n"))
    await waitUntil { scene.role(for: .pane(id: "w1:p1")) == .controller }
    let painted = try #require(scene.entries.first { $0.target == .pane(id: "w1:p1") })
    #expect(painted.id != original, "the new stream never took the screen")
    #expect(!scene.isReattaching, "the quiet outlived the reattach it was covering")
  }

  /// Matches the `terminal session control` command for one terminal id, so a reattach can be
  /// counted.
  private nonisolated static func isControlOf(
    _ terminalID: String
  ) -> @Sendable (String) -> Bool {
    { $0.contains("terminal session control") && $0.contains(terminalID) }
  }

  /// The same for the read-only stream the chat surface holds.
  private nonisolated static func isObserveOf(
    _ terminalID: String
  ) -> @Sendable (String) -> Bool {
    { $0.contains("terminal session observe") && $0.contains(terminalID) }
  }

  // MARK: - Leaving

  @Test("closing the scene releases the controller and every observer")
  func closingReleasesEverything() async throws {
    let (scene, transport) = await makeScene(responder: Self.observersOnly)
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    // Driven, so there are two controllers to hand back: selecting an agent pane opens its
    // chat, which takes only an observer.
    scene.show(.terminal)
    await scene.settle()

    scene.close()
    await scene.settle()

    #expect(scene.entries.isEmpty)
    let log = await transport.streamLog
    // One release per controller ever held: the first pane's, handed back when it was
    // demoted, and the second's, handed back now.
    #expect(log.filter { $0.contains("terminal.release") }.count == 2)
    // The observer warming the first pane writes nothing on its way out, so the close is its
    // only trace.
    #expect(
      log.contains { $0.hasPrefix("close:") && $0.contains("observe") },
      "a warm observer left streaming outlives the screen that opened it"
    )
  }

  @Test("a scene dropped the instant it is closed still hands everything back")
  func closingHandsBackEvenWhenTheSceneGoesFirst() async throws {
    let (model, transport, watch) = await closeAndDropScene(responder: Self.observersOnly)

    // The premise: every other test holds its scene, so `[weak self]` is never nil there.
    #expect(watch.isGone, "the scene has to be deallocated for this test to be evidence")

    await waitUntilSignalled {
      await transport.streamLog.filter { $0.contains("terminal.release") }.count == 2
    }
    let log = await transport.streamLog
    #expect(
      log.filter { $0.contains("terminal.release") }.count == 2,
      "the controller has to go back even though nothing is holding the scene that took it"
    )
    #expect(
      log.contains { $0.hasPrefix("close:") && $0.contains("observe") },
      "a warm observer's channel outlives the scene that opened it"
    )
    #expect(
      log.contains { $0.hasPrefix("close:") && $0.contains("control") },
      "a controller's channel outlives the scene that opened it"
    )
    // Held to the end, as `ConnectionRegistry` holds the connection past the scene.
    withExtendedLifetime(model) {}
  }

  @Test("Done during a switch leaves nothing of that switch attached")
  func closingDuringASwitchLeavesNothingAttached() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    // A chip and a close with nothing in between. `close` queues behind the switch, so the
    // switch's controller opens into a scene already left, and the list `close` banked cannot
    // contain it.
    scene.select(.pane(id: "w1:p2"))
    scene.close()
    await scene.settle()

    let log = await transport.streamLog
    let opened = log.filter {
      $0.hasPrefix("open:") && $0.contains("terminal session control")
    }
    let closed = log.filter {
      $0.hasPrefix("close:") && $0.contains("terminal session control")
    }
    #expect(
      opened.count == closed.count,
      "every controller opened has to be handed back: opened \(opened), closed \(closed)"
    )
    #expect(scene.entries.isEmpty)
  }

  /// Builds a scene, drives it up, closes it, and lets go of it.
  ///
  /// `scene` is a local, so its last strong reference is dropped before the call returns, as
  /// in the real dismissal: `TerminalPresenter.dismiss()` drops the `Request` that owns the
  /// scene in the same turn as the `onDisappear` that called `close()`.
  private func closeAndDropScene(
    initialTarget: TerminalTarget = .pane(id: "w1:p1"),
    responder: @escaping @Sendable (String) -> Data?
  ) async -> (ConnectionModel, FakeSSHTransport, SceneWatch) {
    let (model, transport) = await makeConnection(responder: responder)
    let watch: SceneWatch
    do {
      let scene = TerminalSceneModel(
        host: host,
        model: model,
        initialTarget: initialTarget,
        notifications: NotificationCenter()
      )
      // Driven, because an agent pane opens on its chat with no controller, and this is
      // about a controller outliving the scene.
      scene.show(.terminal)
      scene.start()
      await scene.settle()
      // A second pane, so there is an observer to hand back as well as a controller.
      scene.select(.pane(id: "w1:p2"))
      scene.show(.terminal)
      await scene.settle()
      watch = SceneWatch(scene)
      scene.close()
    }
    return (model, transport, watch)
  }

  @Test("a shell scene opens a pty and keeps it across a switch")
  func theShellIsNotAPaneAndIsNotHandedBack() async throws {
    let (scene, _) = await makeScene(
      initialTarget: .shell,
      ptyGreeting: "carson@workbox:~$ ",
      responder: Self.observersOnly
    )
    scene.start()
    await scene.settle()
    let shell = try #require(scene.currentSession)
    #expect(scene.role(for: .shell) == .local)

    scene.select(.pane(id: "w1:p1"))
    await scene.settle()

    // The shell is a pty with the user's scrollback and possibly a running command. Nothing
    // is handed back, and coming back finds the same session.
    #expect(scene.session(for: .shell) === shell)
    scene.select(.shell)
    await scene.settle()
    #expect(scene.currentSession === shell)
  }

  // MARK: - New pane

  @Test("New pane splits the pane being looked at, and the scene goes to what it made")
  func newPaneAdoptsTheSplit() async throws {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    #expect(scene.current == .pane(id: "w1:p1"))

    scene.newPane()
    await scene.settle()

    let herdr = try #require(scene.model.herdr as? FakeControl)
    let performed = await herdr.performed
    #expect(performed.map(\.action) == [.split(.right)])
    #expect(performed.first?.paneID == "w1:p1", "the split is on the pane being looked at")

    // Adopted by being a stranger, not by name: `pane split` does not report the id it made.
    #expect(scene.current == .pane(id: "w1:p7"))
    let opened = await transport.streamedCommands.filter { $0.contains("term_w1p7") }
    #expect(opened.count == 1, "the scene attached to the pane the split made")
  }

  @Test("a pane that appears on its own does not move the scene")
  func adoptionOnlyFollowsASplit() async throws {
    // A pane opened at the user's desk is a stranger too, so a scene must not jump to one
    // without a split it asked for.
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    let herdr = try #require(scene.model.herdr as? FakeControl)
    await herdr.update(to: FakeControl.crowdedTree)
    await scene.model.session?.refresh()
    scene.adoptNewPane()
    await scene.settle()

    #expect(scene.current == .pane(id: "w1:p1"))
  }

  @Test("a split whose pane never turns up is given up on rather than waited for forever")
  func adoptionGivesUp() async throws {
    // A split that produces nothing is not expected, but a scene watching for a stranger
    // forever would later jump to whatever pane the user opened at their desk. The watch is
    // bounded.
    let silent = SilentSplitControl()
    let (scene, _) = await makeScene(herdr: silent, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.newPane()
    await scene.settle()
    #expect(await silent.splits == ["w1:p1"], "the split was asked for")
    #expect(scene.current == .pane(id: "w1:p1"), "and produced nothing to go to")

    // Every subsequent snapshot is another chance, and there are not many of them.
    for _ in 0..<5 { scene.adoptNewPane() }
    await scene.settle()

    await silent.add(pane: "w9:p9")
    await scene.model.session?.refresh()
    scene.adoptNewPane()
    await scene.settle()

    #expect(scene.current == .pane(id: "w1:p1"), "the scene stopped watching long before")
  }

  @Test("a split the host refuses says so on the pane, and the scene stays and stops watching")
  func refusedSplitReachesThePrompt() async throws {
    let refused = AppError.herdrCommandFailed(reason: "the directory is gone")
    let control = SilentSplitControl(refusal: refused)
    let (scene, _) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.newPane()
    await scene.settle()

    #expect(scene.actions?.prompt == .failed(refused))
    #expect(scene.actions?.failure == refused)
    #expect(scene.current == .pane(id: "w1:p1"))

    await control.add(pane: "w9:p9")
    await scene.model.session?.refresh()
    scene.adoptNewPane()
    await scene.settle()
    #expect(scene.current == .pane(id: "w1:p1"), "no split, so no pane to adopt")
  }

  @Test("the plain shell has nothing to split, so New pane does nothing from it")
  func newPaneNeedsAPane() async throws {
    let (scene, _) = await makeScene(
      initialTarget: .shell,
      ptyGreeting: "carson@workbox:~$ ",
      responder: Self.observersOnly
    )
    scene.start()
    await scene.settle()

    scene.newPane()
    await scene.settle()

    let herdr = try #require(scene.model.herdr as? FakeControl)
    #expect(await herdr.performed.isEmpty)
    #expect(scene.current == .shell)
    #expect(!scene.canStartNewPane)
  }

  @Test("a pane can start a new pane")
  func newPaneFromAPane() async {
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    #expect(scene.canStartNewPane)
  }

  // MARK: - What a thumbnail reads

  @Test("a warm pane's rows are readable from the scene, and a cold one's are not")
  func warmEntriesReportTheirRows() async throws {
    // A warm pane keeps a terminal view laid out, so its picture already exists on this
    // device. A pane the scene is not holding answers `nil`, not an empty screen.
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    // Stands in for the call `DriverrTerminalView.makeUIView` makes. The subject is which
    // target the scene asks, not what the emulator reports.
    let session = try #require(scene.session(for: .pane(id: "w1:p1")))
    session.attach({ _ in }, visibleText: { "$ swift test\n42 tests passed" })

    #expect(
      scene.visibleLines(for: .pane(id: "w1:p1"), last: 6) == ["$ swift test", "42 tests passed"]
    )
    #expect(
      scene.visibleLines(for: .pane(id: "w3:p1"), last: 6) == nil,
      "a pane the scene is not holding has nobody here to ask"
    )
  }

  // MARK: - The sheets the screen presents

  // The pane sheet's and Settings' flags live on this model, not the screen's `@State`, so
  // the sheets can be attached outside the split view's detail column, which must not present.

  @Test("opening the pane sheet raises its flag and starts the thumbnails reading")
  func openingThePaneSheetStartsTheReads() async throws {
    let control = FakeControl()
    let (scene, _) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    #expect(!scene.isShowingPaneSheet)
    #expect(scene.paneThumbnails == nil, "a model that polls `pane read` waits to be asked")

    scene.showPaneSheet()

    #expect(scene.isShowingPaneSheet)
    let thumbnails = try #require(scene.paneThumbnails)
    await control.waitForReads(1)
    #expect(thumbnails.hasRead)
  }

  @Test("closing the pane sheet stops the reads and asks the terminal for the keyboard back")
  func closingThePaneSheetStopsTheReads() async throws {
    // Without the keyboard bump, the terminal underneath looks focused and swallows every
    // keystroke.
    let control = FakeControl()
    let (scene, _) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.showPaneSheet()
    let thumbnails = try #require(scene.paneThumbnails)
    await control.waitForReads(1)
    #expect(thumbnails.hasRead)
    let focusBefore = scene.focusRequest

    scene.hidePaneSheet()

    #expect(!scene.isShowingPaneSheet)
    // `PaneThumbnailModel.close()` clears `hasRead`, so `false` after a read landed is the
    // close itself. The poll's three-second interval is too slow to prove absence with.
    #expect(!thumbnails.hasRead, "the reads must stop with the sheet")
    #expect(scene.focusRequest == focusBefore + 1)
  }

  @Test("a second close of the pane sheet bumps nothing")
  func closingThePaneSheetTwiceBumpsOnce() async throws {
    // A SwiftUI sheet reports its dismissal through the same binding Done writes to, so both
    // arrive for one dismissal. The guard in `hidePaneSheet()` absorbs the second.
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.showPaneSheet()
    let focusBefore = scene.focusRequest
    scene.hidePaneSheet()
    scene.hidePaneSheet()

    #expect(scene.focusRequest == focusBefore + 1)
  }

  /// Ending the presentation takes both sheets and the poll down with it.
  ///
  /// `TerminalPresenter.dismiss()` calls `close()` while the scene is still alive, and a scene
  /// can outlive one route's view, so a re-presented scene would otherwise come back with a
  /// sheet raised over a `pane read` still running against the host.
  ///
  /// `focusRequest` stays unchanged. `close()` writes the flags directly rather than calling
  /// `hidePaneSheet()` and `hideSettings()`, which bump it: every terminal is released, so
  /// there is nothing to hand the keyboard to. Routing it through those methods breaks this.
  @Test("closing the scene lowers both sheets and stops the reads, without a focus bump")
  func closingTheSceneLowersTheSheets() async throws {
    let control = FakeControl()
    let (scene, _) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.showPaneSheet()
    scene.showSettings()
    let thumbnails = try #require(scene.paneThumbnails)
    await control.waitForReads(1)
    #expect(thumbnails.hasRead)
    #expect(scene.isShowingPaneSheet)
    #expect(scene.isShowingSettings)
    let focusBefore = scene.focusRequest

    scene.close()

    #expect(!scene.isShowingPaneSheet, "a re-presented scene must not come back with a sheet up")
    #expect(!scene.isShowingSettings)
    // See `closingThePaneSheetStopsTheReads`.
    #expect(!thumbnails.hasRead, "the reads must stop with the scene")
    #expect(
      scene.focusRequest == focusBefore,
      """
      close() must not bump the focus request. It writes the flags directly rather than \
      through hidePaneSheet()/hideSettings() precisely because it has just released every \
      terminal there is to hand the keyboard to.
      """
    )
  }

  @Test("reopening the pane sheet reuses the thumbnails it already built")
  func reopeningThePaneSheetKeepsItsModel() async throws {
    // A model discarded mid-dismissal pulls the tiles out from under the animation, and a
    // fresh one would reset every picture to a placeholder.
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    scene.showPaneSheet()
    let first = try #require(scene.paneThumbnails)
    scene.hidePaneSheet()
    scene.showPaneSheet()

    #expect(scene.paneThumbnails === first)
    scene.hidePaneSheet()
  }

  @Test("closing Settings asks the terminal for the keyboard back, and opening it does not")
  func closingSettingsReturnsTheKeyboard() async throws {
    let (scene, _) = await makeScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    let focusBefore = scene.focusRequest
    scene.showSettings()

    #expect(scene.isShowingSettings)
    #expect(scene.focusRequest == focusBefore, "the terminal keeps the keyboard on the way in")

    scene.hideSettings()

    #expect(!scene.isShowingSettings)
    #expect(scene.focusRequest == focusBefore + 1)

    scene.hideSettings()
    #expect(scene.focusRequest == focusBefore + 1, "one dismissal, one bump")
  }

  // MARK: - Memory warning

  @Test("a memory warning releases every observer and leaves the warm set at size 1")
  func memoryWarningReleasesEveryObserver() async throws {
    let warnings = NotificationCenter()
    let (scene, transport) = await makeScene(
      notifications: warnings,
      responder: Self.observersOnly
    )
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()
    scene.select(.pane(id: "w1:p3"))
    await scene.settle()
    // current: w1:p3, observers: [w1:p1, w1:p2]
    #expect(scene.warm.observers.count == 2)
    let current = try #require(scene.currentSession)

    warnings.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

    await waitUntil { scene.warm.observers.isEmpty }
    #expect(scene.warm.observers.isEmpty, "only the current target may still be warm")
    #expect(scene.current == .pane(id: "w1:p3"), "the current target is never touched")
    #expect(scene.currentSession === current, "the current session must not be reopened")

    await scene.settle()
    #expect(scene.entries.count == 1, "every observer must be gone, not just demoted")
    #expect(scene.entries.first?.target == scene.current)

    let log = await transport.streamLog
    #expect(
      log.filter { $0.hasPrefix("close:") && $0.contains("observe") }.count == 2,
      "both warm observers must be released, not just dropped from the warm set"
    )
  }

  @Test("a non-current shell survives a memory warning")
  func shellSurvivesAMemoryWarning() async throws {
    let warnings = NotificationCenter()
    let (scene, _) = await makeScene(
      initialTarget: .shell,
      ptyGreeting: "carson@workbox:~$ ",
      notifications: warnings,
      responder: Self.observersOnly
    )
    scene.start()
    await scene.settle()
    let shell = try #require(scene.currentSession)

    scene.select(.pane(id: "w1:p1"))
    await scene.settle()
    #expect(scene.warm.observers.contains(.shell))

    warnings.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    await waitUntil { scene.warm.observers.contains(.shell) == false }
    await scene.settle()

    // Closing that pty would kill whatever runs in it, so eviction must leave it alone.
    #expect(scene.session(for: .shell) === shell, "the shell must never be closed by eviction")
    #expect(scene.role(for: .shell) == .local)
  }

  @Test("switching back to an evicted target after a memory warning reopens it")
  func evictedTargetReopensAfterAMemoryWarning() async throws {
    let warnings = NotificationCenter()
    let (scene, transport) = await makeScene(
      notifications: warnings,
      responder: Self.observersOnly
    )
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)

    warnings.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    await waitUntil { scene.warm.observers.isEmpty }
    await scene.settle()
    #expect(
      scene.session(for: .pane(id: "w1:p1")) == nil,
      "the evicted pane's observer must be gone before it can be treated as cold again"
    )

    scene.select(.pane(id: "w1:p1"))
    #expect(scene.isOpening, "an evicted pane reopens cold, exactly like one never warmed")
    await scene.settle()

    #expect(scene.currentSession != nil)
    let controls = await transport.streamedCommands.filter {
      $0.contains("terminal session control") && $0.contains("term_w1p1")
    }
    #expect(controls.count == 2, "one controller for the first open, one for the reopen")
  }

  // MARK: - Remembering which surface a pane was left on

  /// The scene dies when it is left, and the surface choice must not die with it.
  ///
  /// Two scenes over one connection, as leaving and reopening are. The second is built with no
  /// surface asked for, so what it opens on is the app's answer.
  @Test("a pane switched to the terminal reopens on the terminal in a new scene")
  func aPaneReopensOnTheSurfaceItWasLeftOn() async throws {
    let (model, _) = await makeConnection(responder: Self.everythingPaints)
    let first = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      notifications: NotificationCenter()
    )
    first.start()
    await first.settle()
    #expect(first.surface == .chat, "an agent pane opens on its chat until it is switched")

    first.show(.terminal)
    await first.settle()

    // The first scene is gone: nothing of it is consulted below.
    let second = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      notifications: NotificationCenter()
    )

    #expect(
      second.surface == .terminal,
      "reopening the pane put it back on the surface nobody chose"
    )
  }

  /// A pane nobody switched follows the first-open rule: agent to chat, shell to terminal.
  /// Asserted beside a pane that was switched, because "per pane, not global" is only a claim
  /// if the two answers can differ.
  @Test("a pane nobody switched still opens on chat, beside one that was switched")
  func anUnswitchedPaneKeepsTheFirstOpenRule() async throws {
    let (model, _) = await makeConnection(responder: Self.everythingPaints)
    let first = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p1"),
      notifications: NotificationCenter()
    )
    first.start()
    await first.settle()
    first.show(.terminal)
    await first.settle()

    let second = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: .pane(id: "w1:p2"),
      notifications: NotificationCenter()
    )
    second.start()
    await second.settle()

    #expect(second.surface == .chat, "one pane's choice was applied to another pane")
    #expect(
      second.surface(for: .pane(id: "w1:p1")) == .terminal,
      "the switched pane lost its choice"
    )
    // A shell has one surface however much is remembered about anything else.
    #expect(second.surface(for: .shell) == .terminal)
    #expect(second.surface(for: .pane(id: "w1:p3")) == .terminal)
  }

  // MARK: - Losing the link, and getting it back

  /// A connected host and a scene on it, over a supply of transports, so a reconnect is a new
  /// connection rather than the dropped one handed back.
  private func makeReconnectingScene(
    initialTarget: TerminalTarget = .pane(id: "w1:p1"),
    surface: PaneSurface? = .terminal,
    persistence: PasswordPersistence = .remember,
    herdr: (any HerdrControl)? = nil,
    responder: @escaping @Sendable (String) -> Data? = TerminalSceneModelTests.everythingPaints,
    tokens: HerdrAttachTokens? = nil,
    wait: @escaping ReconnectWaiter = { _ in },
    // Both default to what the app runs. The tests of the reconnect's own deadlines inject
    // milliseconds, because the recovery is under test, not the numbers.
    stepDeadline: Duration = TerminalSceneModel.defaultStepDeadline,
    setUpDeadline: Duration = PaneComposerCopy.sendDeadline
  ) async -> (TerminalSceneModel, ConnectionModel, TransportSupply) {
    let supply = TransportSupply(responder: responder, tokens: tokens)
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { supply.make() }
    // The same control across a reconnect, unlike the app, which builds one per transport, so
    // a test can watch state that has to survive one.
    let control = herdr ?? FakeControl()
    environment.makeHerdrControl = { _ in control }

    let model = ConnectionModel(
      host: host,
      environment: environment,
      setUpDeadline: setUpDeadline
    )
    await model.connect(password: "hunter2", persistence: persistence)
    await model.session?.refresh()
    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: initialTarget,
      wait: wait,
      stepDeadline: stepDeadline,
      // Its own centre; see the suite doc.
      notifications: NotificationCenter()
    )
    if let surface { scene.show(surface) }
    return (scene, model, supply)
  }

  /// Drops the link in a chosen order and returns once the scene has recorded the loss: every
  /// session put down, `linkGeneration` bumped, and a reconnect started.
  ///
  /// **The order is a parameter because a socket teardown has none.** One drop reaches the scene
  /// as two signals, the disconnection and every stream ending, each through its own task hop,
  /// so emitting them in order does not make the scene act on them in order. Each signal is held
  /// until the scene has visibly acted on the previous one, which makes both orders
  /// reproducible. `.ended` marks a handled stream end, because only `sessionEnded` sets it.
  ///
  /// Returning after the loss is recorded is what makes callers' `await scene.settle()` mean
  /// something: `settle()` waits on `reconnectWork`, which `connectionLost()` assigns.
  ///
  /// The condition is every held entry gone, which only `connectionLost()` does, all at once
  /// and synchronously. `scene.notice != nil` is not the loss: a pane notice from a stream end
  /// satisfies it first. Callers settle before dropping, because a promotion in flight would
  /// swap an entry with no loss involved.
  ///
  /// Entries are compared by `Entry.id`, never by the session's `ObjectIdentifier`. The
  /// reconnect's new session can reuse a just-freed address, and the old session then reads as
  /// still there. `nextEntryID` only counts up.
  private func dropLink(
    _ scene: TerminalSceneModel,
    _ supply: TransportSupply,
    order: DropOrder = .lossFirst,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let live = Set(scene.entries.map(\.id))
    #expect(
      !live.isEmpty,
      "a scene holding no session cannot tell a recorded loss from a no-op",
      sourceLocation: sourceLocation
    )
    let lossRecorded: @MainActor () -> Bool = {
      scene.entries.allSatisfy { !live.contains($0.id) }
    }
    guard let transport = supply.latest else {
      Issue.record("no transport to drop", sourceLocation: sourceLocation)
      return
    }

    switch order {
    case .lossFirst:
      await transport.signalLoss()
      await waitUntil(
        "the loss was signalled and the scene never put its sessions down",
        sourceLocation: sourceLocation
      ) { lossRecorded() }
      // Only now, so the ends this causes cannot be the thing the scene acts on first.
      await transport.tearDownEveryChannel()
    case .streamEndFirst:
      // The losing order: the streams end, the scene is watched until it has acted on one, and
      // only then is the loss let go.
      await transport.tearDownEveryChannel()
      let endedOne: @MainActor () -> Bool = { scene.entries.contains { $0.role == .ended } }
      await waitUntil(
        "the streams ended and no entry ever reached the `.ended` role",
        sourceLocation: sourceLocation
      ) { endedOne() }
      #expect(
        endedOne(),
        "the streams ended and `sessionEnded` never ran, so this is not the order it claims",
        sourceLocation: sourceLocation
      )
      await transport.signalLoss()
      await waitUntil(
        "the loss was let go after the stream ends and the scene never recorded it",
        sourceLocation: sourceLocation
      ) { lossRecorded() }
    }

    #expect(
      lossRecorded(),
      "the link dropped and the scene never recorded it",
      sourceLocation: sourceLocation
    )
  }

  @Test("a link that drops says so inline, while it is getting it back")
  func aDropSaysSo() async throws {
    // The waiter parks, or the whole backoff burns through in microseconds and
    // "Reconnecting…" never lasts long enough to read. `close()` at the end stops the park.
    let (scene, _, supply) = await makeReconnectingScene(
      wait: { _ in try? await Task.sleep(for: .seconds(60)) }
    )
    scene.start()
    await scene.settle()
    supply.isAccepting = false

    await supply.latest?.drop()
    await waitUntil { scene.notice == .reconnecting }

    #expect(scene.notice == .reconnecting, "nothing on screen said the link had gone")
    scene.close()
  }

  @Test("a link that drops while a pane is on screen gets that pane back")
  func aDropReconnectsAndReopensTheCurrentTarget() async throws {
    let (scene, model, supply) = await makeReconnectingScene()
    scene.start()
    await scene.settle()

    await dropLink(scene, supply)
    await scene.settle()

    #expect(scene.notice == nil, "the banner outlived the reconnect")
    #expect(model.phase == .connected)
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)
    let opens = await supply.latest?.streamedCommands.filter {
      $0.contains("terminal session control") && $0.contains("term_w1p1")
    }
    #expect(opens?.count == 1, "the pane was re-opened \(opens?.count ?? 0) times, not once")
  }

  @Test("the panes that were merely warm are gone, and come back only when chosen")
  func aDropDropsTheWarmObservers() async throws {
    let (scene, _, supply) = await makeReconnectingScene()
    scene.start()
    await scene.settle()
    scene.select(.pane(id: "w1:p2"))
    // Driven, so what comes back after the drop is a controller, distinct from the warm ones.
    scene.show(.terminal)
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .observer)

    await dropLink(scene, supply)
    await scene.settle()

    #expect(scene.entries.count == 1, "a reconnect re-warmed panes nobody is looking at")
    #expect(scene.session(for: .pane(id: "w1:p1")) == nil)
    #expect(scene.role(for: .pane(id: "w1:p2")) == .controller)

    // Lazily: choosing it opens it, as for any cold pane.
    scene.select(.pane(id: "w1:p1"))
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)
  }

  @Test("the pane comes back where the phone had it")
  func aReconnectRestoresTheScroll() async throws {
    let (scene, _, supply) = await makeReconnectingScene()
    scene.start()
    await scene.settle()
    // Only an answered scroll counts, so the frame has to come back before the link goes.
    let session = try #require(scene.currentSession)
    session.scroll(.up, lines: 5)
    await waitUntilSignalled {
      await supply.latest?.streamLog.contains { $0.contains("terminal.scroll") } == true
    }
    await supply.latest?.emitOnStreams(Self.frame("scrolled\r\n"))
    await waitUntil { session.scrolledRows == 5 }

    await dropLink(scene, supply)
    await scene.settle()
    // `restoreScroll` writes on the session's task rather than through the work chain, so
    // `settle()` can return with the scroll still in flight.
    await waitUntilSignalled {
      await supply.latest?.streamLog.contains { $0.contains("terminal.scroll") } == true
    }

    // One scroll, not a replay: the position survived on the desk, so this only undoes the
    // scroll home. Read off the new transport, which is all the reconnect sent.
    let scrolls = await supply.latest?.streamLog.filter { $0.contains("terminal.scroll") }
    #expect(scrolls?.count == 1, "the phone landed at the bottom of a pane it had scrolled")
    #expect(try #require(scrolls?.first).contains("\"lines\":5"))
  }

  @Test("a bridge stream that fails while the link is up is still that pane's problem")
  func aStreamFailureIsNotALoss() async throws {
    // herdr ending one session says nothing about the link, and a reconnect would tear down
    // every other pane over it.
    let (scene, model, supply) = await makeReconnectingScene(responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    await supply.latest?.finishStreams()

    // `finishStreams` ends a stream with no `terminal.closed` record, which is a channel
    // ending rather than a pane closing, so the scene reattaches.
    await waitUntilSignalled("the pane's stream was never reattached") {
      await supply.latest?.streamedCommands.filter(Self.isControlOf("term_w1p1")).count == 2
    }
    // See `aBareStreamEndReattachesInsteadOfClosing` for why this settles.
    await scene.settle()
    #expect(scene.notice == nil, "one stream ending was reported to the user as a close")
    #expect(model.phase == .connected, "a pane's own trouble was reported as the link going")
  }

  @Test("a host whose password nobody remembered is asked, inline, and retries nothing")
  func aPasswordHostIsAskedRatherThanRetried() async throws {
    var delays: [Duration] = []
    let (scene, model, supply) = await makeReconnectingScene(
      persistence: .promptEveryTime,
      wait: { delays.append($0) }
    )
    scene.start()
    await scene.settle()
    let connectionsBefore = supply.attempts

    await dropLink(scene, supply)
    await scene.settle()

    #expect(scene.notice == .needsPassword)
    #expect(delays.isEmpty, "a backoff started on a credential nobody has")
    #expect(
      supply.attempts == connectionsBefore,
      "the scene tried to reconnect with a password it was never given"
    )
    guard case .lost = model.phase else {
      Issue.record("expected the connection to still be lost, got \(model.phase)")
      return
    }
  }

  @Test("answering the inline prompt gets the pane back")
  func answeringThePromptReconnects() async throws {
    let (scene, model, supply) = await makeReconnectingScene(persistence: .promptEveryTime)
    scene.start()
    await scene.settle()
    await dropLink(scene, supply)
    await scene.settle()
    #expect(scene.notice == .needsPassword)

    scene.reconnect(with: "hunter2")
    await scene.settle()

    #expect(scene.notice == nil)
    #expect(model.phase == .connected)
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)
  }

  @Test("a wrong password asks again rather than starting a backoff")
  func aRefusedPromptAsksAgain() async throws {
    var delays: [Duration] = []
    let (scene, _, supply) = await makeReconnectingScene(
      persistence: .promptEveryTime,
      wait: { delays.append($0) }
    )
    scene.start()
    await scene.settle()
    await dropLink(scene, supply)
    await scene.settle()

    supply.isAccepting = false
    scene.reconnect(with: "wrong")
    await scene.settle()

    #expect(scene.notice == .needsPassword)
    #expect(delays.isEmpty, "a refused password started a loop that can only be refused")
    // The refusal is stated. Without it the bar asks the same question with the field
    // cleared, which reads as a missed tap.
    #expect(scene.passwordWasRefused)
  }

  /// The first ask has refused nothing, and must not say it has.
  ///
  /// `.needsPassword` arrives by two routes: a link that dropped with no stored credential,
  /// and a password the host turned down. The refusal line is only true of the second.
  @Test("being asked for a password in the first place is not a refusal")
  func theFirstAskIsNotARefusal() async throws {
    let (scene, _, supply) = await makeReconnectingScene(
      persistence: .promptEveryTime,
      wait: { _ in }
    )
    scene.start()
    await scene.settle()
    // The drop produces the ask; a scene that never lost its link asks for nothing.
    await dropLink(scene, supply)
    await scene.settle()

    #expect(scene.notice == .needsPassword)
    #expect(!scene.passwordWasRefused, "nobody has typed anything yet")
  }

  /// A password that works clears the accusation, so coming back to this bar after a later
  /// drop does not still show a refusal from the last one.
  @Test("a password that is accepted clears the refusal")
  func anAcceptedPasswordClearsTheRefusal() async throws {
    let (scene, _, supply) = await makeReconnectingScene(
      persistence: .promptEveryTime,
      wait: { _ in }
    )
    scene.start()
    await scene.settle()
    await dropLink(scene, supply)
    await scene.settle()

    supply.isAccepting = false
    scene.reconnect(with: "wrong")
    await scene.settle()
    #expect(scene.passwordWasRefused)

    supply.isAccepting = true
    scene.reconnect(with: "hunter2")
    await scene.settle()

    #expect(!scene.passwordWasRefused)
  }

  /// A host that lets the link come back and then stops answering the set-up.
  ///
  /// `attemptReconnect` checks `model.phase == .connected` after `model.reconnect()` returns,
  /// and an unbounded set-up await inside that call would mean the check is never reached: the
  /// banner says Reconnecting for ever and `settle()` never returns.
  ///
  /// The herdr control is what stalls, because the set-up runs over exec channels, which
  /// `stopAnswering` does not reach; see `StopsAnsweringAfterTheFirstConnect`.
  ///
  /// Never awaits `settle()`. On a regression that would hang the suite rather than fail one
  /// test.
  @Test("a reconnect whose set-up never answers gives up rather than reconnecting for ever")
  func aReconnectThatStallsInItsSetUpGivesUp() async {
    let (scene, model, supply) = await makeReconnectingScene(
      herdr: StopsAnsweringAfterTheFirstConnect(),
      // Every attempt in the schedule spends one of these.
      setUpDeadline: .milliseconds(20)
    )
    scene.start()
    await scene.settle()

    await dropLink(scene, supply)

    // `.disconnected` is the end of `ReconnectSchedule` and stays true, unlike `.reconnecting`.
    await waitUntil { scene.notice == .disconnected }
    #expect(
      scene.notice == .disconnected,
      "the banner has to offer a way back by hand rather than saying Reconnecting for ever"
    )
    #expect(
      model.phase == .failed(.herdrDidNotAnswer(host: host.hostname)),
      "an attempt given up on has to say so; the phase is \(model.phase)"
    )
  }

  /// The re-open the reconnect queues is a targeted step, so an abandoned one leaves a notice
  /// rather than a blank pane that reads as a reconnect that worked.
  ///
  /// The target is resolved when the step runs, not when it is queued: a chip tapped while the
  /// link was down queues a `select` in front, and the queue-time target is the pane just left.
  @Test("a reconnect re-open that is given up on says so on the pane it was about")
  func anAbandonedReconnectReOpenSaysSoOnItsPane() async {
    let (scene, _, supply) = await makeReconnectingScene(stepDeadline: .milliseconds(50))
    scene.start()
    await scene.settle()

    // Armed before the drop, so only the connection that comes back stalls, and only on the
    // re-opened pane's bridge stream.
    supply.stallsNewTransports = true
    await dropLink(scene, supply)

    await waitUntil {
      scene.notice == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer))
    }
    #expect(
      scene.notice == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)),
      "the pane the reconnect was re-opening says \(String(describing: scene.notice))"
    )
  }

  @Test("the backoff follows ReconnectSchedule and stops at its deadline")
  func theBackoffFollowsTheScheduleAndStops() async throws {
    var delays: [Duration] = []
    let (scene, _, supply) = await makeReconnectingScene(wait: { delays.append($0) })
    scene.start()
    await scene.settle()

    // The waiter records what it was asked to wait for and returns at once, so the assertion
    // is on the schedule itself.
    supply.isAccepting = false
    await dropLink(scene, supply)
    await scene.settle()

    #expect(delays == Array(ReconnectSchedule()))
    #expect(scene.notice == .disconnected, "the banner has to offer a way back by hand")
  }

  @Test("the Reconnect the banner offers gets the pane back")
  func theManualReconnectWorks() async throws {
    let (scene, model, supply) = await makeReconnectingScene(wait: { _ in })
    scene.start()
    await scene.settle()
    supply.isAccepting = false
    await dropLink(scene, supply)
    await scene.settle()
    #expect(scene.notice == .disconnected)

    supply.isAccepting = true
    scene.reconnectNow()
    await scene.settle()

    #expect(scene.notice == nil)
    #expect(model.phase == .connected)
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller)
  }

  @Test("a scene that has been closed does not reconnect behind the user")
  func aClosedSceneDoesNotReconnect() async throws {
    let (scene, _, supply) = await makeReconnectingScene()
    scene.start()
    await scene.settle()
    let connectionsBefore = supply.attempts

    scene.close()
    await scene.settle()
    await supply.latest?.drop()
    try? await Task.sleep(for: .milliseconds(50))
    await scene.settle()

    // Letting go of the entries ends their streams, which may leave a notice. What must not
    // happen is a reconnect.
    #expect(scene.notice != .reconnecting)
    #expect(
      supply.attempts == connectionsBefore,
      "a dismissed terminal re-opened a pane on a host nobody is looking at"
    )
  }
  @Test("a pane chosen while the link is down is the one that opens when it comes back")
  func aSelectDuringAnOutageIsHonouredOnTheWayBack() async throws {
    // The scene stays usable while reconnecting, and must not come back to the pane the user
    // left. This guards the behaviour; the narrower window where the select lands between the
    // restore's two halves is not reachable from a test.
    let (scene, _, supply) = await makeReconnectingScene(
      wait: { _ in try? await Task.sleep(for: .milliseconds(20)) }
    )
    scene.start()
    await scene.settle()
    supply.isAccepting = false
    await supply.latest?.drop()
    await waitUntil { scene.notice == .reconnecting }

    scene.select(.pane(id: "w1:p3"))
    supply.isAccepting = true
    await scene.settle()

    #expect(scene.current == .pane(id: "w1:p3"))
    #expect(scene.role(for: .pane(id: "w1:p3")) == .controller)
    let opened = await supply.latest?.streamedCommands.filter { $0.contains("term_w1p3") }
    #expect(opened?.count == 1, "the pane the user chose was opened \(opened?.count ?? 0) times")
    let left = await supply.latest?.streamedCommands.filter { $0.contains("term_w1p1") }
    #expect(left?.isEmpty == true, "the reconnect re-opened the pane the user had left")
  }

  // MARK: - Reattaching after a link the host never saw end

  @Test(
    "reattaching after a lost link reclaims our own pane instead of offering Take over",
    arguments: [DropOrder.lossFirst, .streamEndFirst]
  )
  func aReattachReclaimsOurOwnController(order: DropOrder) async throws {
    // Both orders. The stream ends take the short path (pump, `sessionEnded`) and the loss the
    // long one (coordinator, watcher, `recordLoss`, `onLoss`, `connectionLost()`, which bumps
    // `linkGeneration`). If the short path winning threw the claim away, the reattach would
    // read its own ghost as another device and put up Take over. See `dropLink`.
    try await theReattachReclaimsOurOwnController(dropping: order)
  }

  /// The body of `aReattachReclaimsOurOwnController`, over one of the two orders the loss and
  /// the stream ends can reach the scene in.
  private func theReattachReclaimsOurOwnController(dropping order: DropOrder) async throws {
    // A phone that loses its link closes nothing the host can see, so the herdr process left
    // behind keeps the attach token until sshd reaps it, about 2 h. Driverr reconnects on a new
    // link and is refused by its own ghost.
    let tokens = HerdrAttachTokens()
    let (scene, _, supply) = await makeReconnectingScene(tokens: tokens)
    scene.start()
    await scene.settle()
    // Attached and painted. The claim is made on herdr's first frame, not on the open, and
    // `settle()` returns before the frame. Dropping the link before it would leave a pane
    // never granted, and the prompt would then be correct.
    //
    // Watched through a sink, as a renderer would. `visibleLines` cannot work here: it needs
    // `DriverrTerminalView`. `attach` flushes what arrived before it, so a sink is never late.
    let opened = try #require(scene.session(for: .pane(id: "w1:p1")))
    let painted = PaintedOutput()
    opened.attach { painted.append($0) }
    //
    // The role needs no wait of its own: the pump yields the chunk and then calls
    // `controllerGranted`, so the sink cannot fill first. Here the entry was installed as
    // `.controller` directly anyway.
    await waitUntil("the controller's first frame never reached the screen") {
      painted.text.contains("live")
    }
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller, "the pane opened at all")

    tokens.loseConnection(supply.latestConnection)
    await dropLink(scene, supply, order: order)
    // The reclaim is decided on the refusal record, which arrives on the stream's own task,
    // so `settle()` can return first. Waited on by the two possible outcomes: the reclaim
    // went out and the pane is back, or the prompt went up.
    //
    // Counting opens does not work: the refused open already makes two. The `--takeover`
    // command alone does not work: with `.streamEndFirst` the role is set later, on the first
    // frame, off the work chain. The role alone does not work: with `.lossFirst` the refused
    // open is installed as `.controller` before the refusal is read.
    await waitUntil("the reclaim neither took the pane back nor put the prompt up") {
      (tokens.controlOpens.contains { $0.contains("--takeover") }
        && scene.role(for: .pane(id: "w1:p1")) == .controller)
        || scene.notice == .refused
    }
    await scene.settle()

    #expect(
      scene.notice != .refused,
      "the user is told another device has a pane their own phone never handed back"
    )
    #expect(scene.role(for: .pane(id: "w1:p1")) == .controller, "the pane came back")
    let reclaims = tokens.controlOpens.filter { $0.contains("--takeover") }
    #expect(reclaims.count == 1, "reclaimed exactly once, not retried in a loop")
  }

  @Test("a pane another device really holds still asks before taking it over")
  func aGenuineRefusalStillPrompts() async throws {
    // A refusal Driverr has no claim on is somebody else's pane. `--takeover` is for a
    // deliberate tap, and a reclaim rule that cannot tell the two apart would spend it.
    let tokens = HerdrAttachTokens()
    tokens.holdForAnotherDevice(terminalID: "term_w1p1")
    let (scene, _, _) = await makeReconnectingScene(tokens: tokens)

    scene.start()
    await waitUntil { scene.notice == .refused }

    #expect(scene.notice == .refused, "a pane another device holds is not announced")
    #expect(
      tokens.controlOpens.contains { $0.contains("--takeover") } == false,
      "evicted another device's controller without being asked"
    )
  }

  @Test("a pane handed back cleanly is not reclaimed when it is refused later")
  func aCleanHandBackForfeitsTheClaim() async throws {
    // The claim is "we never gave this back", so giving it back ends it. Whoever takes a
    // released pane next took it fairly.
    let tokens = HerdrAttachTokens()
    let (scene, _, _) = await makeReconnectingScene(tokens: tokens)
    scene.start()
    await scene.settle()

    scene.select(.pane(id: "w1:p3"))
    await scene.settle()
    #expect(scene.role(for: .pane(id: "w1:p3")) == .controller, "the switch happened")

    // Somebody else picks the released pane up, and now the phone wants it back.
    tokens.holdForAnotherDevice(terminalID: "term_w1p1")
    scene.select(.pane(id: "w1:p1"))
    await waitUntil { scene.notice == .refused }

    #expect(scene.notice == .refused, "a pane we handed back was taken as still ours")
    #expect(
      tokens.controlOpens.contains { $0.contains("--takeover") } == false,
      "a released pane was reclaimed over a device that took it fairly"
    )
  }

  @Test("a link that drops takes a pending split's claim on the next stranger with it")
  func aLossDropsAPendingSplit() async throws {
    // A split adopts the first new pane within a few snapshots, so a pane opened at the desk
    // is not mistaken for it. An outage can last minutes and the tree comes back fresh, so the
    // claim goes with the link.
    let silent = SilentSplitControl()
    let (scene, _, supply) = await makeReconnectingScene(herdr: silent)
    scene.start()
    await scene.settle()
    scene.newPane()
    await scene.settle()
    #expect(await silent.splits == ["w1:p1"], "the split was asked for")

    await dropLink(scene, supply)
    await scene.settle()
    #expect(scene.notice == nil, "the link should be back")

    await silent.add(pane: "w9:p9")
    await scene.model.session?.refresh()
    scene.adoptNewPane()
    await scene.settle()

    #expect(
      scene.current == .pane(id: "w1:p1"),
      "a pane opened at the desk during the outage was adopted as this split's"
    )
  }

  // MARK: - A prompt across a poll

  /// `treeChanged()`, which a poll fires every few seconds, must leave the prompt where it was.
  /// A UI test would have to wait out a poll; here the tick is a call.
  @Test("the rename prompt and its half-typed draft outlive a poll")
  func theRenamePromptSurvivesAPoll() async throws {
    let (scene, _) = await makeScene(herdr: FakeControl(), responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    let opened = try #require(scene.actions, "the current pane has actions")
    opened.startRenaming()
    opened.draftLabel = "half typed"

    // What a herdr poll does: the tree arrives again, unchanged, and the screen says so.
    scene.treeChanged()

    let after = try #require(scene.actions, "the pane is still in the tree, so it has actions")
    #expect(after.prompt == .rename, "the poll closed the rename prompt out from under the user")
    #expect(after.draftLabel == "half typed", "the poll threw the typed name away")
  }

  @Test("a close confirmation waiting for an answer outlives a poll")
  func aPendingConfirmationSurvivesAPoll() async throws {
    let (scene, _) = await makeScene(herdr: FakeControl(), responder: Self.everythingPaints)
    scene.start()
    await scene.settle()

    let opened = try #require(scene.actions, "the current pane has actions")
    await opened.request(.close)
    #expect(opened.pendingConfirmation == .close, "close asks first")

    scene.treeChanged()

    #expect(
      scene.actions?.pendingConfirmation == .close,
      "the poll answered the confirmation for the user by dropping it"
    )
  }

  @Test("a pane that leaves the tree mid-prompt still takes the prompt with it")
  func aPaneThatLeavesTakesItsPromptWithIt() async throws {
    let control = FakeControl()
    let (scene, _) = await makeScene(herdr: control, responder: Self.everythingPaints)
    scene.start()
    await scene.settle()
    try #require(scene.actions).startRenaming()

    // The pane is closed somewhere else while the rename bar is open.
    await control.update(to: Self.treeWithNoTerminalID)
    await scene.model.session?.refresh()
    scene.treeChanged()

    #expect(
      scene.actions == nil,
      "a bar offering Rename on a pane that no longer exists addresses herdr by a dead id"
    )
  }
}

/// Which of a dropped link's two signals the scene is made to act on first.
///
/// A real transport offers no ordering. `NIOSSHTransport` yields the loss off the parent
/// channel's `closeFuture` and a stream's end off a child channel's `channelInactive`, and a
/// parent close tears its children down on the way, so stream end first is if anything the
/// likelier order in production.
enum DropOrder: Sendable, CustomStringConvertible {
  /// `connectionLost()` runs first, so every stream end that follows is stale and the
  /// generation guard turns it away.
  case lossFirst
  /// A stream end is acted on while `linkGeneration` still matches and `model.phase` is still
  /// `.connected`.
  case streamEndFirst

  var description: String {
    switch self {
    case .lossFirst: "loss first"
    case .streamEndFirst: "stream end first"
    }
  }
}

/// herdr's attach token, modelled on the host rather than on one connection.
///
/// Two rules, measured against herdr 0.8.2:
///
/// - One controller per terminal. A second `terminal session control` is answered with
///   `terminal.closed` carrying herdr's refusal, and `--takeover` gets past it. Observers take
///   no token and are always answered.
/// - The token comes back when the controlling stream closes, not when `terminal.release` is
///   written. A controller killed with no release frees it just as promptly. So a hold runs
///   from `open:` to `close:`.
///
/// `loseConnection(_:)` is what `FakeSSHTransport.drop()` cannot express: a phone suspended by
/// iOS or off a radio dies with no FIN, and the host keeps the sshd session, the herdr process
/// and the attach token, for about 2 h on stock sshd settings (`ClientAliveInterval 0`,
/// `net.inet.tcp.keepidle` 7200000). That is the state a reattach walks into.
///
/// `@unchecked Sendable` with a lock for `TransportSupply`'s reason: the responder and the
/// close hook are `@Sendable` synchronous closures with no actor to hop to.
private final class HerdrAttachTokens: TransportConnectionHooks, @unchecked Sendable {
  /// Which stream holds a terminal. The command is part of it: a reclaim opens its
  /// `--takeover` controller and then lets go of the refused one on the same link, and that
  /// close must not hand back a token it never held.
  private struct Holder: Equatable {
    let connection: Int
    let command: String
  }

  private let lock = NSLock()
  /// terminal id → the stream whose controller holds it.
  private var holders: [String: Holder] = [:]
  /// Connections the host has stopped hearing. Their closes are ignored, so their tokens
  /// are never handed back.
  private var unheard: Set<Int> = []
  private var controlCommands: [String] = []

  /// Every `terminal session control` command the host was asked for, in order — including
  /// the ones it refused, so a test can count how many carried `--takeover`.
  var controlOpens: [String] { lock.withLock { controlCommands } }

  /// Answers streamed commands for one connection: a frame, or herdr's refusal.
  func responder(connection: Int) -> @Sendable (String) -> Data? {
    { [self] command in
      guard let terminalID = Self.terminalID(in: command) else { return nil }
      if command.contains("terminal session observe") {
        return TerminalSceneModelTests.frame("observed\r\n")
      }
      guard command.contains("terminal session control") else { return nil }
      return lock.withLock {
        controlCommands.append(command)
        // Its own wake-up: `execStream` signals before it calls this responder, so a wait on
        // `controlOpens` woken by that signal would read the list one command short.
        Waker.signalShared()
        if let holder = holders[terminalID], holder.connection != connection,
          !command.contains("--takeover")
        {
          return TerminalSceneModelTests.refusal(of: terminalID)
        }
        holders[terminalID] = Holder(connection: connection, command: command)
        return TerminalSceneModelTests.frame("live\r\n")
      }
    }
  }

  /// Hands the token back when a controller's stream closes — unless the host has stopped
  /// hearing that connection, in which case it never learns.
  func closeHook(connection: Int) -> @Sendable (String) -> Void {
    { [self] command in
      guard command.contains("terminal session control"),
        let terminalID = Self.terminalID(in: command)
      else { return }
      lock.withLock {
        guard !unheard.contains(connection) else { return }
        if holders[terminalID] == Holder(connection: connection, command: command) {
          holders[terminalID] = nil
        }
      }
    }
  }

  /// The link died without the host noticing. Everything this connection holds, it keeps.
  func loseConnection(_ id: Int) {
    lock.withLock { _ = unheard.insert(id) }
  }

  /// A terminal held by a second real device, the case the take-over prompt is for.
  /// Connection `-1` is nobody this app will ever be.
  func holdForAnotherDevice(terminalID: String) {
    lock.withLock {
      holders[terminalID] = Holder(connection: -1, command: "another device")
    }
  }

  /// herdr's terminal ids are the only `term_`-prefixed word in a bridge command, and the
  /// command is shell-quoted, so the quotes come off before matching.
  private static func terminalID(in command: String) -> String? {
    command
      .split(whereSeparator: { $0 == " " || $0 == "'" })
      .first { $0.hasPrefix("term_") }
      .map(String.init)
  }
}

/// What a renderer would have on screen, for a suite that has no renderer.
///
/// The emulator lives in the view, so a test that needs to know a frame landed installs a
/// sink as `DriverrTerminalView.makeUIView` does. Attaching late misses nothing:
/// `TerminalSession` buffers output until something attaches.
@MainActor private final class PaintedOutput {
  private(set) var text = ""

  func append(_ bytes: ArraySlice<UInt8>) {
    text += String(decoding: bytes, as: UTF8.self)
    // A plain property, out of observation's and the transport hook's reach.
    Waker.signalShared()
  }
}

/// A herdr that says yes to a split and then behaves as if nothing happened.
///
/// `FakeControl`'s split adds a pane. This one exits 0 having produced nothing, to exercise the
/// bound on watching for a stranger.
private actor SilentSplitControl: HerdrControl {
  private var tree = FakeControl.seededTree
  /// What a split throws, when it should fail rather than produce nothing.
  private let refusal: AppError?
  /// The panes a split was asked for, in order.
  private(set) var splits: [String] = []

  init(refusal: AppError? = nil) {
    self.refusal = refusal
  }

  nonisolated var binaryPath: String { "herdr" }

  func snapshot() async throws -> SessionTree { tree }

  nonisolated func attachCommand(for pane: Pane) -> String {
    "herdr terminal attach \(pane.terminalID ?? pane.id)"
  }

  func availability() async -> HerdrAvailability {
    // A version and a protocol that go together.
    .ready(version: "0.9.1", protocolVersion: HerdrProtocol.lastVerified)
  }

  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen { .blank }

  func perform(_ action: PaneAction, on paneID: String) async throws {
    if case .split = action { splits.append(paneID) }
    if let refusal { throw refusal }
  }

  func rename(_ target: RenameTarget, to label: String) async throws {}

  /// A pane that turned up long after the split — the one the scene must *not* adopt.
  func add(pane id: String) {
    let pane = Pane(
      id: id,
      tabID: "w9:t1",
      workspaceID: "w9",
      title: "opened at the desk",
      terminalID: "term_w9p9",
      directory: "~"
    )
    let tab = Tab(id: "w9:t1", workspaceID: "w9", number: 1, label: "desk", panes: [pane])
    tree = SessionTree(
      workspaces: tree.workspaces + [Workspace(id: "w9", number: 9, label: "desk", tabs: [tab])],
      focusedPaneID: tree.focusedPaneID
    )
  }
}

/// A herdr that answers the first connection and stops answering every one after it.
///
/// `TransportSupply.isAccepting` refuses the handshake, a different failure, and
/// `FakeSSHTransport.stopAnswering` reaches only streamed commands. `availability()` runs over
/// an exec channel before any stream exists, so the link comes back, `phase` is already
/// `.connected`, and `ConnectionModel.performConnect` parks on the next hop.
///
/// A sleep rather than a continuation nobody resumes, because a dropped `CheckedContinuation`
/// logs a runtime misuse warning. The default outlives every deadline in the test.
private actor StopsAnsweringAfterTheFirstConnect: HerdrControl {
  private let inner = FakeControl()
  private let stall: Duration
  private var connects = 0

  init(stall: Duration = .seconds(30)) {
    self.stall = stall
  }

  nonisolated var binaryPath: String { "herdr" }

  func availability() async -> HerdrAvailability {
    connects += 1
    if connects > 1 { try? await Task.sleep(for: stall) }
    return await inner.availability()
  }

  func snapshot() async throws -> SessionTree {
    try await inner.snapshot()
  }

  /// Reimplemented rather than forwarded: the protocol wants this synchronously and `inner` is
  /// an actor.
  nonisolated func attachCommand(for pane: Pane) -> String {
    "herdr terminal attach \(pane.terminalID ?? pane.id)"
  }

  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen { .blank }
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}
}

/// Weakly holds a scene so a test can say whether it has actually been deallocated.
///
/// A test of the hand-back on deallocation has to assert the scene is gone, or it passes on a
/// scene something still holds.
@MainActor
final class SceneWatch {
  private weak var scene: TerminalSceneModel?

  init(_ scene: TerminalSceneModel) { self.scene = scene }

  var isGone: Bool { scene == nil }
}

/// A one-way flag set from a task and read from the test.
///
/// For waiting on whether an await returns at all, where awaiting it directly is the hang
/// under test. Internal, because `ConnectionModelTests` uses it too.
///
/// `@MainActor` rather than a lock: everything that touches it already runs there.
@MainActor
final class Flag {
  private var raised = false
  private struct Waiter {
    let id: Int
    let continuation: CheckedContinuation<Void, Never>
  }
  private var waiters: [Waiter] = []
  private var nextWaiterID = 0

  func raise() {
    raised = true
    let resuming = waiters
    waiters.removeAll()
    for waiter in resuming { waiter.continuation.resume() }
  }

  var isRaised: Bool { raised }

  /// Suspends until `raise()` is called, or returns at once if it already has been. No clock:
  /// a slow machine takes longer and still passes.
  func wait() async {
    guard !raised else { return }
    let id = nextWaiterID
    nextWaiterID += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if raised {
          continuation.resume()
        } else if Task.isCancelled {
          continuation.resume()
        } else {
          waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume()
  }
}

import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// Switching `Chat | Terminal` back and forth on a pane whose agent Driverr has no reader for.
///
/// A round trip through the segment, rather than one step of the chain. It sees only the scene
/// chain parking, not the surface's layout never settling; `PaneChatUITests` covers layout.
///
/// `.serialized` for `TerminalSceneModelTests`' reason: a `TerminalSceneModel` observes
/// `UIApplication.didReceiveMemoryWarningNotification`, so scenes built in parallel evict
/// each other's warm sets. Every scene here listens on a centre of its own as well.
///
/// In the full bundle the test is slow from main-actor queueing behind the hosted layout
/// suites, not from a wait here; see `HostedProbeMainActorTests`. The worst single settle in
/// the bundle was about 3 s, well inside the 12 s `stepDeadline`.
@MainActor
@Suite("Pane surface switch", .serialized, .timeLimit(.minutes(2)))
struct PaneSurfaceSwitchTests {
  private let host = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")

  /// `FakeControl.seededTree`'s unreadable-agent pane: `kind: "gemini"`, so
  /// `TranscriptReader.agent(of:)` finds no reader before any I/O and the Chat side draws
  /// `PaneScreenView` rather than a conversation. It carries a real `terminalID`, so the
  /// Terminal side attaches through a bridge rather than a pty, which makes the switch a
  /// demote rather than a drop.
  private let unreadablePane = TerminalTarget.pane(id: "w2:p1")

  /// One `terminal.frame`, as herdr's bridge sends it: always `full`, always `seq: 1`.
  /// `nonisolated` because the responder is a `@Sendable` closure the fake transport calls off
  /// the main actor.
  private nonisolated static func frame(_ text: String) -> Data {
    let encoded = Data(text.utf8).base64EncodedString()
    let record = """
      {"type":"terminal.frame","seq":1,"full":true,"encoding":"ansi",\
      "width":80,"height":24,"bytes":"\(encoded)"}
      """
    return Data((record + "\n").utf8)
  }

  /// Answers every terminal stream with a frame, so a controller paints as soon as it opens and
  /// leaves `pending`. A silent responder would park one there for reasons of its own.
  private static let everythingPaints: @Sendable (String) -> Data? = { command in
    command.contains("terminal session") ? frame("live\r\n") : nil
  }

  private func makeScene(
    responder: @escaping @Sendable (String) -> Data?
  ) async -> (TerminalSceneModel, FakeSSHTransport) {
    let transport = FakeSSHTransport(ptyGreeting: nil, streamResponder: responder)
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
    )
    environment.makeTransport = { transport }
    let control = FakeControl()
    environment.makeHerdrControl = { _ in control }

    let model = ConnectionModel(host: host, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.session?.refresh()

    let scene = TerminalSceneModel(
      host: host,
      model: model,
      initialTarget: unreadablePane,
      notifications: NotificationCenter()
    )
    return (scene, transport)
  }

  /// Awaits the chain, and asserts it drained on its own rather than being rescued.
  ///
  /// Awaited through a `Flag`, so a chain that never comes back fails on the suite's
  /// `.timeLimit`. Nothing here consults a clock. A step abandoned at the deadline sets
  /// `notices[target]` to `herdrCommandFailed(reason: noAnswer)`, so the rescue is read from
  /// scene state rather than inferred from a duration.
  ///
  /// **Keep the real twelve-second `stepDeadline`.** An abandoned step's notice is cleared when
  /// the step finishes. With a short deadline, a step slowed by load would be abandoned and its
  /// notice read here before the clear, a false failure. At twelve seconds only a parked step
  /// is abandoned, and it never finishes, so its notice stays.
  private func settle(
    _ scene: TerminalSceneModel,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let settled = Flag()
    Task { [scene] in
      await scene.settle()
      settled.raise()
    }
    await settled.wait()
    #expect(
      scene.notice != .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)),
      Comment(
        rawValue: "\(what): the chain only drained because the twelve-second bound abandoned "
          + "a step. The switch is soft-locked and the bound is hiding it."
      ),
      sourceLocation: sourceLocation
    )
  }

  /// Every stream opened on the unreadable-agent pane's terminal, and every one closed again.
  ///
  /// The indirect read of the private `pending`: a controller parked there is a stream open on
  /// the host with nothing pointing at it. One live stream, the chat side's observer, passes.
  private func liveStreams(in log: [String], on terminalID: String) -> Int {
    let opened = log.filter { $0.hasPrefix("open: ") && $0.contains(terminalID) }.count
    let closed = log.filter { $0.hasPrefix("close: ") && $0.contains(terminalID) }.count
    return opened - closed
  }

  // MARK: - Round trips

  /// Four switches, each draining without a rescue, then one entry for the pane, one live
  /// stream on the host, and no notice.
  @Test("switching surfaces twice on an unreadable agent's pane drains the chain each time")
  func switchingSurfacesTwiceOnAnUnreadableAgentDrainsTheChain() async {
    let (scene, transport) = await makeScene(responder: Self.everythingPaints)
    // No `show(_:)` before `start()`: an agent pane defaults to `.chat`.
    scene.start()
    await settle(scene, "the open")
    #expect(scene.surface(for: unreadablePane) == .chat)

    for round in 1...2 {
      scene.show(.terminal)
      await settle(scene, "round \(round), Chat → Terminal")
      #expect(scene.surface(for: unreadablePane) == .terminal)
      // Needed beside `settle`: a controller is promoted by herdr's first frame, off the
      // stream's pump, so the role can still be `.observer` when the chain drains.
      await waitUntil("round \(round): the Terminal side never took the controller") {
        scene.currentRole == .controller
      }

      scene.show(.chat)
      await settle(scene, "round \(round), Terminal → Chat")
      #expect(scene.surface(for: unreadablePane) == .chat)
      // The observer replaces the controller and the emulator is never torn down.
      await waitUntil("round \(round): the Chat side never gave the desk back to an observer") {
        scene.currentRole == .observer
      }
    }

    // One entry, not one per round: the switch replaces what the pane holds.
    #expect(scene.entries.filter { $0.target == unreadablePane }.count == 1)
    // See `liveStreams`. Above one is a controller opened and never installed or handed back.
    let log = await transport.streamLog
    #expect(liveStreams(in: log, on: "term_w2p1") == 1)
    #expect(scene.notice == nil)
  }
}

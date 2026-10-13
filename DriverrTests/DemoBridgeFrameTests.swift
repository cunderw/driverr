import Foundation
import Testing

@testable import Driverr

/// What the fake bridge puts on a pane's terminal. A pane is fed by `bridgeFrame`, not by the
/// PTY greeting, so the store tour's terminal shots show whatever this frame carries.
@Suite("Fake bridge frame", .timeLimit(.minutes(1)))
struct DemoBridgeFrameTests {
  private let command = "herdr terminal session control 'term_w1p2' --cols 55 --rows 28"

  /// The bytes of the one `terminal.frame` record, as the emulator receives them.
  private func text(isDemo: Bool) throws -> String {
    let frame = AppEnvironment.bridgeFrame(for: command, isDemo: isDemo)
    let record = try #require(
      try JSONSerialization.jsonObject(with: frame) as? [String: Any],
      "The frame is not one JSON record")
    #expect(record["type"] as? String == "terminal.frame")
    let encoded = try #require(record["bytes"] as? String, "The frame carries no bytes")
    let bytes = try #require(Data(base64Encoded: encoded), "The frame's bytes are not base64")
    return String(decoding: bytes, as: UTF8.self)
  }

  /// `PaneAttachUITests`, `PaneSwitchUITests` and `TerminalReconnectUITests` read this line to
  /// prove which pane opened.
  @Test("An ordinary launch names the terminal and prints nothing else")
  func anOrdinaryLaunchNamesTheTerminal() throws {
    #expect(try text(isDemo: false) == "herdr pane term_w1p2\r\n")
  }

  @Test("The store tour's frame is the agent session, without the line that names the terminal")
  func theStoreTourFrameIsTheAgentSession() throws {
    let text = try text(isDemo: true)
    #expect(text == AppEnvironment.demoTranscript)
    #expect(!text.contains("herdr pane term_w1p2"))
  }
}

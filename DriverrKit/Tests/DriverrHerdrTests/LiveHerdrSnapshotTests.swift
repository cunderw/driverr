import DriverrCore
import Foundation
import Testing

@testable import DriverrHerdr

/// Runs `herdr` locally, if it is here.
private enum LocalHerdr {
  /// `CLIControl.fallbackPaths` itself, not a copy. A copy that misses `~/.local/bin` skips
  /// the suite silently even with the variable set, and a skipped tripwire reports the same
  /// green as a passing one.
  static let binary: String? = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return CLIControl.fallbackPaths
      .map { $0.replacingOccurrences(of: "$HOME", with: home) }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }()

  static var isRunning: Bool {
    (run("status", "server") ?? "").contains("status: running")
  }

  static var isAvailable: Bool { binary != nil && isRunning }

  static func run(_ arguments: String...) -> String? {
    guard let binary else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

/// Keeps the hand-built `SnapshotMapperTests` fixture honest: a real herdr's snapshot is
/// decoded and mapped by the app's code.
///
/// Off unless `DRIVERR_LIVE_HERDR=1` and a herdr server is running on this machine. The
/// variable is tested first, so a default run starts no `herdr` process. Run it by hand:
///
/// ```sh
/// DRIVERR_LIVE_HERDR=1 swift test --package-path DriverrKit --filter LiveHerdrSnapshot
/// ```
///
/// A default run leaves it out because `protocolIsUnderstood` fails on a herdr newer than
/// `HerdrProtocol.lastVerified`, on any machine and for any diff. It is read-only
/// (`status server` and `api snapshot`), so it is safe against the herdr you are using.
@Suite(
  "Live herdr snapshot",
  .enabled(
    if: ProcessInfo.processInfo.environment["DRIVERR_LIVE_HERDR"] == "1" && LocalHerdr.isAvailable
  )
)
struct LiveHerdrSnapshotTests {
  @Test("a real snapshot decodes and maps without loss")
  func decodesRealSnapshot() async throws {
    let json = try #require(LocalHerdr.run("api", "snapshot"))

    let control = CLIControl { _ in
      CommandResult(standardOutput: json, standardError: "", exitStatus: 0)
    }
    let tree = try await control.snapshot()

    // Whatever this machine's session holds must survive the round trip intact.
    let raw = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    let snapshot = try #require(
      (raw["result"] as? [String: Any])?["snapshot"] as? [String: Any]
    )
    let rawWorkspaces = try #require(snapshot["workspaces"] as? [[String: Any]])
    let rawPanes = try #require(snapshot["panes"] as? [[String: Any]])

    #expect(tree.workspaces.count == rawWorkspaces.count)
    #expect(tree.allPanes.count == rawPanes.count, "panes were dropped in mapping")

    let tabIDs = Set(tree.workspaces.flatMap { $0.tabs.map(\.id) })
    for pane in tree.allPanes {
      #expect(!pane.title.isEmpty, "a pane with no title would render as a blank row")
      #expect(tabIDs.contains(pane.tabID), "pane \(pane.id) is under no known tab")
    }
  }

  @Test("this build understands the protocol the local herdr speaks")
  func protocolIsUnderstood() throws {
    // A tripwire, not a verdict on herdr: it says when the protocol moves past these wire
    // types.
    let status = try #require(LocalHerdr.run("status", "server"))
    // Through the app's own lookup, so a renamed key cannot make the test go quiet.
    let fields = CLIControl.statusFields(status)
    let version = try #require(
      CLIControl.protocolVersion(in: fields),
      "herdr status changed shape: \(status)"
    )
    #expect(
      version >= HerdrProtocol.minimum,
      "the local herdr speaks protocol \(version), below Driverr's floor of \(HerdrProtocol.minimum). Driverr cannot map it; update herdr."
    )
    // Nothing is refused above `lastVerified`, but the schema should be re-read before raising
    // it.
    #expect(
      version <= HerdrProtocol.lastVerified,
      "herdr now speaks protocol \(version); \(HerdrProtocol.lastVerified) is the newest re-checked against these wire types. Diff `herdr api schema --json` against HerdrWireTypes.swift and raise HerdrProtocol.lastVerified. This does NOT block the app — the floor is what gates."
    )
  }
}

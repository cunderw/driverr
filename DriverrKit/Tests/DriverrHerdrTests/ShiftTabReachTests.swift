import DriverrCore
import Testing

@testable import DriverrHerdr

/// Whether Shift-Tab reaches a pane with its Shift intact. herdr below 0.8.2 (protocol 20)
/// turns `shift+tab` into a plain Tab, which does not change Claude Code's mode.
@Suite("Shift-Tab reach")
struct ShiftTabReachTests {
  @Test("a herdr TUI pane needs protocol 20 or newer")
  func tuiNeedsProtocol20() {
    #expect(HerdrAvailability.ready(version: "0.8.2", protocolVersion: 20)
      .deliversShiftTab(toPane: "w1:p1"))
    #expect(HerdrAvailability.ready(version: "0.9.5", protocolVersion: 22)
      .deliversShiftTab(toPane: "w1:p1"))
    #expect(!HerdrAvailability.ready(version: "0.8.0", protocolVersion: 19)
      .deliversShiftTab(toPane: "w1:p1"))
    #expect(
      HerdrAvailability.readyWithCoreRefused(
        version: "0.9.5", protocolVersion: 22, coreVersion: nil, coreGeneration: nil,
        coreMissingMethods: []
      ).deliversShiftTab(toPane: "w1:p1"))
    #expect(
      !HerdrAvailability.readyWithCoreRefused(
        version: "0.8.0", protocolVersion: 19, coreVersion: nil, coreGeneration: nil,
        coreMissingMethods: []
      ).deliversShiftTab(toPane: "w1:p1"))
  }

  /// `.combined` carries the TUI's version and no protocol number, so the version decides.
  @Test("beside a core, the TUI's version decides")
  func combinedReadsTheVersion() {
    for version in ["0.8.2", "0.8.10", "0.9.5", "1.0", "0.9.5-dev"] {
      #expect(
        HerdrAvailability.combined(herdrVersion: version, coreVersion: "0.1.21")
          .deliversShiftTab(toPane: "w1:p1"), "\(version)")
    }
    for version in ["0.8.1", "0.8.0", "0.7.5", "", "unknown"] {
      #expect(
        !HerdrAvailability.combined(herdrVersion: version, coreVersion: "0.1.21")
          .deliversShiftTab(toPane: "w1:p1"), "\(version)")
    }
  }

  /// A core pane is typed into by a viewer, which writes ESC [ Z whatever the TUI is.
  @Test("a core pane always gets it, whatever the TUI beside it")
  func corePanes() {
    let pane = CorePaneID.id(forAddress: "t4k")
    #expect(HerdrAvailability.coreReady(version: "0.1.21").deliversShiftTab(toPane: pane))
    #expect(
      HerdrAvailability.combined(herdrVersion: "0.8.0", coreVersion: "0.1.21")
        .deliversShiftTab(toPane: pane))
  }

  @Test("no answer, or an unusable one, reaches nothing")
  func notReady() {
    let unusable: [HerdrAvailability] = [
      .notInstalled, .serverNotRunning(version: "0.9.5"), .tooOld(version: "0.6", protocolVersion: 16),
      .statusUnreadable(version: nil), .coreIncompatible(version: nil, generation: nil, missingMethods: []),
    ]
    for availability in unusable {
      #expect(!availability.deliversShiftTab(toPane: "w1:p1"), "\(availability)")
    }
    // A TUI pane id on a core-only host has no TUI to reach.
    #expect(!HerdrAvailability.coreReady(version: "0.1.21").deliversShiftTab(toPane: "w1:p1"))
  }
}

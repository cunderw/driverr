import Foundation
import Testing

@testable import DriverrCore

@Suite("BackgroundRefreshPolicy")
struct BackgroundRefreshPolicyTests {
  /// The system honours roughly fifteen minutes while the phone is in use. Changing it changes
  /// how often Driverr opens an SSH connection from a pocket.
  @Test("the next refresh is asked for fifteen minutes out")
  func theIntervalIsFifteenMinutes() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(BackgroundRefreshPolicy.interval == 900)
    #expect(BackgroundRefreshPolicy.nextEarliestBegin(after: now) == now.addingTimeInterval(900))
  }
}

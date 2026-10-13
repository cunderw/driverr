import Foundation
import Testing

@testable import DriverrCore

/// The stamp tells two builds apart.
@Suite("AppBuildStamp")
struct AppBuildStampTests {
  private let fixed = TimeZone(identifier: "America/Chicago")!
  private let english = Locale(identifier: "en_US")

  @Test("says the version the way Apple writes it")
  func versionSummary() {
    let stamp = AppBuildStamp(version: "1.0.0", build: "1", builtAt: nil)
    #expect(stamp.versionSummary == "1.0.0 (1)")
  }

  /// Builds are minutes apart and `CFBundleShortVersionString` does not change between them.
  @Test("two builds minutes apart do not read the same")
  func minutesApartAreDistinguishable() {
    let first = Date(timeIntervalSince1970: 1_787_000_000)
    let second = first.addingTimeInterval(60 * 7)
    let a = AppBuildStamp(version: "1.0.0", build: "1", builtAt: first)
    let b = AppBuildStamp(version: "1.0.0", build: "1", builtAt: second)
    #expect(a.versionSummary == b.versionSummary)
    #expect(a.builtSummary(locale: english, timeZone: fixed)
      != b.builtSummary(locale: english, timeZone: fixed))
  }

  @Test("an unreadable build date says so")
  func missingDateIsStated() {
    let stamp = AppBuildStamp(version: "1.0.0", build: "1", builtAt: nil)
    #expect(stamp.builtSummary(locale: english, timeZone: fixed) == "Build date unavailable")
  }

  @Test("the date carries the day and the time")
  func summaryCarriesDayAndTime() {
    let stamp = AppBuildStamp(
      version: "1.0.0", build: "1", builtAt: Date(timeIntervalSince1970: 1_787_000_000))
    let summary = stamp.builtSummary(locale: english, timeZone: fixed)
    #expect(summary.contains("2026"))
    #expect(summary.contains(":"))
  }

  /// The test bundle has an `executableURL` and an Info.plist, so every branch runs.
  @Test("reads a real bundle without inventing anything")
  func readsARealBundle() {
    let stamp = AppBuildStamp(bundle: .main)
    #expect(!stamp.version.isEmpty)
    #expect(!stamp.build.isEmpty)
  }
}

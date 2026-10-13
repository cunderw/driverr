import Foundation

/// Which build of Driverr is running, readable on a phone.
///
/// Installing over a running app does not swap its code, so a bug report can be about a
/// binary two installs old. `CFBundleShortVersionString` is the same for every build. The
/// time comes from the executable's own modification date, so no build step has to stamp
/// it.
public struct AppBuildStamp: Equatable, Sendable {
  public let version: String
  public let build: String
  /// When the running executable was written, or `nil` if unreadable, rather than a
  /// plausible guess.
  public let builtAt: Date?

  public init(version: String, build: String, builtAt: Date?) {
    self.version = version
    self.build = build
    self.builtAt = builtAt
  }

  /// `1.0.0 (1)`: the two Info.plist values, in Apple's order.
  public var versionSummary: String {
    "\(version) (\(build))"
  }

  /// `30 Aug 2026 at 12:05`, in the reader's own locale and time zone.
  ///
  /// To the minute, because builds in one session are minutes apart.
  public func builtSummary(
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    guard let builtAt else { return "Build date unavailable" }
    var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
    format.locale = locale
    format.timeZone = timeZone
    return builtAt.formatted(format)
  }

  /// Read off the running bundle, injectable for tests.
  public init(bundle: Bundle = .main, fileManager: FileManager = .default) {
    version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    // `executableURL`, not `bundleURL`: a directory's date moves when anything inside is
    // touched.
    builtAt = bundle.executableURL
      .flatMap { try? fileManager.attributesOfItem(atPath: $0.path) }
      .flatMap { $0[.modificationDate] as? Date }
  }
}

import DriverrCore
import DriverrHerdr
import Foundation

/// A tmux version, for the floor.
public struct TmuxVersion: Hashable, Comparable, Sendable {
  public let major: Int
  public let minor: Int
  /// What `tmux -V` printed after the name, such as `3.7c` or `next-3.5`.
  public let text: String

  /// The oldest tmux Driverr accepts.
  ///
  /// 3.2 is where `attach-session -f` and `refresh-client -A` exist, which the live terminal
  /// needs. It leaves out RHEL 8's 2.7.
  public static let minimum = TmuxVersion(major: 3, minor: 2, text: "3.2")

  public init(major: Int, minor: Int, text: String) {
    self.major = major
    self.minor = minor
    self.text = text
  }

  /// The version in `tmux -V`'s output, or `nil` when it says nothing this build can compare.
  ///
  /// Reads `tmux 3.7c`, `tmux next-3.5` and `tmux 3.4-rc`. A build from `master` has no number
  /// and is the newest there is. A distribution's own scheme, such as `openbsd-7.4`, is
  /// `nil`: guessing would let a floor pass or fail by luck.
  public static func parse(_ output: String) -> TmuxVersion? {
    let words = output.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
    guard words.count == 2, words[0] == "tmux" else { return nil }
    let text = String(words[1])
    if text == "master" { return TmuxVersion(major: .max, minor: 0, text: text) }

    // `next-3.5` is the development line leading to 3.5.
    let number = text.hasPrefix("next-") ? String(text.dropFirst("next-".count)) : text
    let parts = number.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
      let major = Int(parts[0]),
      let minor = Int(parts[1].prefix(while: \.isNumber))
    else { return nil }
    return TmuxVersion(major: major, minor: minor, text: text)
  }

  public static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
    (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }
}

/// Whether this host can serve tmux, and which "no" it is if not.
///
/// A tmux with no server is `.ready`: the first `new-session` starts one, so there is nothing
/// for the user to start first. The snapshot of such a host is an empty tree.
///
/// `asHerdrAvailability` maps it to `HerdrAvailability`'s tmux cases, which is what the app
/// reads.
public enum TmuxAvailability: Equatable, Sendable {
  case ready(version: String)
  case notInstalled
  /// Installed, and older than `TmuxVersion.minimum`.
  case tooOld(version: String)
  /// `tmux -V` ran and printed something this build cannot compare.
  case unreadable

  public var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  /// What to tell the user. The words are `HerdrAvailability`'s, so the two cannot drift.
  public var message: String { asHerdrAvailability.message }

  /// The version line's answer.
  static func from(_ result: CommandResult) -> TmuxAvailability {
    if result.exitStatus == 127 || result.standardError.contains("command not found") {
      return .notInstalled
    }
    guard result.exitStatus == 0, let version = TmuxVersion.parse(result.standardOutput) else {
      return .unreadable
    }
    return version >= TmuxVersion.minimum
      ? .ready(version: version.text) : .tooOld(version: version.text)
  }

  /// This answer in `HerdrAvailability`'s terms, which is what `HerdrControl.availability()`
  /// returns and what the app reads.
  public var asHerdrAvailability: HerdrAvailability {
    switch self {
    case .ready(let version): .tmuxReady(version: version)
    case .notInstalled: .tmuxNotInstalled
    case .tooOld(let version):
      .tmuxTooOld(version: version, minimumVersion: TmuxVersion.minimum.text)
    case .unreadable: .tmuxUnreadable
    }
  }
}

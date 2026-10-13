import Foundation

/// The agent stopped because its API request failed, not because it is waiting on the
/// reader.
///
/// Read from the session file only. Claude Code writes its own record when a request fails:
/// `type` `assistant`, `message.model` `<synthetic>`, `isApiErrorMessage: true`, and a typed
/// `error`. The record's text is the line the terminal prints. Seen in Claude Code 2.1.261
/// to 2.1.281:
///
/// - `rate_limit`, 429, with `quotaLimits`: `You've hit your session limit · resets 5:40pm
///   (America/Chicago)`. By far the most common.
/// - `unknown`, 400: `API Error: 400 Prompt too long: …`, and other 400s.
/// - `server_error`, no status: `API Error: Can't reach the API server …`, and `API Error:
///   Your computer went to sleep mid-response …`.
/// - `authentication_failed`, no status: `Login expired · Please run /login`.
///
/// `kind` comes from `error` only. Distinguishing "prompt too long" from other 400s would
/// mean matching text, which this module refuses, so the text travels as `message` and is
/// shown verbatim. No record carries the "approaching the limit" warning, so it is not a
/// state here.
public struct AgentStop: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// `error: "rate_limit"`. The plan's usage limit, with a reset time when `quotaLimits`
    /// carried one.
    case rateLimit
    /// `error: "authentication_failed"`.
    case loginExpired
    /// `error: "server_error"`: the host could not reach the API, or the response was cut
    /// off.
    case serverError
    /// Any other `error` value, including `unknown`, which a too-long prompt writes.
    case other
  }

  public let kind: Kind
  /// `quotaLimits.resetsAt` on a `rate_limit` record, otherwise `nil`.
  public let resetsAt: Date?
  /// The record's text, sanitised. Shown verbatim as the detail, except for a limit with a
  /// reset time, whose text names the host's clock.
  public let message: String
  /// When the record was written, on the host's clock. The parser hides the record's turn,
  /// so this keeps the Needs-you row's age on the stop.
  public let at: Date?

  public init(kind: Kind, resetsAt: Date? = nil, message: String = "", at: Date? = nil) {
    self.kind = kind
    self.resetsAt = resetsAt
    self.message = message
    self.at = at
  }

  /// The kind for a record's `error` field.
  public init(error: String?, resetsAt: Date? = nil, message: String = "", at: Date? = nil) {
    let kind: Kind =
      switch error {
      case "rate_limit": .rateLimit
      case "authentication_failed": .loginExpired
      case "server_error": .serverError
      default: .other
      }
    self.init(kind: kind, resetsAt: kind == .rateLimit ? resetsAt : nil, message: message, at: at)
  }

  /// Whether the stop still holds at `now`. Only a limit with a reset time lapses on its
  /// own. Anything else holds until a later record clears it, which is the parser's call.
  public func isLive(at now: Date) -> Bool {
    guard let resetsAt else { return true }
    return now < resetsAt
  }
}

/// What the chat's stop notice says. A function of `asOf`, so a `TimelineView` can make it go
/// stale at the reset and tests can inject a date.
///
/// The reset time is shown in the phone's time zone, not the host zone the record names.
/// `timeZone` and `locale` are parameters so tests do not depend on the machine.
public struct AgentStopNotice: Hashable, Sendable {
  public let title: String
  public let detail: String?
  /// The limit's reset time has passed. The notice stays, because the stop is still the
  /// newest record, but it no longer claims the agent is limited.
  public let isStale: Bool
  /// The SF Symbol for the stop, shared by the chat's card and the Needs-you row so they
  /// cannot drift.
  public let symbolName: String

  public init(
    stop: AgentStop, asOf now: Date, timeZone: TimeZone = .current, locale: Locale = .current
  ) {
    isStale = !stop.isLive(at: now)
    symbolName = Self.symbolName(for: stop.kind, isStale: isStale)
    switch stop.kind {
    case .rateLimit:
      // No `quotaLimits`: the record's text is the only reset time, so it is shown as
      // written, host zone and all.
      guard let resetsAt = stop.resetsAt else {
        title = "Usage limit reached"
        detail = Self.nonEmpty(stop.message)
        return
      }
      let when = Self.resetPhrase(resetsAt, asOf: now, timeZone: timeZone, locale: locale)
      if isStale {
        title = "Usage limit reset"
        detail = "It reset \(when)."
      } else {
        title = "Usage limit reached"
        detail = "Resets \(when)."
      }
    case .loginExpired:
      title = "Sign-in required"
      detail = Self.nonEmpty(stop.message)
    case .serverError:
      title = "API request failed"
      detail = Self.nonEmpty(stop.message)
    case .other:
      title = "API error"
      detail = Self.nonEmpty(stop.message)
    }
  }

  /// Title and detail as one sentence pair, for VoiceOver.
  public var accessibilityLabel: String {
    guard let detail else { return "Agent stopped. \(title)." }
    return "Agent stopped. \(title). \(detail)"
  }

  /// `at 5:40 PM` today in `timeZone`, `tomorrow at 5:40 PM`, or `on Tue, Sep 29 at 5:40 PM`
  /// further out. A weekly limit resets days away, and a bare time would read as today.
  static func resetPhrase(
    _ date: Date, asOf now: Date, timeZone: TimeZone, locale: Locale
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let time = date.formatted(
      Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
    ).day ?? 0
    switch days {
    case 0: return "at \(time)"
    case 1: return "tomorrow at \(time)"
    case -1: return "yesterday at \(time)"
    default:
      var style = Date.FormatStyle(locale: locale, timeZone: timeZone)
      style = style.weekday(.abbreviated).month(.abbreviated).day()
      return "on \(date.formatted(style)) at \(time)"
    }
  }

  private static func symbolName(for kind: AgentStop.Kind, isStale: Bool) -> String {
    if isStale { return "clock.arrow.circlepath" }
    switch kind {
    case .rateLimit: return "hourglass"
    case .loginExpired: return "person.crop.circle.badge.exclamationmark"
    case .serverError: return "wifi.exclamationmark"
    case .other: return "exclamationmark.triangle"
    }
  }

  private static func nonEmpty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

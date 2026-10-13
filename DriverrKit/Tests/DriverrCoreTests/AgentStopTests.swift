import DriverrCore
import Foundation
import Testing

/// What the chat's stop notice says, against an injected clock, zone and locale.
struct AgentStopTests {
  private static let chicago = TimeZone(identifier: "America/Chicago")!
  private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
  private static let enUS = Locale(identifier: "en_US")

  /// 22:40 UTC on the 27th: 5:40 PM in Chicago, 7:40 AM on the 28th in Tokyo.
  private static let resetsAt = Date(timeIntervalSince1970: 1_790_548_800)

  private static func notice(
    _ stop: AgentStop, secondsBeforeReset: TimeInterval, in zone: TimeZone = chicago
  ) -> AgentStopNotice {
    AgentStopNotice(
      stop: stop, asOf: resetsAt.addingTimeInterval(-secondsBeforeReset), timeZone: zone,
      locale: enUS)
  }

  private static let limit = AgentStop(
    kind: .rateLimit, resetsAt: resetsAt,
    message: "You've hit your session limit · resets 5:40pm (America/Chicago)")

  /// `Date.FormatStyle` puts a narrow no-break space before the day period in `en_US`.
  private static func time(_ clock: String) -> String {
    clock.replacingOccurrences(of: " ", with: "\u{202F}")
  }

  @Test("a live limit names its reset time in the phone's zone, not the host's")
  func liveLimit() {
    let here = Self.notice(Self.limit, secondsBeforeReset: 3_600)
    #expect(here.title == "Usage limit reached")
    #expect(here.detail == "Resets at \(Self.time("5:40 PM")).")
    #expect(!here.isStale)

    // Twelve hours before the reset is 7:40 PM on the 27th in Tokyo, and the reset is the
    // next morning there.
    let tokyo = Self.notice(Self.limit, secondsBeforeReset: 12 * 3_600, in: Self.tokyo)
    #expect(tokyo.detail == "Resets tomorrow at \(Self.time("7:40 AM")).")
  }

  @Test("a limit that resets days away does not print a bare time")
  func weeklyLimit() {
    let notice = Self.notice(Self.limit, secondsBeforeReset: 3 * 86_400)
    #expect(notice.detail == "Resets on Sun, Sep 27 at \(Self.time("5:40 PM")).")
  }

  @Test("once the reset time passes the notice is stale and says so")
  func staleLimit() {
    let notice = Self.notice(Self.limit, secondsBeforeReset: -60)
    #expect(notice.isStale)
    #expect(notice.title == "Usage limit reset")
    #expect(notice.detail == "It reset at \(Self.time("5:40 PM")).")
    #expect(Self.notice(Self.limit, secondsBeforeReset: 0).isStale)
  }

  @Test("a limit with no reset time is never stale and shows the record's own text")
  func limitWithoutTime() {
    let notice = AgentStopNotice(
      stop: AgentStop(kind: .rateLimit, message: "You've hit your session limit"),
      asOf: .distantFuture, timeZone: Self.chicago, locale: Self.enUS)
    #expect(notice.title == "Usage limit reached")
    #expect(notice.detail == "You've hit your session limit")
    #expect(!notice.isStale)
  }

  @Test("the other kinds are never stale, and show the record's own text verbatim")
  func otherKinds() {
    let login = Self.notice(
      AgentStop(kind: .loginExpired, message: "Login expired · Please run /login"),
      secondsBeforeReset: -86_400)
    #expect(login.title == "Sign-in required")
    #expect(login.detail == "Login expired · Please run /login")
    #expect(!login.isStale)

    let tooLong = Self.notice(
      AgentStop(kind: .other, message: "API Error: 400 Prompt too long: 129845 tokens"),
      secondsBeforeReset: 0)
    #expect(tooLong.title == "API error")
    #expect(tooLong.detail == "API Error: 400 Prompt too long: 129845 tokens")

    let unreachable = Self.notice(
      AgentStop(kind: .serverError, message: "API Error: Can't reach the API server"),
      secondsBeforeReset: 0)
    #expect(unreachable.title == "API request failed")
    #expect(unreachable.detail == "API Error: Can't reach the API server")
    #expect(unreachable.accessibilityLabel
      == "Agent stopped. API request failed. API Error: Can't reach the API server")
  }

  /// The chat's card and the Needs You row draw the same glyph, from here.
  @Test("each kind has its own glyph, and a limit that reset has the reset glyph")
  func symbols() {
    #expect(Self.notice(Self.limit, secondsBeforeReset: 60).symbolName == "hourglass")
    #expect(
      Self.notice(Self.limit, secondsBeforeReset: -60).symbolName == "clock.arrow.circlepath")
    #expect(
      Self.notice(AgentStop(kind: .loginExpired), secondsBeforeReset: 0).symbolName
        == "person.crop.circle.badge.exclamationmark")
    #expect(
      Self.notice(AgentStop(kind: .serverError), secondsBeforeReset: 0).symbolName
        == "wifi.exclamationmark")
    #expect(
      Self.notice(AgentStop(kind: .other), secondsBeforeReset: 0).symbolName
        == "exclamationmark.triangle")
  }

  @Test("`error` values map to kinds, and only a limit keeps a reset time")
  func kindFromError() {
    #expect(AgentStop(error: "rate_limit", resetsAt: Self.resetsAt).kind == .rateLimit)
    #expect(AgentStop(error: "authentication_failed").kind == .loginExpired)
    #expect(AgentStop(error: "server_error").kind == .serverError)
    #expect(AgentStop(error: "unknown").kind == .other)
    #expect(AgentStop(error: nil).kind == .other)
    #expect(AgentStop(error: "server_error", resetsAt: Self.resetsAt).resetsAt == nil)
  }

  /// The parser hides the stop's own turn, so without these the Needs You row would quote
  /// and date the pane from the reply before the stop.
  @Test("a standing stop is the page's last message and its last activity")
  func stopIsTheLastWord() {
    let earlier = Date(timeIntervalSince1970: 1_000)
    let stoppedAt = Date(timeIntervalSince1970: 2_000)
    let turns = [
      TranscriptTurn(id: "a1", speech: .assistant("looking into it"), at: earlier)
    ]
    let stopped = Transcript(
      turns: turns, window: .none,
      agentStop: AgentStop(kind: .rateLimit, message: "You've hit your session limit", at: stoppedAt))
    #expect(stopped.lastAssistantMessage == "You've hit your session limit")
    #expect(stopped.lastActivity == stoppedAt)

    let running = Transcript(turns: turns, window: .none)
    #expect(running.lastAssistantMessage == "looking into it")
    #expect(running.lastActivity == earlier)
  }
}

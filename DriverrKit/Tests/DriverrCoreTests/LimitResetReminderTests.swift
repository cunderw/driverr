import DriverrCore
import Foundation
import Testing

/// When a usage limit's reset reminder fires, against an injected clock and zone.
@Suite("LimitResetReminder")
struct LimitResetReminderTests {
  private static let chicago = TimeZone(identifier: "America/Chicago")!
  private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

  /// 22:40 UTC on 2026-09-27: 5:40 PM in Chicago, 7:40 AM on the 28th in Tokyo.
  private static let resetsAt = Date(timeIntervalSince1970: 1_790_548_800)

  private static func limit(resetsAt: Date? = resetsAt) -> AgentStop {
    AgentStop(kind: .rateLimit, resetsAt: resetsAt, message: "You've hit your session limit")
  }

  private static func schedule(
    _ stop: AgentStop?, asOf now: Date = resetsAt.addingTimeInterval(-3_600),
    in zone: TimeZone = chicago
  ) -> LimitResetReminder? {
    LimitResetReminder.schedule(for: stop, conversation: "s1", asOf: now, timeZone: zone)
  }

  /// The instant the trigger's own components name.
  private static func instant(of trigger: DateComponents) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = trigger.timeZone ?? TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: trigger)
  }

  @Test("a live limit fires at its reset, named by the conversation")
  func liveLimit() throws {
    let reminder = try #require(Self.schedule(Self.limit()))
    #expect(reminder.id == "limitReset:s1")
    #expect(reminder.fireDate == Self.resetsAt)
    #expect(reminder.trigger.timeZone == Self.chicago)
    #expect(reminder.trigger.hour == 17)
    #expect(reminder.trigger.minute == 40)
    #expect(Self.instant(of: reminder.trigger) == Self.resetsAt)
  }

  @Test("two zones give different wall clocks for the same instant")
  func twoZones() throws {
    let here = try #require(Self.schedule(Self.limit(), in: Self.chicago))
    let there = try #require(Self.schedule(Self.limit(), in: Self.tokyo))
    #expect(here.trigger.day == 27)
    #expect(there.trigger.day == 28)
    #expect(there.trigger.hour == 7)
    #expect(there.trigger.timeZone == Self.tokyo)
    #expect(Self.instant(of: here.trigger) == Self.resetsAt)
    #expect(Self.instant(of: there.trigger) == Self.resetsAt)
    #expect(here.id == there.id)
  }

  /// Daylight saving time ends in Chicago at 2:00 AM CDT on 2026-11-01, so 1:30 AM happens
  /// twice: 06:30 UTC, then 07:30 UTC.
  @Test("a reset in the repeated hour fires at the right one of the two", arguments: [
    (1_793_514_600.0, true),  // 06:30 UTC, the first 1:30 AM, CDT.
    (1_793_518_200.0, false),  // 07:30 UTC, the second 1:30 AM, CST.
  ])
  func endOfDaylightSaving(seconds: TimeInterval, staysLocal: Bool) throws {
    let resetsAt = Date(timeIntervalSince1970: seconds)
    let reminder = try #require(
      Self.schedule(Self.limit(resetsAt: resetsAt), asOf: resetsAt.addingTimeInterval(-7_200)))
    #expect(reminder.fireDate == resetsAt)
    #expect(Self.instant(of: reminder.trigger) == resetsAt)
    // The second 1:30 AM cannot be named in Chicago, so its components are in GMT.
    #expect((reminder.trigger.timeZone == Self.chicago) == staysLocal)
  }

  @Test("a reset across the start of daylight saving time keeps its instant")
  func startOfDaylightSaving() throws {
    // 08:30 UTC on 2026-03-08 is 3:30 AM CDT, the hour after the skipped one.
    let resetsAt = Date(timeIntervalSince1970: 1_772_958_600)
    let reminder = try #require(
      Self.schedule(Self.limit(resetsAt: resetsAt), asOf: resetsAt.addingTimeInterval(-7_200)))
    #expect(reminder.trigger.timeZone == Self.chicago)
    #expect(reminder.trigger.hour == 3)
    #expect(Self.instant(of: reminder.trigger) == resetsAt)
  }

  @Test("a reset already past, or now, schedules nothing")
  func pastReset() {
    #expect(Self.schedule(Self.limit(), asOf: Self.resetsAt.addingTimeInterval(60)) == nil)
    #expect(Self.schedule(Self.limit(), asOf: Self.resetsAt) == nil)
    #expect(Self.schedule(Self.limit(), asOf: Self.resetsAt.addingTimeInterval(-1)) != nil)
  }

  @Test("a stop with no reset time, another kind of stop, or none schedules nothing")
  func nothingToSchedule() {
    #expect(Self.schedule(Self.limit(resetsAt: nil)) == nil)
    #expect(Self.schedule(AgentStop(kind: .serverError)) == nil)
    #expect(Self.schedule(AgentStop(kind: .loginExpired)) == nil)
    #expect(Self.schedule(nil) == nil)
  }

  @Test("a reset with a fraction of a second fires on the next whole second")
  func fractionalReset() throws {
    let reminder = try #require(
      Self.schedule(Self.limit(resetsAt: Self.resetsAt.addingTimeInterval(-0.25))))
    #expect(reminder.fireDate == Self.resetsAt)
  }

  @Test("the identifier is not a blocked-pane identifier")
  func separateFromBlockedPanes() {
    let blocked = BlockedPaneAlerts.notificationID(hostID: UUID(), paneID: "s1")
    #expect(!LimitResetReminder.notificationID(conversation: "s1").hasPrefix("blocked:"))
    #expect(LimitResetReminder.notificationID(conversation: "s1") != blocked)
  }

  @Test("the body names the pane and the host, or the host alone")
  func body() {
    #expect(
      LimitResetReminder.body(paneTitle: "fix the parser", hostName: "workbox")
        == "fix the parser on workbox can continue.")
    #expect(LimitResetReminder.body(paneTitle: " ", hostName: "workbox") == "workbox can continue.")
  }
}

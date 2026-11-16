import Foundation

/// The local notification for a usage limit's reset: when it fires and what it is called.
///
/// A stop maps to a reminder only when it is a usage limit with a reset time still ahead.
/// Every other stop, and a reset already past, maps to nothing.
///
/// The identifier names the conversation, not the host and pane. Two connected hosts can
/// each hold a model for one pane: a machine's own host, and a host whose herdr-core added
/// that machine. Their pane ids differ, but the session file is the same, so both schedule
/// one request and the second replaces the first.
public struct LimitResetReminder: Hashable, Sendable {
  /// The notification identifier. See `notificationID(conversation:)`.
  public let id: String
  /// The reset time, rounded up to a whole second.
  public let fireDate: Date
  /// The trigger, with its `timeZone` set, so a phone that changes zone before the reset
  /// still fires at the same instant.
  public let trigger: DateComponents

  /// The notification identifier for one conversation.
  ///
  /// Separate from `BlockedPaneAlerts.notificationID(hostID:paneID:)`, so opening the pane
  /// withdraws the blocked-pane card and leaves this reminder alone.
  public static func notificationID(conversation: String) -> String {
    "limitReset:\(conversation)"
  }

  /// The reminder for `stop`, or `nil`.
  ///
  /// - Parameters:
  ///   - conversation: The session file's id, the same through every host that reads it.
  ///   - now: The phone's clock. A reset at or before `now` gives `nil`.
  ///   - timeZone: The zone of the trigger's components. A reset inside a repeated hour (the
  ///     end of daylight saving time) has the same wall clock twice, and the components
  ///     would match the first one. That reset gets its components in GMT, which repeats no
  ///     hour.
  public static func schedule(
    for stop: AgentStop?, conversation: String, asOf now: Date, timeZone: TimeZone
  ) -> LimitResetReminder? {
    guard let stop, stop.kind == .rateLimit, let resetsAt = stop.resetsAt else { return nil }
    let fireDate = Date(timeIntervalSince1970: resetsAt.timeIntervalSince1970.rounded(.up))
    guard fireDate > now else { return nil }
    let trigger =
      components(of: fireDate, in: timeZone)
      ?? components(of: fireDate, in: TimeZone(secondsFromGMT: 0)!)!
    return LimitResetReminder(
      id: notificationID(conversation: conversation), fireDate: fireDate, trigger: trigger)
  }

  /// The wall clock of `date` in `timeZone`, or `nil` if that wall clock names a different
  /// instant.
  private static func components(of date: Date, in timeZone: TimeZone) -> DateComponents? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    components.calendar = calendar
    components.timeZone = timeZone
    guard calendar.date(from: components) == date else { return nil }
    return components
  }

  /// The card's title, which names the event; the body names the conversation and machine.
  public static let title = "Usage limit reset"

  /// The card's body.
  public static func body(paneTitle: String, hostName: String) -> String {
    let pane = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return pane.isEmpty ? "\(hostName) can continue." : "\(pane) on \(hostName) can continue."
  }

  /// The action that opens the pane and sends `continueText`. Offered only when the reader
  /// opted in from the stop notice.
  public static let continueActionID = "limitReset.continue"
  /// The category that carries `continueActionID`.
  public static let continueCategoryID = "limitReset.withContinue"
  /// The action's button title.
  public static let continueActionTitle = "Continue"
  /// What the action sends to the pane.
  public static let continueText = "continue"

  /// The stop notice's opt-in, as the control reads it.
  public static let optInTitle = "Add Continue to the reset alert"
}

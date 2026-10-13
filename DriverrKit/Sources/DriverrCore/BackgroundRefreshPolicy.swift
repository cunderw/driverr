import Foundation

/// When Driverr asks iOS for its next background look at a host.
///
/// Fifteen minutes is a floor, not a schedule. `earliestBeginDate` promises only that the
/// task will not start sooner. On a real phone runs came every 15 to 17 minutes while in
/// use, with a gap of hours overnight. Asking for less does not produce more runs, because
/// the system's budget spaces them.
public enum BackgroundRefreshPolicy {
  /// The gap Driverr asks for between refreshes.
  public static let interval: TimeInterval = 15 * 60

  /// The earliest a refresh submitted now may begin.
  ///
  /// Takes `now` rather than reading the clock, so tests can assert it.
  public static func nextEarliestBegin(after now: Date) -> Date {
    now.addingTimeInterval(interval)
  }
}

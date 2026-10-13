/// The backoff Driverr retries a lost connection on while its terminal scene stays open.
///
/// Doubling from 1 s (1, 2, 4, 8, 16), capped at 30 s, until a 120 s deadline. When the next
/// delay would pass the deadline, the sequence ends and the caller offers a manual Reconnect.
public struct ReconnectSchedule: Sequence, Sendable {
  public static let steps: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
  public static let deadline = Duration.seconds(120)

  public init() {}

  public func makeIterator() -> Iterator { Iterator() }

  public struct Iterator: IteratorProtocol {
    private var index = 0
    private var elapsed = Duration.zero

    public mutating func next() -> Duration? {
      let delay = index < ReconnectSchedule.steps.count
        ? ReconnectSchedule.steps[index]
        : ReconnectSchedule.steps[ReconnectSchedule.steps.count - 1]
      guard elapsed + delay <= ReconnectSchedule.deadline else { return nil }
      index += 1
      elapsed += delay
      return delay
    }
  }
}

/// What the transcript's pager says, and what a tap on it will cost.
///
/// A session file can be large and the phone may be on cellular, so the price goes on the
/// control rather than spending quietly on scroll. Every figure comes from
/// `TranscriptWindow`, what actually crossed the wire. First pages vary from about 1 KB to
/// 100 KB, so a literal would be wrong per session.
public struct TranscriptPaging: Equatable, Sendable {
  /// How many more turns a tap asks for.
  public static let defaultIncrement = 14

  /// Turns the reader currently holds.
  public let turnsHeld: Int
  /// What the last fetch actually cost, and what it says about the file behind it.
  public let window: TranscriptWindow
  public let increment: Int

  public init(
    turnsHeld: Int,
    window: TranscriptWindow,
    increment: Int = TranscriptPaging.defaultIncrement
  ) {
    self.turnsHeld = turnsHeld
    self.window = window
    self.increment = increment
  }

  /// `Last 6 turns · 61.4 KB fetched`, or `All 23 turns · 6.9 KB fetched` at the top. No
  /// tilde, because this figure is measured, unlike the estimate.
  public var held: String {
    let scope = window.reachesStartOfFile ? "All" : "Last"
    let noun = turnsHeld == 1 ? "turn" : "turns"
    return "\(scope) \(turnsHeld) \(noun) · \(ByteSize.phrase(window.bytesFetched)) fetched"
  }

  /// `Load up to 14 more · ~3.0 KB`, or `nil` at the start of the file.
  ///
  /// Removed, not disabled, when nothing is behind the page, and absent when there is no
  /// measurement to price from, because an unpriced control is what this replaces.
  ///
  /// Prices the delta, not the whole re-fetched tail, because it reads beside `held` as an
  /// amount on top of what was already fetched. That is what the reader will hold more of,
  /// not the wire cost. "up to" because the reader's ladder rounds up.
  public var loadMore: String? {
    guard let estimate = estimatedNextFetchBytes else { return nil }
    let delta = max(0, estimate - window.bytesFetched)
    return "Load up to \(increment) more · ~\(ByteSize.phrase(delta))"
  }

  /// `Load up to 14 more turns, about 3.0 kilobytes`: `loadMore`'s figure for VoiceOver,
  /// which reads `·`, `~` and `KB` literally.
  public var spokenLoadMore: String? {
    guard let estimate = estimatedNextFetchBytes else { return nil }
    let delta = max(0, estimate - window.bytesFetched)
    return "Load up to \(increment) more turns, about \(ByteSize.spoken(delta))"
  }

  /// Present only at the start of the file, where `loadMore` is absent.
  public var startOfFile: String? {
    window.reachesStartOfFile ? "This is the start of the session file." : nil
  }

  /// `Driverr stopped before it had all the turns it asked for. Load more to keep reading.`,
  /// or `nil` on an ordinary page.
  ///
  /// `held` alone says `Last 2 turns`, which a two-turn session also says. The second
  /// sentence is safe because `stoppedShort` is never set at the start of the file, so
  /// `loadMore` is always beside it.
  public var stoppedShort: String? {
    guard window.stoppedShort else { return nil }
    return "Driverr stopped before it had all the turns it asked for. "
      + "Load more to keep reading."
  }

  /// Whether `held` would only restate the count and size the mid-record notice states. True
  /// only at the start of the file, because a mid-file tail has more behind it and the two
  /// state different facts. `outcome` is passed in because `TranscriptPaging` is built from
  /// `TranscriptWindow` alone elsewhere.
  public func isBillRedundant(outcome: TranscriptOutcome) -> Bool {
    outcome == .endsMidRecord && window.reachesStartOfFile
  }

  /// What is behind the page, in bytes, because bytes are what Driverr knows. A turn count
  /// would be a guess: turn sizes vary hugely, and one long autonomous turn can be most of a
  /// file.
  public var unfetched: String? {
    guard !window.reachesStartOfFile else { return nil }
    return "The file is \(ByteSize.phrase(window.fileSizeInBytes)). "
      + "Driverr only ever fetches the tail."
  }

  /// Projected bytes for the whole next fetch, or `nil` when there is no next page.
  ///
  /// The reader always fetches a tail, so a tap re-reads a larger one. Scaled from this
  /// page's cost, which assumes even turns (hence the tilde), and capped at the file size.
  public var estimatedNextFetchBytes: Int? {
    guard !window.reachesStartOfFile else { return nil }
    guard turnsHeld > 0, window.bytesFetched > 0 else { return nil }
    let projected = window.bytesFetched * (turnsHeld + increment) / turnsHeld
    return min(projected, window.fileSizeInBytes)
  }

  /// Uses `spokenLoadMore`, because VoiceOver cannot read `loadMore`'s typography.
  public var accessibilityLabel: String {
    // `stoppedShort` follows the bill it qualifies, as on screen. Each part is ended rather
    // than joined with ". ", because some already end in a full stop.
    [held, stoppedShort, spokenLoadMore, startOfFile]
      .compactMap { $0 }
      .map { $0.hasSuffix(".") ? $0 : "\($0)." }
      .joined(separator: " ")
  }
}

/// Bytes as a person reads them: `837 B`, `6.9 KB`, `2.3 MB`.
///
/// 1024-based, with one decimal for KB and MB, including `.0`. Built from integers rather
/// than `String(format:)`, whose `%.1f` uses the locale's decimal separator.
public enum ByteSize {
  private static let kilobyte = 1024
  private static let megabyte = 1024 * 1024

  public static func phrase(_ bytes: Int) -> String {
    if bytes < kilobyte { return "\(bytes) B" }
    if bytes < megabyte { return decimal(bytes, over: kilobyte, unit: "KB") }
    return decimal(bytes, over: megabyte, unit: "MB")
  }

  /// `3.0 kilobytes` or `837 bytes`, for VoiceOver, which spells `KB` out letter by letter.
  public static func spoken(_ bytes: Int) -> String {
    if bytes < kilobyte { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
    if bytes < megabyte { return decimal(bytes, over: kilobyte, unit: "kilobytes") }
    return decimal(bytes, over: megabyte, unit: "megabytes")
  }

  private static func decimal(_ bytes: Int, over unit: Int, unit name: String) -> String {
    let tenths = Int((Double(bytes) / Double(unit) * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(name)"
  }
}

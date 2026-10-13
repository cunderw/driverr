import Foundation

/// How much of the agent's context the conversation fills.
///
/// A raw token count, not a percentage. A percentage needs each model's window size, which
/// changes with every model release, and a wrong percentage is worse than none.
///
/// Input plus both cache fields, output excluded: the prompt last sent, which is what fills
/// the window and what Claude Code's status line shows. Taken from the newest assistant
/// record with a non-zero sum (see `TranscriptParser.page(from:)`). Claude only; a Codex page
/// carries `nil`.
public struct ContextUsage: Hashable, Sendable {
  public let inputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int

  public init(inputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
    self.inputTokens = inputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
  }

  public var totalTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

  /// The provenance row's trailing text: `84k context`.
  public var compact: String { "\(Self.compactCount(totalTokens)) context" }

  /// What VoiceOver says for `compact`, which it would otherwise read as "84 k".
  public var spoken: String { "\(Self.grouped(totalTokens)) tokens in context" }

  /// The long-press detail: the total and the three fields it is the sum of.
  public var breakdown: String {
    "\(Self.grouped(totalTokens)) tokens in context: \(Self.grouped(inputTokens)) input, "
      + "\(Self.grouped(cacheCreationTokens)) cache write, \(Self.grouped(cacheReadTokens)) cache read"
  }

  /// `812`, `8.4k`, `84k`, `1.2M`. Rounded down, so 84,999 is `84k` and the row never
  /// overstates.
  static func compactCount(_ count: Int) -> String {
    let count = max(0, count)
    if count < 1_000 { return "\(count)" }
    if count < 10_000 { return oneDecimal(count, per: 1_000, unit: "k") }
    if count < 1_000_000 { return "\(count / 1_000)k" }
    if count < 10_000_000 { return oneDecimal(count, per: 1_000_000, unit: "M") }
    return "\(count / 1_000_000)M"
  }

  /// `8.4k`, and `8k` rather than `8.0k`.
  private static func oneDecimal(_ count: Int, per unit: Int, unit name: String) -> String {
    let tenths = count / (unit / 10)
    let whole = tenths / 10
    let fraction = tenths % 10
    return fraction == 0 ? "\(whole)\(name)" : "\(whole).\(fraction)\(name)"
  }

  /// `84,213`. A fixed locale, because the screen is English and tests must not depend on
  /// the machine.
  static func grouped(_ count: Int) -> String {
    count.formatted(.number.locale(Locale(identifier: "en_US")))
  }
}

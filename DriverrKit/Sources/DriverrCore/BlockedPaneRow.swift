import Foundation

/// The agent's last message, bounded to what one row of a list can hold.
///
/// `init?` returns `nil` when there is no message, so a view draws no quote block rather
/// than an empty box or a placeholder. That is the ordinary case for any pane whose
/// transcript Driverr cannot read.
///
/// The text arrives already sanitised by the producing module (`PaneScreenText.plain`). Do
/// not add a second scanner here. Raw control bytes reaching a view are a bug there.
public struct QuotedMessage: Hashable, Sendable {
  /// How many of the message's lines a row shows. The quote is a hint for triage, and the
  /// whole message is one tap away.
  public static let lineLimit = 2

  /// How many characters of those lines, because a markdown paragraph has no newlines and
  /// one "line" can run to thousands of characters.
  public static let characterLimit = 160

  /// What to show, newlines and all. Never empty.
  public let text: String

  /// Whether anything was left out. Stored because the view no longer has the original, and
  /// VoiceOver has to be told (`quoteAccessibilityLabel`).
  public let isTruncated: Bool

  public init?(quoting raw: String?) {
    guard let raw else { return nil }

    // Blank lines are closed up, so a heading followed by a blank line does not fill both
    // lines with whitespace.
    let lines =
      raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }

    let kept = lines.prefix(Self.lineLimit)
    var truncated = kept.count < lines.count
    var text = kept.joined(separator: "\n")
    if text.count > Self.characterLimit {
      text = Self.cut(text, to: Self.characterLimit) + "…"
      truncated = true
    }
    self.text = text
    isTruncated = truncated
  }

  /// The first `limit` characters, backed off to a word boundary where there is one, since
  /// a mid-word cut reads as corruption. A hard cut is the fallback for one long word.
  private static func cut(_ text: String, to limit: Int) -> String {
    let head = text.prefix(limit)
    let boundary = text.index(text.startIndex, offsetBy: limit)
    // Cutting exactly at a boundary keeps the whole last word.
    if text[boundary].isWhitespace { return trimmedEnd(String(head)) }
    guard let space = head.lastIndex(where: \.isWhitespace) else { return String(head) }
    return trimmedEnd(String(head[..<space]))
  }

  private static func trimmedEnd(_ text: String) -> String {
    var text = text
    while let last = text.last, last.isWhitespace { text.removeLast() }
    return text
  }
}

/// How long a pane has been waiting, in the two forms a row needs.
///
/// Separate from `TranscriptAge` on purpose. That one keeps sub-minute precision for the
/// provenance header, and this one says `now` for anything under a minute, which is right
/// for a wait. Do not build either on the other.
public enum WaitedFor {
  private static let minute: TimeInterval = 60
  private static let hour: TimeInterval = 60 * 60
  private static let day: TimeInterval = 24 * 60 * 60

  /// `4m`, the meta line's last field.
  public static func short(_ seconds: TimeInterval) -> String {
    let waited = clamped(seconds)
    if waited < minute { return "now" }
    if waited < hour { return "\(Int(waited / minute))m" }
    if waited < day { return "\(Int(waited / hour))h" }
    return "\(Int(waited / day))d"
  }

  /// `4 minutes`, the same fact for VoiceOver.
  public static func spoken(_ seconds: TimeInterval) -> String {
    let waited = clamped(seconds)
    if waited < minute { return "just now" }
    if waited < hour { return counted(Int(waited / minute), "minute") }
    if waited < day { return counted(Int(waited / hour), "hour") }
    return counted(Int(waited / day), "day")
  }

  public static func short(since: Date, asOf now: Date) -> String {
    short(now.timeIntervalSince(since))
  }

  public static func spoken(since: Date, asOf now: Date) -> String {
    spoken(now.timeIntervalSince(since))
  }

  /// A wait cannot run backwards. The timestamp is the host's clock and `now` is the phone's,
  /// so a phone behind its host would otherwise show `-1m`.
  private static func clamped(_ seconds: TimeInterval) -> TimeInterval {
    guard seconds.isFinite else { return 0 }
    return max(0, seconds)
  }

  private static func counted(_ count: Int, _ unit: String) -> String {
    "\(count) \(unit)\(count == 1 ? "" : "s")"
  }
}

/// One row of the Needs-you section: everything it draws, decided here.
///
/// Every field is optional, and a row leaves out what it does not know rather than showing
/// a placeholder or a guess. A pane whose transcript Driverr cannot read has no message and
/// no age.
public struct BlockedPaneRow: Identifiable, Hashable, Sendable {
  public var id: String { paneID }

  public let paneID: String
  public let title: String
  /// `Claude`, from `SnapshotMapper`. `nil` only for a pane with no agent, which
  /// `SessionTree.blockedPanes` never yields, but `Pane.agent` is optional.
  public let agentName: String?
  /// `driverr › app`, from `SessionTree.location(of:)`, or `nil` when unresolved.
  public let location: String?
  /// How long the conversation has been quiet, or `nil` when nothing said.
  public let waited: TimeInterval?
  /// `nil` whenever `stopNotice` is set: a stopped pane shows the stop, not a quote.
  public let quote: QuotedMessage?
  /// The failed API request the agent stopped on. The row draws its title in place of the
  /// quote. Draw `stopDetail`, not the notice's own `detail`.
  public let stopNotice: AgentStopNotice?
  /// The notice's detail, bounded like a quote. A detail can run to hundreds of characters.
  public let stopDetail: QuotedMessage?

  /// - Parameters:
  ///   - lastMessage: `Transcript.lastAssistantMessage`, or `nil` without a readable
  ///     transcript. Already sanitised; see `QuotedMessage`.
  ///   - quietSince: when the agent last wrote to its session file
  ///     (`Transcript.lastActivity`), or `nil`.
  ///   - blockedSince: when this pane was last seen entering `.blocked`, recorded by the
  ///     client. Used only when `quietSince` is `nil`, so a pane with no transcript still
  ///     has an age.
  ///   - stop: `Transcript.agentStop`, or `nil`. With one, the row shows the stop and no
  ///     quote. The record's text is Claude Code's terminal line, and quoting it made a
  ///     limited pane look like one waiting on its owner.
  ///   - now: passed rather than read, so a test can assert the age.
  ///   - timeZone, locale: for the reset time in `AgentStopNotice`, passed so tests do not
  ///     depend on the machine.
  public init(
    pane: Pane,
    location: String?,
    lastMessage: String?,
    quietSince: Date?,
    blockedSince: Date? = nil,
    stop: AgentStop? = nil,
    asOf now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) {
    paneID = pane.id
    title = pane.title
    agentName = pane.agent?.name
    self.location = location
    waited = (quietSince ?? blockedSince).map { max(0, now.timeIntervalSince($0)) }
    let notice = stop.map {
      AgentStopNotice(stop: $0, asOf: now, timeZone: timeZone, locale: locale)
    }
    stopNotice = notice
    stopDetail = QuotedMessage(quoting: notice?.detail)
    // `Transcript.lastAssistantMessage` returns the stop's text while a stop stands, so the
    // quote is dropped here.
    quote = notice == nil ? QuotedMessage(quoting: lastMessage) : nil
  }

  /// `Claude · driverr › app · 4m`: one line, with only the parts there are.
  public var meta: String {
    [agentName, location, waited.map(WaitedFor.short)]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  /// What VoiceOver hears instead of dot-separated fragments.
  ///
  /// The age is said as "last wrote 4 minutes ago", not "waiting for 4 minutes", because
  /// `waited` measures time since the transcript was written (or since the pane turned
  /// blocked), which can be several tool calls older than the current wait.
  ///
  /// The title is its own `Text` and announces itself, so it is not repeated here. A stopped
  /// pane is said to be stopped, or its limit to have reset, because it is not waiting on
  /// its owner even though herdr reports it blocked.
  public var metaAccessibilityLabel: String {
    let state = stopState ?? "waiting for you"
    var sentence =
      agentName.map { "\($0), \(state)" } ?? Self.capitalizingFirst(state)
    if let location { sentence += " in \(location)" }
    sentence += "."
    if let waited { sentence += " Last wrote \(Self.spokenAgo(waited))." }
    return sentence
  }

  /// "4 minutes ago", but "just now" stays bare rather than "just now ago".
  private static func spokenAgo(_ waited: TimeInterval) -> String {
    let spoken = WaitedFor.spoken(waited)
    return spoken == "just now" ? spoken : "\(spoken) ago"
  }

  /// The spoken label for the glyph in the badge's place. Never "Blocked", which means
  /// waiting on the owner.
  public var stopGlyphAccessibilityLabel: String? {
    stopState.map(Self.capitalizingFirst)
  }

  private static func capitalizingFirst(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  /// `stopped`, or `usage limit reset` once the reset time has passed, or `nil`. Uses
  /// `PaneStopBadge`'s words so the tree and the switcher agree.
  private var stopState: String? {
    stopNotice.map { PaneStopBadge.state(isStale: $0.isStale) }
  }

  /// The stop, spoken: `Usage limit reached. Resets at 5:40 PM.` The meta label has already
  /// said the agent stopped. `nil` without a stop.
  public var stopAccessibilityLabel: String? {
    guard let stopNotice else { return nil }
    guard let stopDetail else { return "\(stopNotice.title)." }
    let detail = stopDetail.text.replacingOccurrences(of: "\n", with: " ")
    return stopDetail.isTruncated
      ? "\(stopNotice.title). Shortened: \(detail)"
      : "\(stopNotice.title). \(detail)"
  }

  /// The quote, spoken, and named as the agent's last message, never as "the question". The
  /// last thing said can be older than what the agent is waiting on. `nil` without a quote.
  public var quoteAccessibilityLabel: String? {
    guard let quote else { return nil }
    let owner = agentName.map { "\($0)'s last message" } ?? "Last message"
    let opening = quote.isTruncated ? "\(owner), shortened" : owner
    // Spoken as one sentence, because VoiceOver reads newlines as nothing.
    return "\(opening): \(quote.text.replacingOccurrences(of: "\n", with: " "))"
  }
}

/// The Needs-you section's header. The count is drawn as a numeral and spoken in words.
public enum NeedsYouSection {
  /// `Needs You · 3`.
  public static func title(count: Int) -> String { "Needs You · \(count)" }

  /// `3 panes need you.` A spoken count names what it counts. Not "waiting for you",
  /// because a stopped pane stays in this section and is not waiting.
  public static func spokenTitle(count: Int) -> String {
    count == 1 ? "1 pane needs you." : "\(count) panes need you."
  }
}

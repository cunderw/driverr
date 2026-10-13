import Foundation
import Testing

@testable import DriverrCore

private func blockedPane(
  _ id: String = "w1:p2",
  title: String = "needs a decision",
  agent: Agent? = Agent(name: "Claude", kind: "claude", status: .blocked)
) -> Pane {
  Pane(id: id, tabID: "t1", workspaceID: "w1", title: title, agent: agent)
}

private let noon = Date(timeIntervalSince1970: 1_756_209_600)

@Suite("QuotedMessage")
struct QuotedMessageTests {
  @Test("a short single-line message is quoted whole and not marked truncated")
  func shortMessage() throws {
    let quote = try #require(QuotedMessage(quoting: "Two panes claim focus after a close."))
    #expect(quote.text == "Two panes claim focus after a close.")
    #expect(!quote.isTruncated)
  }

  @Test("nothing recoverable produces no quote at all")
  func nothingToQuote() {
    // A row with no recoverable question renders no quote block. An empty `QuotedMessage`
    // would give the view something to draw.
    #expect(QuotedMessage(quoting: nil) == nil)
    #expect(QuotedMessage(quoting: "") == nil)
    #expect(QuotedMessage(quoting: "   \n\n\t  ") == nil)
  }

  @Test("more lines than the row holds are cut, and the cut is declared")
  func tooManyLines() throws {
    let quote = try #require(
      QuotedMessage(quoting: "First line.\nSecond line.\nThird line.\nFourth line.")
    )
    #expect(quote.text == "First line.\nSecond line.")
    #expect(quote.isTruncated)
  }

  @Test("blank lines between paragraphs are closed up rather than spent")
  func blankLinesCollapse() throws {
    // Spending the row's two lines on blank lines renders a markdown message with a heading
    // as an empty quote block.
    let quote = try #require(QuotedMessage(quoting: "\n\nFirst line.\n\n\nSecond line.\n"))
    #expect(quote.text == "First line.\nSecond line.")
    #expect(!quote.isTruncated)
  }

  @Test("one enormous line is cut on a word boundary and ellipsised")
  func oneEnormousLine() throws {
    let long = String(repeating: "alpha beta ", count: 60)
    let quote = try #require(QuotedMessage(quoting: long))
    #expect(quote.isTruncated)
    #expect(quote.text.count <= QuotedMessage.characterLimit + 1)  // + the ellipsis
    #expect(quote.text.hasSuffix("…"))
    // A half word reads as corrupted text.
    #expect(!quote.text.contains("alph…"))
  }

  @Test("a word longer than the whole budget is still cut")
  func oneEnormousWord() throws {
    // There is no word boundary, but the cut must still happen, or a minified file pasted
    // into a prompt takes the row with it.
    let quote = try #require(QuotedMessage(quoting: String(repeating: "x", count: 4000)))
    #expect(quote.isTruncated)
    #expect(quote.text.count <= QuotedMessage.characterLimit + 1)
  }

  @Test("a message that only just fits is not marked truncated")
  func exactlyAtTheLimit() throws {
    let text = String(repeating: "a", count: QuotedMessage.characterLimit)
    let quote = try #require(QuotedMessage(quoting: text))
    #expect(quote.text == text)
    #expect(!quote.isTruncated)
  }

  @Test("trailing whitespace on a kept line is trimmed, and interior spacing is left alone")
  func trimsEnds() throws {
    let quote = try #require(QuotedMessage(quoting: "  Proceed with  the migration?   "))
    #expect(quote.text == "Proceed with  the migration?")
  }
}

@Suite("WaitedFor")
struct WaitedForTests {
  @Test(
    "an age is said the way a row has room for",
    arguments: [
      (0.0, "now"),
      (1.0, "now"),
      (59.0, "now"),
      (60.0, "1m"),
      (299.0, "4m"),
      (3599.0, "59m"),
      (3600.0, "1h"),
      (86_399.0, "23h"),
      (86_400.0, "1d"),
      (86_400.0 * 9, "9d"),
    ]
  )
  func shortForm(seconds: TimeInterval, expected: String) {
    #expect(WaitedFor.short(seconds) == expected)
  }

  @Test(
    "and said in words for a screen reader, because `4m` is not a word",
    arguments: [
      (0.0, "just now"),
      (60.0, "1 minute"),
      (299.0, "4 minutes"),
      (3600.0, "1 hour"),
      (7200.0, "2 hours"),
      (86_400.0, "1 day"),
      (86_400.0 * 3, "3 days"),
    ]
  )
  func spokenForm(seconds: TimeInterval, expected: String) {
    #expect(WaitedFor.spoken(seconds) == expected)
  }

  @Test("a clock that disagrees cannot produce a wait in the future")
  func negativeIsClamped() {
    // The record's timestamp is the host's clock and the age is taken on the phone's.
    #expect(WaitedFor.short(-90) == "now")
    #expect(WaitedFor.spoken(-90) == "just now")
  }

  @Test("an age is measured between two dates rather than against the system clock")
  func between() {
    #expect(WaitedFor.short(since: noon.addingTimeInterval(-300), asOf: noon) == "5m")
    #expect(WaitedFor.short(since: noon, asOf: noon) == "now")
  }
}

@Suite("BlockedPaneRow")
struct BlockedPaneRowTests {
  @Test("the meta line names the agent, where it is, and how long it has waited")
  func fullMetaLine() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: noon.addingTimeInterval(-240),
      asOf: noon
    )
    #expect(row.meta == "Claude · driverr › app · 4m")
  }

  @Test("a part with nothing to say is left out rather than filled in")
  func metaLineDropsWhatItDoesNotKnow() {
    // herdr can report a pane whose tab Driverr cannot resolve, and a pane with no readable
    // transcript has no age.
    let noLocation = BlockedPaneRow(
      pane: blockedPane(),
      location: nil,
      lastMessage: nil,
      quietSince: noon.addingTimeInterval(-240),
      asOf: noon
    )
    #expect(noLocation.meta == "Claude · 4m")

    let noAge = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: nil,
      asOf: noon
    )
    #expect(noAge.meta == "Claude · driverr › app")

    let neither = BlockedPaneRow(
      pane: blockedPane(),
      location: nil,
      lastMessage: nil,
      quietSince: nil,
      asOf: noon
    )
    #expect(neither.meta == "Claude")
  }

  @Test("a pane with no recoverable message carries no quote")
  func noQuote() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: nil,
      asOf: noon
    )
    #expect(row.quote == nil)
  }

  @Test("the quote is the agent's last message, bounded")
  func quotesTheLastMessage() throws {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: "Two panes claim focus after a close.\nWhich should win?\nThird line.",
      quietSince: nil,
      asOf: noon
    )
    let quote = try #require(row.quote)
    #expect(quote.text == "Two panes claim focus after a close.\nWhich should win?")
    #expect(quote.isTruncated)
  }

  @Test("a screen reader hears the state, the place and the wait in words")
  func spokenLabel() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: "Proceed with the migration?",
      quietSince: noon.addingTimeInterval(-240),
      asOf: noon
    )
    // `4m` is not a word, so it is not spoken as one. The age is time since the transcript
    // was last written, not time spent waiting.
    #expect(
      row.metaAccessibilityLabel
        == "Claude, waiting for you in driverr › app. Last wrote 4 minutes ago."
    )
    #expect(row.quoteAccessibilityLabel == "Claude's last message: Proceed with the migration?")
  }

  @Test("under a minute is 'just now', not 'just now ago'")
  func spokenLabelJustNow() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: nil,
      lastMessage: nil,
      quietSince: noon,
      asOf: noon
    )
    #expect(row.metaAccessibilityLabel == "Claude, waiting for you. Last wrote just now.")
  }

  @Test("no age at all leaves the sentence without a second half")
  func spokenLabelWithNoAge() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: nil,
      asOf: noon
    )
    #expect(row.metaAccessibilityLabel == "Claude, waiting for you in driverr › app.")
  }

  /// Codex transcripts have no age, so `blockedSince`, recorded on the client, fills in.
  @Test("blockedSince fills the age in when the transcript gives no quietSince")
  func blockedSinceFallsBackWhenQuietSinceIsNil() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: nil,
      blockedSince: noon.addingTimeInterval(-240),
      asOf: noon
    )
    #expect(row.meta == "Claude · driverr › app · 4m")
    #expect(
      row.metaAccessibilityLabel
        == "Claude, waiting for you in driverr › app. Last wrote 4 minutes ago."
    )
  }

  /// The transcript says when the agent stopped writing, which is more precise.
  @Test("quietSince wins over blockedSince when both are available")
  func quietSinceWinsOverBlockedSince() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: nil,
      lastMessage: nil,
      quietSince: noon.addingTimeInterval(-60),
      blockedSince: noon.addingTimeInterval(-3600),
      asOf: noon
    )
    #expect(row.meta == "Claude · 1m")
  }

  @Test("a truncated quote says so out loud instead of ending mid-sentence")
  func spokenTruncation() {
    let row = BlockedPaneRow(
      pane: blockedPane(),
      location: nil,
      lastMessage: "One.\nTwo.\nThree.",
      quietSince: nil,
      asOf: noon
    )
    #expect(row.quoteAccessibilityLabel == "Claude's last message, shortened: One. Two.")
  }

  @Test("a blocked pane herdr reported without an agent name still renders")
  func noAgent() {
    // Only an agent can be blocked, but `Pane.agent` is optional and the row must not crash.
    let row = BlockedPaneRow(
      pane: blockedPane(agent: nil),
      location: "driverr › app",
      lastMessage: nil,
      quietSince: nil,
      asOf: noon
    )
    #expect(row.meta == "driverr › app")
    #expect(row.metaAccessibilityLabel == "Waiting for you in driverr › app.")
  }
}

/// A pane whose transcript ends on a failed API request shows the stop, not a quote.
@Suite("BlockedPaneRow, stopped")
struct BlockedPaneRowStopTests {
  private static let chicago = TimeZone(identifier: "America/Chicago")!
  private static let enUS = Locale(identifier: "en_US")

  /// 22:40 UTC, 5:40 PM in Chicago.
  private static let resetsAt = Date(timeIntervalSince1970: 1_790_548_800)

  private static let limit = AgentStop(
    kind: .rateLimit, resetsAt: resetsAt,
    message: "You've hit your session limit · resets 5:40pm (America/Chicago)",
    at: resetsAt.addingTimeInterval(-3_900))

  /// `Date.FormatStyle` puts a narrow no-break space before the day period in `en_US`.
  private static func time(_ clock: String) -> String {
    clock.replacingOccurrences(of: " ", with: "\u{202F}")
  }

  private static func row(
    _ stop: AgentStop?, lastMessage: String? = nil, quietSince: Date? = nil,
    secondsBeforeReset: TimeInterval
  ) -> BlockedPaneRow {
    BlockedPaneRow(
      pane: blockedPane(),
      location: "driverr › app",
      lastMessage: lastMessage,
      quietSince: quietSince,
      stop: stop,
      asOf: resetsAt.addingTimeInterval(-secondsBeforeReset),
      timeZone: chicago,
      locale: enUS
    )
  }

  @Test("a live limit shows the stop in the injected zone instead of the record's text")
  func liveLimit() throws {
    // Not the record's verbatim text, which carries the host's zone.
    let row = Self.row(
      Self.limit, lastMessage: Self.limit.message, secondsBeforeReset: 3_600)
    #expect(row.quote == nil)
    let notice = try #require(row.stopNotice)
    #expect(notice.title == "Usage limit reached")
    #expect(!notice.isStale)
    #expect(row.stopDetail?.text == "Resets at \(Self.time("5:40 PM")).")
  }

  @Test("a limit whose reset has passed says it reset")
  func staleLimit() throws {
    let row = Self.row(Self.limit, lastMessage: Self.limit.message, secondsBeforeReset: -60)
    let notice = try #require(row.stopNotice)
    #expect(notice.title == "Usage limit reset")
    #expect(notice.isStale)
    #expect(row.stopDetail?.text == "It reset at \(Self.time("5:40 PM")).")
    #expect(row.quote == nil)
  }

  @Test("a server error's long detail is bounded like a quote")
  func longServerError() throws {
    // Real server-error details run to hundreds of characters on one line.
    let message =
      "API Error: Can't reach the API server. "
      + String(repeating: "The proxy returned an upstream error and closed the stream. ", count: 8)
    #expect(message.count > 400)
    let stop = AgentStop(kind: .serverError, message: message)
    let row = Self.row(stop, lastMessage: message, secondsBeforeReset: 0)
    #expect(row.quote == nil)
    #expect(row.stopNotice?.title == "API request failed")
    let detail = try #require(row.stopDetail)
    #expect(detail.isTruncated)
    #expect(detail.text.count <= QuotedMessage.characterLimit + 1)
    #expect(detail.text.hasPrefix("API Error: Can't reach the API server."))
    #expect(
      row.stopAccessibilityLabel == "API request failed. Shortened: \(detail.text)")
  }

  @Test("a screen reader hears that the agent stopped, not that it is waiting for you")
  func spokenLabel() {
    let row = Self.row(
      Self.limit, lastMessage: Self.limit.message, quietSince: Self.limit.at,
      secondsBeforeReset: 3_600)
    #expect(
      row.metaAccessibilityLabel == "Claude, stopped in driverr › app. Last wrote 5 minutes ago."
    )
    #expect(
      row.stopAccessibilityLabel == "Usage limit reached. Resets at \(Self.time("5:40 PM")).")
  }

  @Test("once a limit has reset, a screen reader hears that, not that the agent stopped")
  func spokenLabelAfterReset() {
    let row = Self.row(
      Self.limit, lastMessage: Self.limit.message, quietSince: Self.limit.at,
      secondsBeforeReset: -60)
    #expect(
      row.metaAccessibilityLabel
        == "Claude, usage limit reset in driverr › app. Last wrote 1 hour ago."
    )
    #expect(row.stopGlyphAccessibilityLabel == "Usage limit reset")
    #expect(Self.row(Self.limit, secondsBeforeReset: 60).stopGlyphAccessibilityLabel == "Stopped")
  }

  @Test("a row with no stop is unchanged")
  func noStop() {
    let row = Self.row(
      nil, lastMessage: "Proceed with the migration?",
      quietSince: Self.resetsAt.addingTimeInterval(-3_840), secondsBeforeReset: 3_600)
    #expect(row.stopNotice == nil)
    #expect(row.stopDetail == nil)
    #expect(row.stopAccessibilityLabel == nil)
    #expect(row.stopGlyphAccessibilityLabel == nil)
    #expect(row.quote?.text == "Proceed with the migration?")
    #expect(
      row.metaAccessibilityLabel
        == "Claude, waiting for you in driverr › app. Last wrote 4 minutes ago."
    )
  }
}

@Suite("Transcript.lastActivity")
struct TranscriptLastActivityTests {
  private func page(_ turns: [TranscriptTurn]) -> Transcript {
    Transcript(turns: turns, window: .none)
  }

  @Test("a page with nothing in it has no last activity")
  func empty() {
    #expect(Transcript.empty.lastActivity == nil)
  }

  @Test("the newest turn's timestamp is when the conversation went quiet")
  func newestTurn() {
    let transcript = page([
      TranscriptTurn(id: "1", speech: .human("go"), at: noon.addingTimeInterval(-600)),
      TranscriptTurn(id: "2", speech: .assistant("asking"), at: noon.addingTimeInterval(-300)),
    ])
    #expect(transcript.lastActivity == noon.addingTimeInterval(-300))
  }

  @Test("a tail record that carried no timestamp does not erase an age the page has")
  func undatedTail() {
    // `TranscriptTurn.at` is `nil` when a record did not say, so `turns.last?.at` alone would
    // lose an age two rows up.
    let transcript = page([
      TranscriptTurn(id: "1", speech: .assistant("asking"), at: noon.addingTimeInterval(-300)),
      TranscriptTurn(id: "2", speech: .tools(ToolRun(calls: [ToolCall(name: "Bash")])), at: nil),
    ])
    #expect(transcript.lastActivity == noon.addingTimeInterval(-300))
  }

  @Test("a page whose records all lack timestamps has no age, rather than a made-up one")
  func noTimestampsAtAll() {
    #expect(page([TranscriptTurn(id: "1", speech: .assistant("hi"))]).lastActivity == nil)
  }
}

@Suite("NeedsYouSection")
struct NeedsYouSectionTests {
  @Test("the header states the count")
  func headerCount() {
    #expect(NeedsYouSection.title(count: 3) == "Needs You · 3")
    #expect(NeedsYouSection.title(count: 1) == "Needs You · 1")
  }

  @Test("and says what the count is a count of, in words, for a screen reader")
  func spokenHeader() {
    // "Needs you, 3" leaves a VoiceOver user guessing three of what. It does not say "waiting",
    // because a pane stopped on a limit is listed here too.
    #expect(NeedsYouSection.spokenTitle(count: 1) == "1 pane needs you.")
    #expect(NeedsYouSection.spokenTitle(count: 3) == "3 panes need you.")
  }
}

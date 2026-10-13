import Foundation
import Testing

@testable import DriverrCore

/// Whether a scrolled-back screen reader is told the agent started. A reader who can see
/// the row is not told, a row leaving or rewording is not an arrival, and a send verdict is
/// `PaneComposerBar`'s to announce. XCUITest cannot see an announcement, so this is the
/// test tier for it.
@Suite("What a scrolled-back reader is told about the foot of the chat")
struct ChatActivityAnnouncementTests {
  private let working = ChatActivity(
    message: "Claude is working.",
    detail: nil,
    tone: .progress,
    offersRetry: false
  )

  private let failed = ChatActivity(
    message: "Reply failed.",
    detail: "Connection lost.",
    tone: .failure,
    offersRetry: true,
    isVerdict: true
  )

  private let answering = ChatActivity(
    message: "0 of 2 answered",
    detail: nil,
    tone: .prompt,
    offersRetry: false
  )

  // MARK: - The one case that speaks

  /// Up in the history the cell is not realised, so nothing on screen or in the tree says the
  /// agent resumed.
  @Test("The working row arriving is announced to a reader who has scrolled back")
  func theWorkingRowIsAnnouncedToAReaderWhoCannotSeeIt() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: working, isScrolledBack: true) == "Claude is working."
    )
  }

  /// `accessibilityLabel` joins with ". ", so the fixture's message has no full stop of its
  /// own, or it reads "working.. Running". Only the working branch of
  /// `ChatActivity.init(header:status:)` reaches this path, and it passes `detail: nil`.
  @Test("The announcement is the row's own accessibility label, headline and cause")
  func theAnnouncementIsTheRowsOwnLabel() {
    let detailed = ChatActivity(
      message: "Claude is working",
      detail: "Running the tests.",
      tone: .progress,
      offersRetry: false
    )
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: detailed, isScrolledBack: true)
        == "Claude is working. Running the tests."
    )
  }

  /// A part-answered question set is not a verdict.
  @Test("A question set waiting on an answer is announced on the same terms")
  func thePromptRowIsAnnouncedToo() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: answering, isScrolledBack: true) == "0 of 2 answered"
    )
  }

  // MARK: - Rule 1: only a reader who cannot see the row

  /// The row is already on screen and in their tree.
  @Test("A reader at the end of the conversation is told nothing")
  func aFollowerIsNotAnnouncedTo() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: working, isScrolledBack: false) == nil
    )
  }

  // MARK: - Rule 2: arrival only

  @Test("The row leaving is not announced")
  func theRowLeavingIsSilent() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: working, current: nil, isScrolledBack: true) == nil
    )
  }

  /// `PaneComposerStatus.message` counts up on a clock, so keying on the wording would
  /// re-announce the row every tick. This keys on arrival, as `PaneComposerBar` keys on phase.
  @Test("A row that was already there and changed its wording is not an arrival")
  func aChangedMessageIsNotAnArrival() {
    let later = ChatActivity(
      message: "Claude is working on the tests.",
      detail: nil,
      tone: .progress,
      offersRetry: false
    )
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: working, current: later, isScrolledBack: true) == nil
    )
  }

  @Test("No row before and no row after is nothing to say")
  func silenceIsSilence() {
    #expect(
      ChatActivityAnnouncement.onArrival(previous: nil, current: nil, isScrolledBack: true) == nil
    )
  }

  // MARK: - Rule 3: a send verdict is somebody else's announcement

  /// `PaneComposerBar` announces verdicts to every reader on the send's phase change.
  @Test("A send verdict is not announced here, because the composer already announces it")
  func aVerdictIsLeftToTheComposer() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: failed, isScrolledBack: true) == nil
    )
  }

  /// The verdict is the row that left, so this is an arrival.
  @Test("The working row arriving after a verdict has cleared is still an arrival")
  func aWorkingRowAfterAClearedVerdictIsAnArrival() {
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: nil, current: working, isScrolledBack: true) == "Claude is working."
    )
    // Verdict to working is not one: the row never left.
    #expect(
      ChatActivityAnnouncement.onArrival(
        previous: failed, current: working, isScrolledBack: true) == nil
    )
  }
}

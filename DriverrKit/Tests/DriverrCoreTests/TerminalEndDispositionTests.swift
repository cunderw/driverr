import Testing

@testable import DriverrCore

@Suite("Reading why a bridge session ended")
struct TerminalEndDispositionTests {
  private func disposition(
    _ reason: TerminalCloseReason,
    stated: Bool = false,
    inTree: Bool = true,
    attempts: Int = 0
  ) -> TerminalEndDisposition {
    TerminalEndDisposition.forSessionThatEnded(
      reason: reason,
      statedByHerdr: stated,
      paneIsStillInTree: inTree,
      reattachAttempts: attempts
    )
  }

  private let gaveUp = TerminalEndDisposition.failed(
    message: TerminalEndDisposition.reattachFailedMessage
  )
  private let herdrStopped = TerminalEndDisposition.failed(
    message: TerminalEndDisposition.serverStoppedMessage
  )

  // MARK: - The defect

  @Test("a stream that ended with no record reattaches rather than reporting a close")
  func aBareEndReattaches() {
    #expect(disposition(.streamEnded) == .reattach)
  }

  @Test("herdr's own close is still a close")
  func herdrsOwnWordIsBelieved() {
    #expect(disposition(.paneClosed, stated: true) == .closed)
    #expect(disposition(.paneClosed, stated: true, inTree: false) == .closed)
  }

  /// herdr's `paneClosed` finishes the stream cleanly, and the scene labels that
  /// `.streamEnded`. Read off the label alone, an ordinary close reattached and the closed
  /// banner never appeared.
  @Test("a close herdr stated is a close even when it arrives labelled .streamEnded")
  func aStatedCloseWinsOverItsLabel() {
    #expect(disposition(.streamEnded, stated: true) == .closed)
    #expect(disposition(.streamEnded, stated: true, attempts: 3) == .closed)
  }

  // MARK: - The two ends herdr states that are not a pane closing

  // herdr's wording is mapped to `.detached` and `.serverShuttingDown` in `DriverrHerdr`,
  // so this tier never sees the strings.

  @Test("a herdr that says it is shutting down is not a pane that closed")
  func aShutdownIsNeverAClose() {
    #expect(disposition(.serverShuttingDown, stated: true) == herdrStopped)
    // It always arrives stated, but the answer must not depend on that.
    #expect(disposition(.serverShuttingDown) == herdrStopped)
  }

  @Test("a shutdown does not reattach, however few attempts have been spent")
  func aShutdownNeverReattaches() {
    // Nothing is there to reattach to until herdr is back.
    for attempts in 0...3 {
      #expect(disposition(.serverShuttingDown, stated: true, attempts: attempts) != .reattach)
    }
    // Nor is it a close when herdr's snapshot has gone with herdr.
    #expect(disposition(.serverShuttingDown, stated: true, inTree: false) != .closed)
  }

  /// herdr tore our client down for a reason of its own, and the pane is still running. The
  /// scene's own hand-back never arrives here: `controllerFeed` and `observerFeed` drop an
  /// end the scene caused on `Task.isCancelled`.
  @Test("an unsolicited detached reattaches rather than reporting a close")
  func aDetachedReattaches() {
    #expect(disposition(.detached, stated: true) == .reattach)
  }

  @Test("a second detached with no frame between gives up, and still never says closed")
  func aSecondDetachedFails() {
    #expect(disposition(.detached, stated: true, attempts: 1) == gaveUp)
    for attempts in 1...5 {
      #expect(disposition(.detached, stated: true, attempts: attempts) != .closed)
    }
  }

  @Test("a detached on a pane that has left herdr's tree is a close after all")
  func aDetachedOnAVanishedPaneIsAClose() {
    #expect(disposition(.detached, stated: true, inTree: false) == .closed)
  }

  /// A reason this build has never seen is safer over-reported as a close than reattached.
  @Test("an unrecognised herdr reason still reads as a close")
  func anUnknownReasonIsStillAClose() {
    #expect(disposition(.other("terminal session stopped"), stated: true) == .closed)
    #expect(disposition(.other("something a later herdr says")) == .closed)
  }

  // MARK: - herdr's snapshot is herdr's word

  @Test("a bare end on a pane that has left the tree is a close after all")
  func aBareEndOnAVanishedPaneIsAClose() {
    #expect(disposition(.streamEnded, inTree: false) == .closed)
  }

  // MARK: - The bound

  @Test("a second bare end with no frame between gives up and says so")
  func theSecondBareEndFails() {
    #expect(disposition(.streamEnded, attempts: 1) == gaveUp)
    #expect(disposition(.streamEnded, attempts: 2) == gaveUp)
  }

  @Test("giving up never reports the pane as closed")
  func givingUpIsNotAClose() {
    // The bound must not turn into reporting a close one attempt later.
    for attempts in 1...5 {
      #expect(disposition(.streamEnded, attempts: attempts) != .closed)
    }
  }

  @Test("the sentence Driverr shows when it gives up says only what it knows")
  func theFailureSentenceClaimsNothingAboutTheCause() {
    let message = TerminalEndDisposition.reattachFailedMessage
    #expect(message.contains("closed") == false)
    // The reader cannot act on the reattach, so it is not named.
    #expect(message.lowercased().contains("reattach") == false)
    // The length of the notices beside it, which keeps the phone's bar to one line.
    #expect((18...41).contains(message.count), "measured \(message.count) characters")
  }

  /// It may name herdr because herdr stated the cause. It must not say the pane closed.
  @Test("the sentence for a herdr that stopped names herdr and not a close")
  func theShutdownSentenceNamesTheServerRatherThanThePane() {
    let message = TerminalEndDisposition.serverStoppedMessage
    #expect(message.contains("closed") == false)
    #expect(message.lowercased().contains("pane") == false)
    #expect(message.lowercased().contains("herdr"))
    #expect((18...41).contains(message.count), "measured \(message.count) characters")
    #expect(message != TerminalEndDisposition.reattachFailedMessage)
  }

  // MARK: - A process that ran and refused

  @Test("a bridge process that failed says why, in herdr's own words, attributed to herdr")
  func aFailedProcessCarriesHerdrsMessage() {
    #expect(
      disposition(.processFailed(status: 1, message: "pane w1:p9 not found"))
        == .failed(message: "herdr said: pane w1:p9 not found")
    )
  }

  /// herdr writes fragments: no capital, no full stop, sometimes a bare identifier. The
  /// lead-in lets them ship unedited.
  @Test("the far side's words are quoted, never edited into Driverr's own voice")
  func theRemoteMessageIsQuotedRatherThanRewritten() {
    let answer = disposition(.processFailed(status: 1, message: "pane w1:p9 not found"))
    guard case .failed(let message) = answer else {
      Issue.record("expected .failed, got \(answer)")
      return
    }
    #expect(message.hasPrefix(TerminalEndDisposition.remoteMessageLeadIn))
    #expect(
      message.hasSuffix("pane w1:p9 not found"),
      "herdr's own characters, in herdr's own order, with nothing added to the end"
    )
  }

  @Test("a bridge process that failed silently gets the fixed sentence")
  func aSilentFailureGetsTheFixedSentence() {
    let fixed = TerminalEndDisposition.failed(message: TerminalEndDisposition.paneFailedMessage)
    #expect(disposition(.processFailed(status: 127, message: nil)) == fixed)
    #expect(disposition(.processFailed(status: 1, message: "")) == fixed)
    #expect(disposition(.processFailed(status: 1, message: "   \n ")) == fixed)
  }

  /// A process that exited nonzero decides the same way again, so a reattach would loop.
  /// Retry is the reader's.
  @Test("a bridge process that failed never reattaches, whatever else is true")
  func aFailedProcessNeverReattaches() {
    for inTree in [true, false] {
      for attempts in 0...2 {
        for stated in [true, false] {
          let answer = disposition(
            .processFailed(status: 1, message: "pane w1:p9 not found"),
            stated: stated,
            inTree: inTree,
            attempts: attempts
          )
          #expect(
            answer == .failed(message: "herdr said: pane w1:p9 not found"),
            "inTree \(inTree), attempts \(attempts), stated \(stated)"
          )
        }
      }
    }
  }

  /// The far side's message is the one string here Driverr did not write, so the bound sits
  /// where it becomes a notice.
  @Test("a message from the far side is truncated rather than allowed to fill the screen")
  func aLongMessageIsBounded() {
    let long = String(repeating: "x", count: 400)
    let answer = disposition(.processFailed(status: 1, message: long))
    guard case .failed(let message) = answer else {
      Issue.record("expected .failed, got \(answer)")
      return
    }
    #expect(message.count == TerminalEndDisposition.messageLimit)
    #expect(message.hasSuffix("\u{2026}"), "the truncation is visible rather than silent")
  }

  /// The budget is the finished line, lead-in included.
  @Test("a message that just fits, lead-in included, keeps every character and no ellipsis")
  func aMessageAtTheLimitIsUntouched() {
    let leadIn = TerminalEndDisposition.remoteMessageLeadIn
    let exact = String(
      repeating: "y",
      count: TerminalEndDisposition.messageLimit - leadIn.count
    )
    let answer = disposition(.processFailed(status: 1, message: exact))
    #expect(answer == .failed(message: leadIn + exact))
    guard case .failed(let message) = answer else { return }
    #expect(message.count == TerminalEndDisposition.messageLimit)
    #expect(message.hasSuffix("\u{2026}") == false)
  }

  @Test("a message from the far side is trimmed before it is shown")
  func aMessageIsTrimmed() {
    #expect(
      disposition(.processFailed(status: 1, message: "  pane not found \n"))
        == .failed(message: "herdr said: pane not found")
    )
  }

  /// A bridge process exiting says nothing about the terminal behind it.
  @Test("the sentence for a failed process names the attach and not a close")
  func theFailedSentenceNamesTheAttachRatherThanThePane() {
    let message = TerminalEndDisposition.paneFailedMessage
    #expect(message.contains("closed") == false)
    #expect(message.lowercased().contains("herdr"))
    #expect((18...41).contains(message.count), "measured \(message.count) characters")
    #expect(message != TerminalEndDisposition.reattachFailedMessage)
    #expect(message != TerminalEndDisposition.serverStoppedMessage)
  }

  // MARK: - Totality

  @Test("the two banners the scene owns are never answered with a silent reattach")
  func aRefusalIsNeverSilent() {
    #expect(disposition(.refused) == .closed)
    #expect(disposition(.takenOver) == .closed)
  }
}

import Foundation
import Testing

@testable import DriverrCore

/// Where the chat rests while a question waits.
@Suite("ChatReplyAnchor")
struct ChatReplyAnchorTests {
  /// The transcript's tool card replaces the screen band's heading, and the chips must not
  /// move.
  @Test("headroom keeps the chips where the screen band put them")
  func headroomKeepsTheChips() {
    #expect(ChatReplyAnchor.headroom(screenBandTop: 58, bandTop: 1) == 57)
    #expect(ChatReplyAnchor.headroom(screenBandTop: nil, bandTop: 1) == 0)
    #expect(ChatReplyAnchor.headroom(screenBandTop: 1, bandTop: 58) == 0)
    let rest = ChatReplyAnchor.restingOffset(
      endOffset: 2000, replyTop: 1000, insetTop: 0, headroom: 57)
    #expect(rest == 1000 - ChatReplyAnchor.lead - 57)
  }

  @Test("with no chips the chat rests at the end")
  func noChipsRestsAtTheEnd() {
    #expect(ChatReplyAnchor.restingOffset(endOffset: 900, replyTop: nil, insetTop: 0) == 900)
  }

  @Test("a band taller than the chat rests with its top in view")
  func aTallBandRestsAtItsTop() {
    #expect(
      ChatReplyAnchor.restingOffset(endOffset: 900, replyTop: 600, insetTop: 0)
        == 600 - ChatReplyAnchor.lead)
  }

  @Test("a band that fits rests at the end")
  func aShortBandRestsAtTheEnd() {
    #expect(ChatReplyAnchor.restingOffset(endOffset: 500, replyTop: 800, insetTop: 0) == 500)
  }

  @Test("the rest never goes above the content's top")
  func theRestIsClampedAtTheTop() {
    #expect(ChatReplyAnchor.restingOffset(endOffset: 900, replyTop: 2, insetTop: 5) == -5)
  }

  @Test("above the rest the distance is the gap")
  func aboveTheRestIsTheGap() {
    #expect(ChatReplyAnchor.distanceFromRest(restingOffset: 600, contentOffsetY: 600) == 0)
    #expect(ChatReplyAnchor.distanceFromRest(restingOffset: 600, contentOffsetY: 450) == 150)
  }

  /// What is below the rest can be shorter than the follow tolerance, so a reader there would
  /// be settled back onto the band.
  @Test("below the rest by any real amount the reader has moved on")
  func belowTheRestHasMovedOn() {
    #expect(ChatReplyAnchor.distanceFromRest(restingOffset: 600, contentOffsetY: 600.4) == 0)
    #expect(
      ChatReplyAnchor.distanceFromRest(restingOffset: 600, contentOffsetY: 620)
        > ChatEndProximity.jumpTolerance)
  }

  /// Anchored on a band that has left, the reader would stop following until the next drag.
  @Test("a reader anchored on the band follows the reply once the band leaves")
  func aReaderOnTheBandFollowsTheReply() {
    let onTheBand = ChatReaderPlace.reading(anchorItemID: "reply:t9", offsetWithinItem: 120)
    #expect(ChatReplyAnchor.place(onTheBand, whenReplyLeaves: "reply:t9") == .followingLatest)
  }

  @Test("a reader anchored anywhere else keeps their place")
  func aReaderElsewhereKeepsTheirPlace() {
    let elsewhere = ChatReaderPlace.reading(anchorItemID: "t3", offsetWithinItem: 40)
    #expect(ChatReplyAnchor.place(elsewhere, whenReplyLeaves: "reply:t9") == elsewhere)
    #expect(
      ChatReplyAnchor.place(.followingLatest, whenReplyLeaves: "reply:t9") == .followingLatest)
  }
}

/// What the composer does with Reply's request for the keyboard.
@Suite("ComposerFocusGate")
struct ComposerFocusGateTests {
  private let question = ToolCall(
    name: "AskUserQuestion",
    outcome: .pending,
    questions: [PendingQuestion(question: "Which?", options: ["A", "B"])]
  )

  @Test("the request waits until the chat has read the session")
  func waitsForTheRead() {
    #expect(ComposerFocusGate(isSettled: false, pendingCall: nil) == .wait)
    #expect(ComposerFocusGate(isSettled: false, pendingCall: question) == .wait)
  }

  @Test("a pane asking its own question keeps the keyboard down")
  func aQuestionDeclines() {
    #expect(ComposerFocusGate(isSettled: true, pendingCall: question) == .decline)
  }

  /// A permission prompt's pair is short, and Reply there is for typing.
  @Test("nothing asking, or a call with no questions of its own, takes the keyboard")
  func otherwiseAllows() {
    #expect(ComposerFocusGate(isSettled: true, pendingCall: nil) == .allow)
    #expect(
      ComposerFocusGate(isSettled: true, pendingCall: ToolCall(name: "Bash", outcome: .pending))
        == .allow)
  }

  /// A tenth option has no digit, so the call gets no chips.
  @Test("a question with no chips takes the keyboard")
  func aQuestionWithNoChipsAllows() {
    let ten = ToolCall(
      name: "AskUserQuestion", outcome: .pending,
      questions: [PendingQuestion(question: "Which?", options: (1...10).map { "o\($0)" })])
    #expect(ComposerFocusGate(isSettled: true, pendingCall: ten) == .allow)
  }
}

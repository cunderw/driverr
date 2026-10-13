import DriverrCore
import DriverrHerdr
import Foundation
import Testing
import UIKit

@testable import Driverr

/// A `HerdrControl` whose steering commands never come back.
///
/// A channel that has stalled rather than failed, which `FakeControl` cannot model. Everything
/// else answers, so only the send hangs.
///
/// Suspends on a continuation, so it blocks no cooperative thread; see `CLAUDE.md`.
actor HangingControl: HerdrControl {
  private var resume: (@Sendable () -> Void)?

  nonisolated var binaryPath: String { "herdr" }
  func snapshot() async throws -> SessionTree { .empty }
  nonisolated func attachCommand(for pane: Pane) -> String { "herdr terminal attach t" }
  func availability() async -> HerdrAvailability {
    .ready(version: "0.8.2", protocolVersion: HerdrProtocol.lastVerified)
  }
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen { .blank }
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}

  func sendText(paneID: String, text: String) async throws { await hang() }
  func submitText(paneID: String, text: String) async throws { await hang() }
  func sendKeys(paneID: String, keys: [PaneKey]) async throws { await hang() }

  private func hang() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      resume = { continuation.resume() }
    }
  }

  /// Lets the parked send finish, so a test leaves no task suspended behind it.
  func release() {
    resume?()
    resume = nil
  }
}

/// Answering a pane, with no host and no terminal.
///
/// The state transitions are `PaneComposerState`'s, tested in `swift test`. This covers what
/// needs an actor and a clock: what goes over the wire, to which pane, what a retry repeats,
/// what a stalled send does, and what the composer tells the connection once a reply lands.
@MainActor
@Suite("PaneComposerModel")
struct PaneComposerModelTests {
  private let pane = Pane(
    id: "w1:p2",
    tabID: "w1:t1",
    workspaceID: "w1",
    title: "needs a decision",
    agent: Agent(name: "Claude", kind: "claude", status: .blocked),
    terminalID: "term_w1p2"
  )

  private func composer(
    _ control: (any HerdrControl)?,
    pane: Pane? = nil,
    makeUpload: @escaping @MainActor (Data, String) -> (any ImageUploading)? = { _, _ in nil },
    onSent: @escaping @MainActor (String, PaneComposerState.Attempt) -> Void = { _, _ in },
    sendDeadline: Duration = .seconds(12),
    now: @escaping @MainActor () -> Date = Date.init
  ) -> PaneComposerModel {
    PaneComposerModel(
      pane: pane ?? self.pane,
      control: { control },
      makeUpload: makeUpload,
      onSent: onSent,
      sendDeadline: sendDeadline,
      // Fast, and it decides nothing: the notice is retired by evidence.
      ageTick: .milliseconds(5),
      now: now
    )
  }

  // MARK: - The bytes that go over

  /// Measured against herdr 0.8.2 and Claude Code v2.1.248, with a raw-mode reader on a pane's
  /// tty:
  ///
  /// | called as | bytes delivered |
  /// | --- | --- |
  /// | `pane send-text <p> "yes\n"` | `79 65 73 0a` — `yes` + **LF** |
  /// | `pane send-keys <p> enter` | `0d` — **CR** |
  /// | `pane run <p> "yes"` | `79 65 73 0d` — `yes` + **CR** |
  ///
  /// To the live agent a bare LF is a line break, and does nothing on an arrow menu. CR
  /// submits. `sendText(text + "\n")` leaves the reply unsent in the input box.
  @Test("a reply is submitted, not typed and left sitting in the agent's input box")
  func submitsRatherThanTyping() async {
    let control = FakeControl()
    let model = composer(control)
    model.text = "yes, go ahead"

    await model.send()

    #expect(await control.sent == [.submit(paneID: "w1:p2", text: "yes, go ahead")])
    #expect(model.state.phase == .sent)
  }

  /// `pane run "q\n"` delivers `71 0a 0d`: the reply's own newline, then the submit, so a
  /// stray blank line.
  @Test("a trailing newline is trimmed rather than sent ahead of the submit")
  func trailingNewlineIsTrimmed() async {
    let control = FakeControl()
    let model = composer(control)
    model.text = "yes\n"

    await model.send()

    #expect(await control.sent == [.submit(paneID: "w1:p2", text: "yes")])
  }

  /// The other half of the rule: an interior newline is a line break somebody typed. It
  /// crosses as LF, Claude Code renders it as one, and the single CR at the end submits the
  /// whole message — so a multi-line reply must arrive whole rather than as two sends.
  @Test("an interior newline survives, so a two-line reply is one message")
  func interiorNewlineSurvives() async {
    let control = FakeControl()
    let model = composer(control)
    model.text = "first line\nsecond line"

    await model.send()

    #expect(await control.sent == [.submit(paneID: "w1:p2", text: "first line\nsecond line")])
  }

  @Test("herdr taking the reply is not reported as the agent answering it")
  func sentSaysWhatItMeans() async {
    let model = composer(FakeControl())
    model.text = "y"

    await model.send()

    #expect(model.status?.message == "Sent · waiting for the agent")
  }

  @Test("nothing to send is a disabled button, not an error")
  func blankIsNotSent() async {
    let control = FakeControl()
    let model = composer(control)
    model.text = "   \n  "

    #expect(!model.canSend)
    await model.send()

    #expect(await control.sent.isEmpty)
    #expect(model.state.phase == .editing)
  }

  // MARK: - Several questions in one call

  /// Driven through the pieces the screen uses: the notice a blocked `AskUserQuestion`
  /// produces, the selection a tap records, and the composer that puts the answer on the wire.
  ///
  /// Two of three answered sends nothing. The rule is `ReplyChipSelection`'s; this adds that
  /// nothing reaches the control until it says so.
  @Test("nothing is sent until every question in the call has an answer")
  func multiQuestionSendsOnlyWhenComplete() async throws {
    let control = FakeControl()
    let model = composer(control)
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(question: "Which branch?", options: ["main", "release"]),
        PendingQuestion(question: "Run the tests?", options: ["Yes", "No"]),
        PendingQuestion(question: "Who reviews it?", options: ["Ann", "Bo"], allowsMultiple: true),
      ]
    )
    let groups = call.pendingNotice(agentStatus: .blocked).groups
    try #require(groups.count == 3)
    var selection = ReplyChipSelection(groups: groups)

    selection.toggle(groups[0].chips[1], in: groups[0])
    selection.toggle(groups[1].chips[0], in: groups[1])
    if let early = selection.reply { await model.send(early) }

    #expect(await control.sent.isEmpty)

    // The completing tap on a multi-select question sends nothing, or the answer would be
    // truncated at whichever chip completed the call.
    selection.toggle(groups[2].chips[0], in: groups[2])
    #expect(selection.isComplete)
    if let onCompletion = selection.reply { await model.send(onCompletion) }
    #expect(await control.sent.isEmpty)

    selection.toggle(groups[2].chips[1], in: groups[2])
    selection.confirm()
    let reply = try #require(selection.reply)
    await model.send(reply)

    // One send, as the picker's own keys: release is option 2, Yes option 1, Ann and Bo are
    // toggles followed by `right`, and the last `1` is the review screen's Submit.
    #expect(
      await control.sent == [
        .keys(paneID: "w1:p2", keys: [.digit2, .digit1, .digit1, .digit2, .right, .digit1])
      ]
    )
    #expect(model.state.phase == .sent)
  }

  /// A complete selection left standing would re-send the whole message on the next tap. It is
  /// cleared when the reply goes, so one more tap sends nothing until every question is
  /// answered again.
  @Test("a tap after a complete reply has gone does not send it a second time")
  func aTapAfterSendingDoesNotResend() async throws {
    let control = FakeControl()
    let model = composer(control)
    let call = ToolCall(
      name: "AskUserQuestion",
      outcome: .pending,
      questions: [
        PendingQuestion(question: "Which branch?", options: ["main", "release"]),
        PendingQuestion(question: "Who reviews it?", options: ["Ann", "Bo"]),
      ]
    )
    let groups = call.pendingNotice(agentStatus: .blocked).groups
    var selection = ReplyChipSelection(groups: groups)

    selection.toggle(groups[0].chips[0], in: groups[0])
    selection.toggle(groups[1].chips[0], in: groups[1])
    let reply = try #require(selection.reply)
    await model.send(reply)
    // What `PaneChatView.choose` does as the reply goes. It marks rather than clears, so the
    // chosen chips stay on screen under the verdict.
    selection.markSent()

    selection.toggle(groups[1].chips[1], in: groups[1])
    #expect(selection.reply == nil)
    // The record survives: the band under `Sent` still shows what was answered.
    #expect(selection.isChosen(groups[0].chips[0], in: groups[0]))
    #expect(selection.isChosen(groups[1].chips[0], in: groups[1]))
    if let again = selection.reply { await model.send(again) }

    #expect(await control.sent == [.keys(paneID: "w1:p2", keys: [.digit1, .digit1, .digit1])])
  }

  /// A single-question call is unchanged: the first tap completes it, and the chip's own
  /// action goes over — a generic Approve is still the `y` key, not the word typed out.
  @Test("a single-question call still sends on the first tap")
  func singleQuestionSendsOnTheFirstTap() async throws {
    let control = FakeControl()
    let model = composer(control)
    let call = ToolCall(name: "Bash", target: "cargo test", outcome: .pending)
    let groups = call.pendingNotice(agentStatus: .blocked).groups
    try #require(groups.count == 1)
    var selection = ReplyChipSelection(groups: groups)

    selection.toggle(groups[0].chips[0], in: groups[0])
    let reply = try #require(selection.reply)
    await model.send(reply)

    #expect(await control.sent == [.keys(paneID: "w1:p2", keys: [.yes])])
  }

  @Test("a key goes over as a key, not as its name typed out")
  func sendsKeys() async {
    let control = FakeControl()
    let model = composer(control)

    await model.send(.interrupt)

    #expect(await control.sent == [.keys(paneID: "w1:p2", keys: [.interrupt])])
    #expect(model.state.phase == .sent)
  }

  @Test("a refused reply says what herdr said, and keeps the text")
  func failureKeepsTheText() async {
    // Clearing the field on failure would make the user type it again on a phone.
    let control = FakeControl()
    await control.failNextSends(1, with: .herdrCommandFailed(reason: "no such pane"))
    let model = composer(control)
    model.text = "retry me"

    await model.send()

    #expect(model.failure == .herdrCommandFailed(reason: "no such pane"))
    #expect(model.text == "retry me")
    #expect(model.status?.offersRetry == true)
  }

  @Test("a retry sends the same reply again, with nothing retyped")
  func retryResends() async {
    let control = FakeControl()
    await control.failNextSends(1, with: .herdrCommandFailed(reason: "no such pane"))
    let model = composer(control)
    model.text = "retry me"
    await model.send()
    // The refused attempt is recorded. It asked with the right text, which the retry repeats.
    #expect(await control.sent == [.submit(paneID: "w1:p2", text: "retry me")])

    await model.retry()

    // Two entries, one per attempt. A retry that did nothing would leave one.
    #expect(
      await control.sent == [
        .submit(paneID: "w1:p2", text: "retry me"),
        .submit(paneID: "w1:p2", text: "retry me"),
      ]
    )
    #expect(model.state.phase == .sent)
    #expect(model.text.isEmpty, "a retry that worked empties the field like any other send")
  }

  @Test("a retried key press goes over as the same key")
  func retryResendsAKey() async {
    let control = FakeControl()
    await control.failNextSends(1, with: .herdrCommandFailed(reason: "no such pane"))
    let model = composer(control)
    await model.send(.esc)

    await model.retry()

    // Two: the refused press and the retried one, the same key both times.
    #expect(
      await control.sent == [
        .keys(paneID: "w1:p2", keys: [.esc]),
        .keys(paneID: "w1:p2", keys: [.esc]),
      ]
    )
  }

  @Test("there is nothing to retry when nothing failed")
  func retryNeedsAFailure() async {
    let control = FakeControl()
    let model = composer(control)
    model.text = "y"

    await model.retry()

    #expect(await control.sent.isEmpty)
    #expect(model.state.phase == .editing)
  }

  @Test("a send on a link that has gone says so rather than looking like it worked")
  func deadLinkFails() async {
    // The control is resolved per send, so this is a failure with a Retry, not a reply that
    // silently went nowhere.
    let model = composer(nil)
    model.text = "y"

    await model.send()

    #expect(model.failure != nil)
    #expect(model.text == "y")
  }

  @Test("a composer is identified by its pane")
  func identity() {
    #expect(composer(FakeControl()).id == "w1:p2")
  }

  // MARK: - Holding "Sent" until something says so

  /// The confirmation is retired by evidence, not a timer. On a timer the header would then say
  /// "Claude is waiting for you." over the same question with an empty field, the prompt to
  /// answer twice.
  @Test("Sent outlives the old three-second timer while herdr still reports the pane blocked")
  func sentIsNotRetiredByAClock() async {
    let model = composer(FakeControl())
    model.text = "y"
    await model.send()

    // Past several ticks of the ageing task.
    try? await Task.sleep(for: .milliseconds(60))

    #expect(model.state.phase == .sent)
    #expect(model.status?.message == "Sent · waiting for the agent")
  }

  @Test("Sent clears when the poll reports the pane has stopped being blocked")
  func sentClearsOnAStatusChange() async {
    let model = composer(FakeControl())
    model.text = "y"
    await model.send()
    #expect(model.state.phase == .sent)

    model.paneChanged(
      to: Pane(
        id: "w1:p2",
        tabID: "w1:t1",
        workspaceID: "w1",
        title: "needs a decision",
        agent: Agent(name: "Claude", kind: "claude", status: .working)
      )
    )

    #expect(model.state.phase == .editing)
    #expect(model.status == nil)
    #expect(model.sentNotice == nil, "a settled composer stops waking up once a second")
  }

  @Test("Sent clears when the conversation gains a turn")
  func sentClearsWhenTheTranscriptMoves() async {
    let model = composer(FakeControl())
    model.text = "y"
    await model.send()

    model.transcriptAdvanced()

    #expect(model.state.phase == .editing)
  }

  /// Neither piece of evidence arrived, so the notice says how long it has been waiting
  /// rather than reverting to a header that would contradict it.
  @Test("a send nothing has confirmed ages on screen")
  func sentAges() async {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let model = composer(FakeControl(), now: { clock.now })
    model.text = "y"
    await model.send()
    #expect(model.status?.message == "Sent · waiting for the agent")

    clock.advance(by: 40)

    #expect(model.status?.message == "Sent 40s ago")
    #expect(model.status?.detail == "herdr still reports Claude as waiting.")
    #expect(model.state.phase == .sent)
  }

  // MARK: - Telling the rest of the connection

  /// A successful send triggers a re-read. Without it the reader answers and watches the same
  /// question stay on screen with an empty field under it.
  @Test("a reply herdr took tells the connection what was sent, and to which pane")
  func announcesASend() async {
    var announced: [(String, PaneComposerState.Attempt)] = []
    let model = composer(FakeControl(), onSent: { announced.append(($0, $1)) })
    model.text = "yes, go ahead"

    await model.send()

    #expect(announced.count == 1)
    #expect(announced.first?.0 == "w1:p2")
    #expect(announced.first?.1 == .text("yes, go ahead"))
  }

  @Test("a key press is announced too, because it changes what the pane is showing")
  func announcesAKey() async {
    var announced: [(String, PaneComposerState.Attempt)] = []
    let model = composer(FakeControl(), onSent: { announced.append(($0, $1)) })

    await model.send(.enter)

    #expect(announced.first?.1 == .key(.enter))
  }

  @Test("a send that failed announces nothing")
  func aFailedSendAnnouncesNothing() async {
    let control = FakeControl()
    await control.failNextSends(1, with: .herdrCommandFailed(reason: "no such pane"))
    var announced = 0
    let model = composer(control, onSent: { _, _ in announced += 1 })
    model.text = "y"

    await model.send()

    #expect(announced == 0)
  }

  // MARK: - A send that never comes back

  /// A stalled send needs a deadline. Otherwise the bar sits on `Sending…` with every key
  /// disabled and no Retry, and the composer is cached for the whole connection, so switching
  /// surfaces does not escape it.
  @Test("a send that never comes back fails into a Retry rather than hanging on Sending")
  func aStalledSendIsBounded() async {
    let control = HangingControl()
    let model = composer(control, sendDeadline: .milliseconds(50))
    model.text = "y"

    await model.send()

    #expect(model.state.phase == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer)))
    #expect(model.status?.offersRetry == true)
    #expect(model.text == "y", "nothing typed is lost to a deadline either")
    await control.release()
  }

  /// The deadline must not fire on a send that worked, or a reply that landed would be
  /// reported as having failed and be sent a second time on the retry.
  @Test("a send that answers well inside the deadline is not called a failure")
  func aFastSendIsNotBounded() async {
    let model = composer(FakeControl(), sendDeadline: .seconds(30))
    model.text = "y"

    await model.send()

    #expect(model.state.phase == .sent)
  }

  @Test("a key press is bounded by the same deadline")
  func aStalledKeyIsBounded() async {
    let control = HangingControl()
    let model = composer(control, sendDeadline: .milliseconds(50))

    await model.send(.interrupt)

    #expect(model.failure == .herdrCommandFailed(reason: PaneComposerCopy.noAnswer))
    await control.release()
  }
}

/// A clock a test moves by hand.
///
/// A `@MainActor` class rather than an actor, so a synchronous property like `status` can read
/// it.
@MainActor
final class TestClock {
  private(set) var now: Date

  init(now: Date) {
    self.now = now
  }

  func advance(by seconds: TimeInterval) {
    now = now.addingTimeInterval(seconds)
  }
}

/// The composers the connection keeps, one per pane.
@MainActor
@Suite("PaneComposerCache")
struct PaneComposerCacheTests {
  private let pane = Pane(
    id: "w1:p2",
    tabID: "w1:t1",
    workspaceID: "w1",
    title: "needs a decision",
    agent: Agent(name: "Claude", status: .blocked)
  )

  @Test("a half-typed reply survives the pane being asked for again")
  func staysTyped() {
    // Switching to the Terminal side and back rebuilds the bar, not the model behind it.
    let cache = PaneComposerCache(control: { nil })
    cache.model(for: pane).text = "half written"

    // The same pane as a different value, as a poll hands over every three seconds.
    let polled = Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", status: .working)
    )

    #expect(cache.model(for: polled).text == "half written")
  }

  @Test("two panes get two composers")
  func oneEach() {
    let cache = PaneComposerCache(control: { nil })
    let other = Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "wiring")

    cache.model(for: pane).text = "for p2"

    #expect(cache.model(for: other).text.isEmpty)
    #expect(cache.existingModel(for: "w9:p9") == nil)
  }

  /// A pane that has left the session is the one case where forgetting a composer throws
  /// nothing away that anybody could still use.
  @Test("a pane that leaves the session takes its composer with it")
  func forgetsPanesThatLeft() {
    let cache = PaneComposerCache(control: { nil })
    let other = Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "wiring")
    cache.model(for: pane).text = "for p2"
    cache.model(for: other).text = "for p1"

    cache.forgetEverythingExcept(["w1:p1"])

    #expect(cache.existingModel(for: "w1:p2") == nil)
    #expect(cache.existingModel(for: "w1:p1")?.text == "for p1")
  }

  @Test("every composer it makes reports its sends to the connection")
  func passesOnTheSendHook() async {
    var announced: [String] = []
    let cache = PaneComposerCache(control: { FakeControl() }, onSent: { id, _ in
      announced.append(id)
    })
    let model = cache.model(for: pane)
    model.text = "y"

    await model.send()

    #expect(announced == ["w1:p2"])
  }
}

// MARK: - The uploaded path, handed to the pane

extension PaneComposerModelTests {
  /// A small real PNG, so `ImageDownscale` succeeds and the upload path runs. Rendered rather
  /// than committed; see `PaneAttachmentModelTests`.
  private static func pngBytes() throws -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
      UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
    return try #require(image.pngData())
  }

  /// Waits on the main actor for a condition rather than sleeping a fixed interval.
  private func waitFor(
    _ description: String,
    until condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    for _ in 0..<600 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(description).", sourceLocation: sourceLocation)
  }

  /// The host path goes to the pane, bare.
  ///
  /// `.text` rather than `.submit`: `submitText` appends a CR, which would submit the bare path
  /// as the whole question. The path is compared whole, so a trailing space or newline fails.
  @Test("the uploaded path is typed into the pane, with nothing appended")
  func handsTheUploadedPathToThePane() async throws {
    let control = FakeControl()
    let path = "/home/carson/.driverr/inbox/8f1c2d.png"
    let model = composer(control, makeUpload: { _, _ in GatedUpload(hostPath: path) })

    model.attachment.attach(try Self.pngBytes())
    await waitFor("the hand-off") { model.attachment.phase == .handedOver }

    #expect(await control.sent == [.text(paneID: "w1:p2", text: path)])
    // Driverr's own field is untouched: the path went to the agent's input box on the host.
    #expect(model.text.isEmpty)
  }

  /// The path goes to the composer that staged the image, and to no other pane.
  ///
  /// An upload takes seconds and a pane switch none, so the bytes can land after the reader
  /// has answered another pane. Exactly one `.text` reaches the wire, naming the staging
  /// composer's pane, so a hand-off wired to a shared target or to the most recent composer
  /// fails.
  ///
  /// It cannot separate `PaneComposerModel.id` from `pane.id`: `paneChanged(to:)` guards that
  /// they are equal.
  @Test("the path reaches the staging composer's own pane and no other")
  func handsThePathToTheStagedPaneAcrossASwitch() async throws {
    let control = FakeControl()
    let path = "/home/carson/.driverr/inbox/staged.png"
    let upload = GatedUpload(hostPath: path, holdsOpen: true)
    let staged = composer(control, makeUpload: { _, _ in upload })
    let elsewhere = composer(
      control,
      pane: Pane(id: "w2:p7", tabID: "w2:t1", workspaceID: "w2", title: "schema sync"))

    staged.attachment.attach(try Self.pngBytes())
    await waitFor("the upload to start") { staged.attachment.phase?.isUploading == true }

    // The reader has gone to another pane and answered it while the bytes are still moving.
    elsewhere.text = "yes"
    await elsewhere.send()

    upload.release()
    await waitFor("the hand-off") { staged.attachment.phase == .handedOver }

    let sent = await control.sent
    #expect(sent.contains(.text(paneID: "w1:p2", text: path)))
    #expect(!sent.contains(.text(paneID: "w2:p7", text: path)))
    // The other pane got its reply and nothing else.
    #expect(sent.filter { if case .text = $0 { return true } else { return false } }.count == 1)
  }

  /// The finished row goes when the reply it was staged for is sent. Otherwise it sits above
  /// every reply for the rest of the connection.
  @Test("a sent reply retires the finished attachment row")
  func aReplyRetiresTheRow() async throws {
    let control = FakeControl()
    let model = composer(
      control, makeUpload: { _, _ in GatedUpload(hostPath: "/home/c/.driverr/inbox/a.png") })

    model.attachment.attach(try Self.pngBytes())
    await waitFor("the hand-off") { model.attachment.phase == .handedOver }

    model.text = "what is wrong with this screen?"
    await model.send()

    #expect(!model.attachment.isAttached)
    #expect(model.attachment.phase == nil)
  }

  /// A reply sent while the bytes are still moving leaves the upload alone.
  /// `attachment.remove()` cancels the transfer, so an unguarded clear would throw the image
  /// away with no notice.
  ///
  /// The whole sequence is asserted, because a row surviving a cancelled upload looks the same
  /// for the first second.
  @Test("a reply sent mid-upload neither clears the row nor cancels the transfer")
  func aReplyDuringAnUploadLeavesItAlone() async throws {
    let control = FakeControl()
    let path = "/home/carson/.driverr/inbox/inflight.png"
    let upload = GatedUpload(hostPath: path, holdsOpen: true)
    let model = composer(control, makeUpload: { _, _ in upload })

    model.attachment.attach(try Self.pngBytes())
    await waitFor("the upload to start") { model.attachment.phase?.isUploading == true }

    model.text = "not about the image"
    await model.send()

    #expect(model.state.phase == .sent)
    // Still staged, still moving, and nothing was cancelled.
    #expect(model.attachment.isAttached)
    #expect(model.attachment.phase?.isUploading == true)
    #expect(!upload.wasCancelled)

    // The hand-off still lands afterwards.
    upload.release()
    await waitFor("the hand-off") { model.attachment.phase == .handedOver }
    #expect(!upload.wasCancelled)
    #expect(await control.sent.contains(.text(paneID: "w1:p2", text: path)))
  }

  /// A key press is not that reply. Escape or an arrow steers a menu, and the staged image is
  /// still wanted.
  @Test("a key press leaves the attachment row alone")
  func aKeyPressLeavesTheRowAlone() async throws {
    let control = FakeControl()
    let model = composer(
      control, makeUpload: { _, _ in GatedUpload(hostPath: "/home/c/.driverr/inbox/a.png") })

    model.attachment.attach(try Self.pngBytes())
    await waitFor("the hand-off") { model.attachment.phase == .handedOver }

    await model.send(.esc)

    #expect(model.attachment.isAttached)
    #expect(model.attachment.phase == .handedOver)
  }
}

/// An upload that reports one progress event and then lands, optionally only when let go, so
/// a test can put a pane switch between the bytes arriving and the path being handed over.
private final class GatedUpload: ImageUploading, @unchecked Sendable {
  let progress: AsyncStream<ImageUploadProgress>
  private let signal: AsyncStream<ImageUploadProgress>.Continuation
  private let gate: AsyncStream<Void>
  private let open: AsyncStream<Void>.Continuation
  private let hostPath: String
  private let holdsOpen: Bool
  /// Set when a cancel cuts the hold short, proving a clear reached the transfer.
  private(set) var wasCancelled = false

  init(hostPath: String, holdsOpen: Bool = false) {
    self.hostPath = hostPath
    self.holdsOpen = holdsOpen
    let (stream, continuation) = AsyncStream.makeStream(of: ImageUploadProgress.self)
    progress = stream
    signal = continuation
    let (gateStream, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    gate = gateStream
    open = gateContinuation
  }

  func upload() async throws -> ImageUploadOutcome {
    signal.yield(ImageUploadProgress(bytesSent: 10, totalBytes: 100))
    if holdsOpen {
      // Suspends rather than sleeping; see `CLAUDE.md` on the cooperative pool.
      //
      // A cancelled task ends this iteration without throwing, so the cancel is read
      // afterwards, or a cancelled upload would read as a success.
      for await _ in gate { break }
      if Task.isCancelled {
        wasCancelled = true
        signal.finish()
        throw CancellationError()
      }
    }
    signal.finish()
    return ImageUploadOutcome(hostPath: hostPath, bytesSent: 100)
  }

  func release() {
    open.yield(())
    open.finish()
  }
}

import DriverrCore
import DriverrHerdr
import Testing

@testable import Driverr

/// Split, rename, close — everything except what the toolbar looks like.
///
/// "Close asks first" is a claim about behaviour. A UI test that taps through a dialog proves
/// the dialog exists, not that nothing can skip it.
@MainActor
@Suite("PaneActionsModel")
struct PaneActionsModelTests {
  private let pane = Pane(
    id: "w1:p2",
    tabID: "w1:t1",
    workspaceID: "w1",
    title: "needs a decision",
    agent: Agent(name: "Claude", status: .blocked),
    terminalID: "term_w1p2"
  )

  private func model(
    _ control: FakeControl = FakeControl(),
    onChanged: @escaping () async -> Void = {},
    onClosed: @escaping () -> Void = {}
  ) -> PaneActionsModel {
    PaneActionsModel(pane: pane, control: control, onChanged: onChanged, onClosed: onClosed)
  }

  @Test("a harmless action runs straight away")
  func runsNonDestructive() async {
    let control = FakeControl()
    let subject = model(control)

    await subject.request(.split(.right))

    #expect(await control.performed.map(\.action) == [.split(.right)])
    #expect(subject.pendingConfirmation == nil)
  }

  @Test("closing asks first, and does nothing until it is confirmed")
  func closeAsksFirst() async {
    // The confirmation cannot be skipped by any path.
    let control = FakeControl()
    let subject = model(control)

    await subject.request(.close)

    #expect(subject.pendingConfirmation == .close)
    #expect(await control.performed.isEmpty, "the pane was closed without asking")
  }

  @Test("confirming closes the pane; cancelling closes nothing")
  func confirmAndCancel() async {
    let cancelled = FakeControl()
    let subjectA = model(cancelled)
    await subjectA.request(.close)
    subjectA.cancelConfirmation()
    #expect(await cancelled.performed.isEmpty)
    #expect(subjectA.pendingConfirmation == nil)

    let confirmed = FakeControl()
    let subjectB = model(confirmed)
    await subjectB.request(.close)
    await subjectB.confirm(.close)
    #expect(await confirmed.performed.map(\.action) == [.close])
    #expect(subjectB.didClose, "the screen watches this to leave a terminal with no pane")
  }

  @Test("confirming still works after the pending action has already been cleared")
  func confirmSurvivesTheAlertDismissal() async {
    // An alert's `isPresented` setter runs before the tapped button's action, so the pending
    // action is gone when `confirm` runs. Re-reading it would find nil and do nothing.
    let control = FakeControl()
    let subject = model(control)

    await subject.request(.close)
    subject.cancelConfirmation()  // what the alert's own dismissal does
    await subject.confirm(.close)

    #expect(await control.performed.map(\.action) == [.close])
  }

  @Test("every action names the pane the toolbar is attached to")
  func targetsTheRightPane() async {
    // The one failure mode with no undo: aiming a close at somebody else's pane.
    let control = FakeControl()
    let subject = model(control)

    await subject.request(.split(.down))
    await subject.request(.rename("logs"))

    #expect(await control.performed.allSatisfy { $0.paneID == "w1:p2" })
  }

  @Test("starting a rename opens the prompt with the current title as the draft")
  func startRenamingSeedsTheDraft() {
    // What `PanePromptBar` reads to decide what to focus and select. The focus itself needs
    // a live responder chain, so it is a UI test.
    let subject = model()

    subject.startRenaming()

    #expect(subject.prompt == .rename)
    #expect(subject.draftLabel == pane.title)
  }

  @Test("a rename sends the new label")
  func renames() async {
    let control = FakeControl()
    let subject = model(control)
    subject.startRenaming()
    subject.draftLabel = "  build logs  "

    await subject.commitRename()

    #expect(await control.performed.map(\.action) == [.rename("build logs")])
    #expect(subject.prompt == nil)
  }

  @Test("a blank or unchanged rename is a cancel, not an erase")
  func blankRenameDoesNothing() async {
    let control = FakeControl()
    let subject = model(control)

    subject.draftLabel = "   "
    await subject.commitRename()
    subject.draftLabel = "needs a decision"
    await subject.commitRename()

    #expect(await control.performed.isEmpty)
  }

  @Test("the session is re-read after a change, not left to the poll interval")
  func refreshesAfterwards() async {
    // A sidebar still listing a closed pane invites a second tap, which lands somewhere else.
    var refreshes = 0
    let subject = model(onChanged: { refreshes += 1 })

    await subject.request(.split(.right))

    #expect(refreshes == 1)
  }

  @Test("a refused action says so and does not claim the pane closed")
  func failureIsReported() async {
    var refreshes = 0
    let control = FakeControl.failing(.herdrCommandFailed(reason: "pane is the last one"))
    let subject = PaneActionsModel(pane: pane, control: control, onChanged: { refreshes += 1 })

    await subject.request(.close)
    await subject.confirm(.close)

    #expect(subject.failure == .herdrCommandFailed(reason: "pane is the last one"))
    #expect(!subject.didClose, "a failed close must not take the terminal down with it")
    #expect(refreshes == 0)

    subject.clearFailure()
    #expect(subject.failure == nil)
  }

  @Test("a successful close tells the screen to leave; nothing else does")
  func closeNotifiesTheScreen() async {
    // A callback rather than the screen watching `didClose`: an `onChange` on an optional
    // model's property fires only if SwiftUI re-evaluates the body, which it may not.
    var closures = 0
    let subject = model(onClosed: { closures += 1 })

    await subject.request(.rename("logs"))
    await subject.request(.split(.right))
    #expect(closures == 0, "only closing takes the terminal down")

    await subject.request(.close)
    await subject.confirm(.close)
    #expect(closures == 1)
  }

  @Test("a failed close leaves the terminal where it is")
  func failedCloseDoesNotDismiss() async {
    var closures = 0
    let control = FakeControl.failing(.herdrCommandFailed(reason: "no"))
    let subject = PaneActionsModel(
      pane: pane,
      control: control,
      onClosed: { closures += 1 }
    )

    await subject.request(.close)
    await subject.confirm(.close)

    #expect(closures == 0)
  }

  @Test("only close is destructive")
  func destructiveness() {
    // A future destructive action inherits the prompt.
    #expect(PaneAction.close.isDestructive)
    #expect(!PaneAction.split(.right).isDestructive)
    #expect(!PaneAction.rename("x").isDestructive)
  }
}

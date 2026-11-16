import DriverrCore
import DriverrHerdr
import DriverrSSH
import DriverrTranscript
import Foundation
import Testing
import UserNotifications

@testable import Driverr

/// What a usage-limit stop schedules, and what takes it down again.
///
/// The timing rule is `LimitResetReminderTests` in `DriverrCore`. This is the app half:
/// permission, the memory that keeps a re-read from scheduling twice, the Continue opt-in,
/// and the connection feeding it pages.
@MainActor
@Suite("LimitResetNotifier", .timeLimit(.minutes(1)))
struct LimitResetNotifierTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let adder = DriverrCore.Host(name: "adder", hostname: "10.1.0.7", username: "carson")

  /// Fixed, so every reminder below has one fire date.
  private static let now = Date(timeIntervalSince1970: 1_790_541_600)
  private static let resetsAt = now.addingTimeInterval(7_200)
  private static let conversation = "3f8c1d20-0000-4000-8000-000000000002"
  private static let id = LimitResetReminder.notificationID(conversation: conversation)

  /// A clock a test moves.
  @MainActor private final class Clock {
    var now = LimitResetNotifierTests.now
  }

  private static func limit(resetsAt: Date = resetsAt) -> AgentStop {
    AgentStop(kind: .rateLimit, resetsAt: resetsAt, message: "You've hit your session limit")
  }

  private static func pane(_ id: String = "w1:p2") -> Pane {
    Pane(
      id: id, tabID: "w1:t1", workspaceID: "w1", title: "needs a decision",
      agent: Agent(name: "Claude", status: .idle))
  }

  private func notifier(
    _ center: FakeNotificationCenter, host: DriverrCore.Host? = nil,
    now: @escaping @MainActor () -> Date = { LimitResetNotifierTests.now }
  ) -> LimitResetNotifier {
    LimitResetNotifier(
      host: host ?? workbox, center: center, now: now,
      timeZone: { TimeZone(identifier: "America/Chicago")! })
  }

  private func report(
    _ notifier: LimitResetNotifier, stop: AgentStop?, pane: Pane = pane(),
    conversation: String = conversation
  ) async {
    notifier.report(.init(pane: pane, conversation: conversation, stop: stop))
    await notifier.work?.value
  }

  // MARK: - Scheduling

  @Test("a usage limit schedules one card at its reset, and a re-read schedules nothing more")
  func schedulesOnce() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)

    await report(notifier, stop: Self.limit())
    let first = try #require(await center.schedules.first)
    #expect(await center.schedules.count == 1)
    #expect(first.id == Self.id)
    #expect(first.title == "Usage limit reset")
    #expect(first.body == "needs a decision on workbox can continue.")
    #expect(first.categoryID == nil)
    #expect(
      first.userInfo == [
        NotificationTapRouter.hostIDKey: workbox.id.uuidString,
        NotificationTapRouter.paneIDKey: "w1:p2",
      ])

    await report(notifier, stop: Self.limit())
    await report(notifier, stop: Self.limit())
    #expect(await center.schedules.count == 1)
    #expect(await center.withdrawn.isEmpty)
  }

  @Test("the trigger the system builds fires at the reset", arguments: [
    // Two hours ahead of the real clock.
    Date().addingTimeInterval(7_200).timeIntervalSince1970.rounded(.up),
    // 07:30 UTC on 2027-11-07, the second 1:30 AM in Chicago, whose components are in GMT.
    1_825_572_600,
  ])
  func triggerFiresAtTheReset(seconds: TimeInterval) throws {
    let resetsAt = Date(timeIntervalSince1970: seconds)
    let reminder = try #require(
      LimitResetReminder.schedule(
        for: Self.limit(resetsAt: resetsAt), conversation: "s1", asOf: Date(),
        timeZone: TimeZone(identifier: "America/Chicago")!))
    let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.trigger, repeats: false)
    #expect(trigger.nextTriggerDate() == resetsAt)
  }

  @Test("a stop with no reset time, or one already past, schedules nothing")
  func nothingToSchedule() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)

    await report(notifier, stop: AgentStop(kind: .rateLimit, resetsAt: nil))
    await report(notifier, stop: Self.limit(resetsAt: Self.now.addingTimeInterval(-60)))
    await report(notifier, stop: AgentStop(kind: .serverError))

    #expect(await center.schedules.isEmpty)
  }

  @Test("no permission asks for none, and a later re-read schedules once it is granted")
  func waitsForPermission() async {
    let center = FakeNotificationCenter(status: .notDetermined)
    let notifier = notifier(center)

    await report(notifier, stop: Self.limit())
    #expect(await center.schedules.isEmpty)
    #expect(await center.authorizationRequests == 0)

    await center.setStatus(.authorized)
    await report(notifier, stop: Self.limit())
    #expect(await center.schedules.map(\.id) == [Self.id])
    #expect(await center.authorizationRequests == 0)
  }

  // MARK: - Taking it down

  @Test("the agent going on before the reset withdraws the card")
  func resumeCancels() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    await report(notifier, stop: Self.limit())
    #expect(await center.pending[Self.id] != nil)

    await report(notifier, stop: nil)

    #expect(await center.withdrawn == [Self.id])
    #expect(await center.pending.isEmpty)
  }

  @Test("the reset passing under a standing stop withdraws nothing, because the card is due")
  func theResetPassingKeepsTheCard() async {
    let center = FakeNotificationCenter(status: .authorized)
    let clock = Clock()
    let notifier = notifier(center, now: { clock.now })
    await report(notifier, stop: Self.limit())
    #expect(await center.schedules.count == 1)

    clock.now = Self.resetsAt.addingTimeInterval(60)
    await report(notifier, stop: Self.limit())

    #expect(await center.withdrawn.isEmpty)
    #expect(await center.schedules.count == 1)
  }

  @Test("a pane's first page with no limit withdraws what a previous process left")
  func aFirstPageWithoutALimitWithdraws() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)

    await report(notifier, stop: nil)
    #expect(await center.withdrawn == [Self.id])

    // Not on every page after it.
    await report(notifier, stop: nil)
    #expect(await center.withdrawn == [Self.id])
  }

  @Test("a past reset on a pane's first page withdraws nothing, because that card is due")
  func aFirstPageWithAPastLimitKeepsTheCard() async {
    let center = FakeNotificationCenter(status: .authorized)
    await report(notifier(center), stop: Self.limit(resetsAt: Self.now.addingTimeInterval(-60)))
    #expect(await center.withdrawn.isEmpty)
  }

  // MARK: - Continue

  @Test("Continue is off by default, and turning it on schedules the card again with it")
  func continueOptIn() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    await report(notifier, stop: Self.limit())
    #expect(!notifier.continues(paneID: "w1:p2"))

    notifier.setContinues(true, paneID: "w1:p2")
    await notifier.work?.value

    #expect(notifier.continues(paneID: "w1:p2"))
    #expect(await center.schedules.count == 2)
    #expect(await center.pending[Self.id]?.categoryID == LimitResetReminder.continueCategoryID)

    notifier.setContinues(false, paneID: "w1:p2")
    await notifier.work?.value
    #expect(!notifier.continues(paneID: "w1:p2"))
    #expect(await center.pending[Self.id]?.categoryID == nil)
  }

  @Test("a re-read, a relaunch or a second host does not take Continue off the card")
  func continueSurvivesAReRead() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    await report(notifier, stop: Self.limit())
    notifier.setContinues(true, paneID: "w1:p2")
    await notifier.work?.value
    await report(notifier, stop: Self.limit())
    #expect(await center.pending[Self.id]?.categoryID == LimitResetReminder.continueCategoryID)

    // A fresh notifier is a relaunch, or the host whose core added the same machine. It finds
    // the card already there for the same instant and keeps it.
    let fresh = self.notifier(center, host: adder)
    await report(fresh, stop: Self.limit(), pane: Self.pane("core:em/t1"))
    #expect(await center.schedules.count == 2)
    #expect(await center.pending[Self.id]?.categoryID == LimitResetReminder.continueCategoryID)
    #expect(fresh.continues(paneID: "core:em/t1"))
  }

  @Test("two hosts reading one conversation hold one card between them")
  func twoHostsOneCard() async {
    let center = FakeNotificationCenter(status: .authorized)
    let own = notifier(center)
    let adding = notifier(center, host: adder)

    await report(own, stop: Self.limit(), pane: Self.pane("core:t1"))
    await report(adding, stop: Self.limit(), pane: Self.pane("core:em/t1"))

    #expect(await center.schedules.map(\.id) == [Self.id])
    #expect(await center.pending.count == 1)
  }

  @Test("a new limit in the same conversation starts with Continue off")
  func aNewLimitResetsContinue() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    await report(notifier, stop: Self.limit())
    notifier.setContinues(true, paneID: "w1:p2")
    await notifier.work?.value

    await report(notifier, stop: Self.limit(resetsAt: Self.resetsAt.addingTimeInterval(3_600)))

    #expect(!notifier.continues(paneID: "w1:p2"))
    #expect(await center.pending[Self.id]?.categoryID == nil)
    #expect(await center.withdrawn.isEmpty, "the same id is replaced, not withdrawn")
  }

  // MARK: - Through the connection

  /// The conversation a session file holds, swapped by the test.
  private actor Conversation {
    var host: FakeTranscriptHost
    init(_ host: FakeTranscriptHost) { self.host = host }
    func set(_ host: FakeTranscriptHost) { self.host = host }
    func run(_ command: String) async throws -> CommandResult { try await host.run(command) }
  }

  private static func file(stopped: Bool) -> FakeTranscriptHost {
    var turns: [FakeTranscriptHost.Turn] = [
      .init(speaker: .human, text: "run the migration", secondsAgo: 600),
      .init(speaker: .assistant, text: "The migration ran.", secondsAgo: 420),
    ]
    if stopped {
      turns.append(
        .init(
          speaker: .apiError(
            error: "rate_limit", status: 429, resetsAt: Date().addingTimeInterval(7_200)),
          text: "You've hit your session limit", secondsAgo: 300))
    } else {
      turns.append(.init(speaker: .assistant, text: "Carrying on.", secondsAgo: 10))
    }
    return FakeTranscriptHost(sessionID: conversation, turns: turns)
  }

  private var claudePane: Pane {
    Pane(
      id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "needs a decision",
      agent: Agent(
        name: "Claude", kind: "claude", status: .idle,
        session: AgentSession(agent: "claude", kind: "id", value: Self.conversation)),
      terminalID: "term_w1p2",
      directory: "/home/carson/dev/driverr")
  }

  private func connection(
    center: FakeNotificationCenter, conversation: Conversation
  ) -> ConnectionModel {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [workbox.hostname: FakeSSHTransport.defaultHostKey])
    environment.makeTransport = { FakeSSHTransport() }
    environment.makeHerdrControl = { _ in FakeControl() }
    environment.makeTranscriptReader = { _ in
      TranscriptReader(run: { try await conversation.run($0) })
    }
    environment.notifications = center
    return ConnectionModel(host: workbox, environment: environment)
  }

  /// Opens the pane's conversation on the current link and waits for the page and for
  /// whatever it scheduled.
  private func read(_ model: ConnectionModel, refresh: Bool = false) async throws {
    let chat = try #require(model.transcripts?.model(for: claudePane))
    if refresh { chat.refresh() } else { chat.loadIfNeeded() }
    await chat.currentLoad?.value
    #expect(chat.transcript != nil, "the fixture never reached the model")
    await model.limitResets.work?.value
  }

  @Test("a connection schedules a stop once, keeps it across a disconnect, and cancels on resume")
  func throughTheConnection() async throws {
    let center = FakeNotificationCenter(status: .authorized)
    let conversation = Conversation(Self.file(stopped: true))
    let model = connection(center: center, conversation: conversation)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    #expect(model.phase == .connected)

    try await read(model)
    #expect(await center.schedules.map(\.id) == [Self.id])

    // A re-read of the same stop.
    try await read(model, refresh: true)
    #expect(await center.schedules.count == 1)

    // A disconnect drops the page and is not a resume.
    await model.disconnect()
    #expect(model.transcripts == nil)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    try await read(model)
    #expect(await center.withdrawn.isEmpty)
    #expect(await center.schedules.count == 1)

    // The agent goes on.
    await conversation.set(Self.file(stopped: false))
    try await read(model, refresh: true)
    #expect(await center.withdrawn == [Self.id])
    #expect(await center.pending.isEmpty)
  }

  // MARK: - The action

  @Test("Continue opens the pane and asks for continue to be sent; a plain tap only opens it")
  func continueActionRoute() {
    let hostID = UUID()
    let userInfo = [
      NotificationTapRouter.hostIDKey: hostID.uuidString,
      NotificationTapRouter.paneIDKey: "w1:p2",
    ]

    let continuing = TerminalPresenter()
    NotificationTapRouter.route(
      action: LimitResetReminder.continueActionID, userInfo: userInfo, to: continuing)
    #expect(
      continuing.pendingOpen == .init(hostID: hostID, intent: .paneSending("w1:p2", text: "continue")))

    let tapped = TerminalPresenter()
    NotificationTapRouter.route(
      action: UNNotificationDefaultActionIdentifier, userInfo: userInfo, to: tapped)
    #expect(tapped.pendingOpen == .init(hostID: hostID, paneID: "w1:p2"))

    let empty = TerminalPresenter()
    NotificationTapRouter.route(
      action: LimitResetReminder.continueActionID, userInfo: [:], to: empty)
    #expect(empty.pendingOpen == nil)
  }
}

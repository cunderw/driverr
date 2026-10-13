import DriverrCore
import Foundation
import Testing

@testable import Driverr

/// A notification centre that records instead of posting.
///
/// Internal, so `BackgroundRefreshTests` can assert what a background run posted.
///
/// An `actor`, so it makes no assumption about where a caller runs: the notifier is
/// main-actor, and `TerminalPresenter` posts from an unstructured task.
actor FakeNotificationCenter: NotificationScheduling {
  struct Post: Equatable {
    let id: String
    let title: String
    let body: String
    let userInfo: [String: String]
  }

  private(set) var posts: [Post] = []
  private(set) var withdrawn: [String] = []
  private(set) var authorizationRequests = 0
  private var status: NotificationAuthorization
  /// What the system says when it is asked. Separate from `status`, so the user can say no to
  /// the alert.
  private let grantsWhenAsked: Bool

  init(status: NotificationAuthorization, grantsWhenAsked: Bool = true) {
    self.status = status
    self.grantsWhenAsked = grantsWhenAsked
  }

  func authorizationStatus() async -> NotificationAuthorization { status }

  /// Run inside `requestAuthorization` before it answers, so a test can put a poll in the
  /// middle of a pending permission alert.
  private var whileAsking: (@Sendable () async -> Void)?

  func askDuringAuthorization(_ body: @escaping @Sendable () async -> Void) {
    whileAsking = body
  }

  @discardableResult
  func requestAuthorization() async -> Bool {
    authorizationRequests += 1
    await whileAsking?()
    status = grantsWhenAsked ? .authorized : .denied
    return grantsWhenAsked
  }

  func post(id: String, title: String, body: String, userInfo: [String: String]) async {
    posts.append(Post(id: id, title: title, body: body, userInfo: userInfo))
  }

  func withdraw(ids: [String]) async {
    withdrawn.append(contentsOf: ids)
    // The wake-up for `TerminalPresenterWithdrawalTests.withdrawals(from:)`: the withdrawal is
    // an unstructured task, and `withdrawn` is actor state observation cannot reach.
    Waker.signalShared()
  }
}

private func pane(_ id: String, status: AgentStatus) -> Pane {
  Pane(
    id: id,
    tabID: "t1",
    workspaceID: "w1",
    title: "pane \(id)",
    agent: Agent(name: "Claude", status: status)
  )
}

private func tree(_ panes: [Pane]) -> SessionTree {
  SessionTree(workspaces: [
    Workspace(
      id: "w1", number: 1, label: "one",
      tabs: [Tab(id: "t1", workspaceID: "w1", number: 1, label: "a", panes: panes)]
    )
  ])
}

/// The app-tier half of blocked-pane notifications: permission, the card's two strings, and
/// the identifiers a later open withdraws by. The timing rule is `BlockedPaneAlertsTests`.
@MainActor
@Suite("BlockedPaneNotifier")
struct BlockedPaneNotifierTests {
  private let host = DriverrCore.Host(
    name: "workbox",
    hostname: "10.1.0.9",
    username: "carson"
  )

  private func notifier(
    _ center: FakeNotificationCenter,
    store: any AnnouncedPaneStore = InMemoryAnnouncedPaneStore()
  ) -> BlockedPaneNotifier {
    BlockedPaneNotifier(host: host, center: center, store: store)
  }

  // MARK: - Surviving the process

  /// A `BGAppRefreshTask` launches the app from cold and builds its own notifier. Without the
  /// restored set, every run would meet every blocked pane as new and buzz the whole set.
  @Test("a pane the last process announced is not announced again")
  func theAnnouncedSetSurvivesTheProcess() async {
    let center = FakeNotificationCenter(status: .authorized)
    let store = InMemoryAnnouncedPaneStore(seeded: [host.id: ["w1:p1"]])
    let notifier = notifier(center, store: store)

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await center.posts.isEmpty)
  }

  /// The other half: a set nothing writes is a set nothing can restore.
  @Test("what was announced is written back for the next process")
  func theAnnouncedSetIsPersisted() async {
    let center = FakeNotificationCenter(status: .authorized)
    let store = InMemoryAnnouncedPaneStore()

    await notifier(center, store: store)
      .sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await store.announcedPanes(forHost: host.id) == ["w1:p1"])
  }

  @Test("one request per newly-blocked pane, carrying both ids")
  func oneRequestPerNewlyBlockedPane() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)

    await notifier.sessionChanged(
      to: tree([
        pane("w1:p1", status: .blocked),
        pane("w1:p2", status: .working),
        pane("w1:p3", status: .blocked),
      ]),
      isAppActive: false
    )

    let posts = await center.posts
    #expect(posts.count == 2)
    #expect(posts.map(\.id) == [
      BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p1"),
      BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p3"),
    ])
    // The pane names the conversation, the host names the machine.
    #expect(posts.first?.title == "pane w1:p1")
    #expect(posts.first?.body == "workbox needs you")
    // The ids the tap handler reads back out; see `NotificationTapRouterTests`.
    #expect(
      posts.first?.userInfo == [
        NotificationTapRouter.hostIDKey: host.id.uuidString,
        NotificationTapRouter.paneIDKey: "w1:p1",
      ]
    )
  }

  @Test("a pane that is already blocked is not posted about again")
  func alreadyBlockedIsSilent() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    let blocked = tree([pane("w1:p1", status: .blocked)])

    await notifier.sessionChanged(to: blocked, isAppActive: false)
    await notifier.sessionChanged(to: blocked, isAppActive: false)
    await notifier.sessionChanged(to: blocked, isAppActive: false)

    #expect(await center.posts.count == 1, "a three-second poll would post twenty a minute")
  }

  @Test("nothing is posted while the app is active")
  func activePostsNothing() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)

    await notifier.sessionChanged(
      to: tree([pane("w1:p1", status: .blocked)]),
      isAppActive: true
    )

    #expect(await center.posts.isEmpty)

    // Backgrounding afterwards must not turn the transition the user watched into a card.
    await notifier.sessionChanged(
      to: tree([pane("w1:p1", status: .blocked)]),
      isAppActive: false
    )
    #expect(await center.posts.isEmpty)
  }

  @Test("a denied permission is silent, and is never asked about again")
  func denialIsSilent() async {
    let center = FakeNotificationCenter(status: .denied)
    let notifier = notifier(center)

    await notifier.sessionChanged(
      to: tree([pane("w1:p1", status: .blocked)]),
      isAppActive: false
    )

    #expect(await center.posts.isEmpty)
    #expect(await center.authorizationRequests == 0, "the user said no; there is no nag")
  }

  @Test("permission is asked for at the first blocked pane and not at construction")
  func authorizationIsLazy() async {
    let center = FakeNotificationCenter(status: .notDetermined)
    let notifier = notifier(center)

    #expect(
      await center.authorizationRequests == 0,
      "permission was asked for at launch, before any pane was blocked")

    await notifier.sessionChanged(
      to: tree([pane("w1:p1", status: .blocked)]),
      isAppActive: false
    )

    #expect(await center.authorizationRequests == 1)

    // The next question the same pane asks is posted too, without asking again.
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .working)]), isAppActive: false)
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await center.posts.count == 2)
    #expect(await center.authorizationRequests == 1, "asked twice for one answer")
  }

  @Test("the first blocked pane on a fresh install gets a card once the ask is granted")
  func aGrantedAskPostsForTheEventThatPromptedIt() async {
    // The ask must not swallow the event that raised it, or a fresh install's first blocked
    // pane shows nothing.
    let center = FakeNotificationCenter(status: .notDetermined)
    let notifier = notifier(center)

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await center.authorizationRequests == 1)
    let posts = await center.posts
    #expect(posts.count == 1)
    #expect(posts.first?.id == BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p1"))
  }

  @Test("a pane answered while the permission alert was up gets no card")
  func aPaneClearedDuringTheAskIsNotPosted() async {
    // The alert sits unanswered while the question is answered elsewhere and a poll clears the
    // pane. When the user allows notifications, no card may arrive for it: nothing would ever
    // withdraw it.
    let center = FakeNotificationCenter(status: .notDetermined)
    let notifier = notifier(center)
    let id = BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p1")
    await center.askDuringAuthorization { [notifier] in
      await notifier.sessionChanged(
        to: tree([pane("w1:p1", status: .working)]),
        isAppActive: false
      )
    }

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await center.authorizationRequests == 1)
    #expect(await center.posts.isEmpty)
    // The poll that cleared it took the card down.
    #expect(await center.withdrawn == [id])
  }

  @Test("permission is asked for at a blocked pane seen while the app is active, too")
  func authorizationIsAskedWhileActive() async {
    // If a request from the background cannot present its alert, the first blocked pane seen
    // while the app is active asks. The ask hangs off the pane being newly blocked, not off
    // there being something to post.
    let center = FakeNotificationCenter(status: .notDetermined)
    let notifier = notifier(center)

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: true)

    #expect(await center.authorizationRequests == 1)
    #expect(await center.posts.isEmpty, "active still posts nothing")
  }

  @Test("a user who says no to the alert gets nothing, then or later")
  func aRefusedAlertPostsNothing() async {
    let center = FakeNotificationCenter(status: .notDetermined, grantsWhenAsked: false)
    let notifier = notifier(center)

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .working)]), isAppActive: false)
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)

    #expect(await center.posts.isEmpty)
    #expect(await center.authorizationRequests == 1)
  }

  @Test("a pane that stops being blocked has its card withdrawn")
  func withdrawnWhenThePaneUnblocks() async {
    let center = FakeNotificationCenter(status: .authorized)
    let notifier = notifier(center)
    let id = BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p1")

    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)
    #expect(await center.withdrawn.isEmpty)

    // Answered from the laptop.
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .working)]), isAppActive: false)
    #expect(await center.withdrawn == [id])

    // A pane that leaves the session takes its card with it.
    await notifier.sessionChanged(to: tree([pane("w1:p1", status: .blocked)]), isAppActive: false)
    await notifier.sessionChanged(to: .empty, isAppActive: false)
    #expect(await center.withdrawn == [id, id])
  }

  @Test("a UI launch cannot reach the system's notification centre")
  func theEphemeralEnvironmentIsSilent() {
    // A `-uiTesting` launch that reached `LiveNotificationCenter` would raise a SpringBoard
    // permission alert at the first blocked pane, and every UI class that opens a pane would
    // fail on elements behind it.
    #expect(AppEnvironment.ephemeral.notifications is SilentNotificationCenter)
  }
}

/// Opening a pane takes its card down, whichever route the open came by.
///
/// The subject is `TerminalPresenter`, whose withdrawal is an unstructured task: `present` is
/// called from a SwiftUI action and cannot be `async`.
@MainActor
@Suite("TerminalPresenter notification withdrawal", .timeLimit(.minutes(1)))
struct TerminalPresenterWithdrawalTests {
  private let host = DriverrCore.Host(
    name: "workbox",
    hostname: "10.1.0.9",
    username: "carson"
  )

  /// Waits for the presenter's unstructured withdrawal to land, driven by the withdrawal.
  ///
  /// `FakeNotificationCenter.withdraw(ids:)` signals the shared waker, and `withdrawn` is actor
  /// state, so this is `waitUntilSignalled`. A withdrawal that never lands fails on the
  /// suite's `.timeLimit`, and the caller's `#expect` still prints what was withdrawn.
  ///
  /// `openingTheShellWithdrawsNothing` must not use this: it asserts nothing was withdrawn, so
  /// expiry is its passing outcome, and it keeps a short sleep.
  private func withdrawals(from center: FakeNotificationCenter) async -> [String] {
    await waitUntilSignalled("the presenter never withdrew anything") {
      await center.withdrawn.isEmpty == false
    }
    return await center.withdrawn
  }

  @Test("presenting a pane withdraws that pane's card")
  func openingAPaneWithdrawsItsCard() async {
    let center = FakeNotificationCenter(status: .authorized)
    var environment = AppEnvironment.ephemeral
    environment.notifications = center

    let presenter = TerminalPresenter()
    presenter.configure(
      hostStore: environment.hostStore,
      connections: ConnectionRegistry(),
      environment: environment,
      select: { _ in }
    )
    let model = ConnectionModel(host: host, environment: environment)

    presenter.present(
      host: host,
      model: model,
      pane: Pane(id: "w1:p1", tabID: "t1", workspaceID: "w1", title: "p1")
    )

    #expect(
      await withdrawals(from: center)
        == [BlockedPaneAlerts.notificationID(hostID: host.id, paneID: "w1:p1")]
    )
  }

  @Test("presenting the plain shell withdraws nothing")
  func openingTheShellWithdrawsNothing() async {
    let center = FakeNotificationCenter(status: .authorized)
    var environment = AppEnvironment.ephemeral
    environment.notifications = center

    let presenter = TerminalPresenter()
    presenter.configure(
      hostStore: environment.hostStore,
      connections: ConnectionRegistry(),
      environment: environment,
      select: { _ in }
    )

    presenter.present(host: host, model: ConnectionModel(host: host, environment: environment))

    // A moment is enough for a task that was going to run; the claim is that none was made.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await center.withdrawn.isEmpty)
  }
}

import DriverrCore
import DriverrHerdr
import DriverrSSH
import Foundation
import Testing

@testable import Driverr

/// The presentation is keyed by host alone. Asking for a second pane on a presented host
/// changes the scene's target rather than the request, so a switch keeps SwiftTerm, the
/// controller and the channel. Two panes on one host are the same presentation, and the scene's
/// current target is what tells them apart.
@MainActor
@Suite("TerminalPresenter")
struct TerminalPresenterTests {
  private let host = DriverrCore.Host(
    name: "workbox",
    hostname: "10.1.0.9",
    username: "carson"
  )
  private let other = DriverrCore.Host(
    name: "edge-01",
    hostname: "10.1.0.99",
    username: "root"
  )

  private func model(for host: DriverrCore.Host) -> ConnectionModel {
    ConnectionModel(host: host, environment: .ephemeral, prompt: InteractiveHostKeyPrompt())
  }

  private func pane(_ id: String) -> Pane {
    Pane(id: id, tabID: "t1", workspaceID: "w1", title: id)
  }

  private func record(_ paneID: String, _ witness: String) -> LastPaneRecord {
    LastPaneRecord(paneID: paneID, witness: witness)
  }

  /// A connected model whose writes land in `store`, with its session tree loaded.
  ///
  /// Connected, because the write takes the witness off the pane herdr reports. Every pane in
  /// `FakeControl.seededTree` carries a terminal id.
  private func connected(rememberingInto store: InMemoryLastPaneStore) async -> ConnectionModel {
    var environment = AppEnvironment.ephemeral
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey])
    environment.lastPanes = store
    let model = ConnectionModel(host: host, environment: environment)
    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.session?.refresh()
    return model
  }

  @Test("two panes on one host are one presentation, showing different things")
  func panesShareOnePresentation() throws {
    let presenter = TerminalPresenter()
    let model = model(for: host)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))
    let first = try #require(presenter.request)
    #expect(first.scene.current == .pane(id: "w1:p1"))

    presenter.present(host: host, model: model, pane: pane("w1:p2"))
    let second = try #require(presenter.request)

    #expect(second.id == first.id, "the cover would be re-presented, which is the old cost")
    #expect(
      second.scene === first.scene,
      "a new scene loses every warm pane, which is the whole of the change"
    )
    #expect(second.scene.current == .pane(id: "w1:p2"), "the scene did not switch")
  }

  @Test("the same pane twice changes nothing")
  func samePaneIsStable() throws {
    let presenter = TerminalPresenter()
    let model = model(for: host)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))
    let first = try #require(presenter.request)
    presenter.present(host: host, model: model, pane: pane("w1:p1"))

    #expect(presenter.request?.id == first.id)
    #expect(presenter.request?.scene === first.scene)
    #expect(first.scene.current == .pane(id: "w1:p1"))
  }

  @Test("a plain shell is a target of the same scene, not a second presentation")
  func shellIsATargetNotAPresentation() throws {
    let presenter = TerminalPresenter()
    let model = model(for: host)

    presenter.present(host: host, model: model)
    let shell = try #require(presenter.request)
    #expect(shell.scene.current == .shell)
    #expect(shell.scene.openedAsShell)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))
    #expect(presenter.request?.id == shell.id)
    #expect(presenter.request?.scene.current == .pane(id: "w1:p1"))
    // The Shell chip stays available, because that is how this scene opened.
    #expect(presenter.request?.scene.openedAsShell == true)
  }

  @Test("another host is another scene")
  func adifferentHostIsADifferentScene() throws {
    // A scene belongs to a host, and its warm panes are that host's.
    let presenter = TerminalPresenter()

    presenter.present(host: host, model: model(for: host), pane: pane("w1:p1"))
    let first = try #require(presenter.request)
    presenter.present(host: other, model: model(for: other), pane: pane("w1:p1"))
    let second = try #require(presenter.request)

    #expect(first.id != second.id)
    #expect(first.scene !== second.scene)
  }

  // MARK: - The pane switcher's cross-host pick

  /// A registry already holding `hosts`' connections, and a presenter configured with it: the
  /// state a user reaches by opening two hosts, through the same `model(for:environment:)`
  /// `HostDetailView` calls.
  private func registered(
    _ presenter: TerminalPresenter,
    _ hosts: [DriverrCore.Host],
    selection: Selection? = nil
  ) -> ConnectionRegistry {
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    let environment = AppEnvironment.ephemeral
    for host in hosts { _ = registry.model(for: host, environment: environment) }
    presenter.configure(
      hostStore: environment.hostStore,
      connections: registry,
      environment: environment,
      select: { selection?.id = $0 }
    )
    return registry
  }

  @Test("picking a pane on another host presents that host, ending the scene that was up")
  func aCrossHostPickPresentsTheOtherHost() throws {
    let presenter = TerminalPresenter()
    let registry = registered(presenter, [host, other])
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )
    let first = try #require(presenter.request)

    presenter.present(hostID: other.id, paneID: "w1:p2")

    let second = try #require(presenter.request)
    #expect(second.host.id == other.id, "the pick did not reach the other host")
    #expect(second.scene.current == .pane(id: "w1:p2"))
    // Another host is another presentation, so the scene that was up ends.
    #expect(second.scene !== first.scene)
    #expect(first.scene.isClosed, "the scene that was standing was left running")
  }

  @Test("a pick on a host with no connection left does nothing rather than opening an empty scene")
  func aCrossHostPickOnALostHostIsANoOp() throws {
    // `CrossHostPanes` offers connected hosts only, so this is the link going between the sheet
    // being drawn and a tile tapped. Making a model would present a terminal over a handshake.
    let presenter = TerminalPresenter()
    let registry = registered(presenter, [host])
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )
    let first = try #require(presenter.request)

    presenter.present(hostID: other.id, paneID: "w1:p2")

    #expect(presenter.request?.scene === first.scene, "the scene on screen was replaced")
    #expect(!first.scene.isClosed)
  }

  @Test("a pick on the host already on screen switches the scene rather than re-presenting it")
  func aPickOnTheCurrentHostSwitchesInPlace() throws {
    // The switcher cannot produce this, but the method must not tear a warm scene down for
    // nothing.
    let presenter = TerminalPresenter()
    let registry = registered(presenter, [host])
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )
    let first = try #require(presenter.request)

    presenter.present(hostID: host.id, paneID: "w1:p2")

    #expect(presenter.request?.scene === first.scene)
    #expect(first.scene.current == .pane(id: "w1:p2"))
  }

  @Test("a cross-host pick moves the sidebar to the host whose pane it shows")
  func aCrossHostPickMovesTheSidebar() throws {
    // As `open(hostID:paneID:)` does. On iPad the list and the detail column have to name the
    // same machine.
    let presenter = TerminalPresenter()
    let selection = Selection()
    let registry = registered(presenter, [host, other], selection: selection)
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )

    presenter.present(hostID: other.id, paneID: "w1:p2")

    #expect(presenter.request?.host.id == other.id)
    #expect(selection.id == other.id, "the sidebar stayed on the host the scene left")
  }

  @Test("a pick on a host with no connection left leaves the sidebar alone")
  func aLostHostsPickDoesNotMoveTheSidebar() throws {
    // A host nothing can reach must not take the highlight with no screen behind it.
    let presenter = TerminalPresenter()
    let selection = Selection()
    let registry = registered(presenter, [host], selection: selection)
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )
    selection.id = host.id

    presenter.present(hostID: other.id, paneID: "w1:p2")

    #expect(selection.id == host.id)
  }

  // MARK: - The sidebar tap that owns the detail column

  @Test("choosing another host in the sidebar ends the scene that owns the column")
  func aSidebarChoiceEndsTheScene() throws {
    // On regular width the detail branch takes the scene first, so the tap has to end it or
    // it moves only the highlight.
    let presenter = TerminalPresenter()
    let registry = registered(presenter, [host, other])
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )
    let standing = try #require(presenter.request)

    presenter.sidebarDidSelect(hostID: other.id)

    #expect(presenter.request == nil, "the column is still showing the old host's pane")
    #expect(standing.scene.isClosed, "the scene was left running behind the host screen")
  }

  @Test("choosing the host already on screen leaves the scene too")
  func aSidebarChoiceOfTheSameHostEndsTheScene() throws {
    // The row means "show me this host". A same-id check would drop this case.
    let presenter = TerminalPresenter()
    let registry = registered(presenter, [host])
    presenter.present(
      host: host,
      model: try #require(registry.existingModel(for: host.id)),
      pane: pane("w1:p1")
    )

    presenter.sidebarDidSelect(hostID: host.id)

    #expect(presenter.request == nil)
  }

  @Test("a sidebar choice with no scene up does nothing")
  func aSidebarChoiceWithNoSceneIsANoOp() {
    // Every tap on the host list on regular width comes through here.
    let presenter = TerminalPresenter()

    presenter.sidebarDidSelect(hostID: host.id)

    #expect(presenter.request == nil)
  }

  @Test("dismissing clears the request")
  func dismissClears() {
    let presenter = TerminalPresenter()
    presenter.present(host: host, model: model(for: host))
    presenter.dismiss()

    #expect(presenter.request == nil)
  }

  // MARK: - The phone's derived path

  /// The app-side half of `PhoneStackPathTests`, read through the presenter that supplies
  /// `hasRequest`.
  ///
  /// Back off the pane writes a one-element path and has to end the scene. A long press on Back
  /// offers "Hosts", which pops both levels in one write; the scene has to end with them, or a
  /// pane would be presented behind the host screen on the next layout pass.
  @Test("the phone's path derives from the selection and the request, and a pop ends the scene")
  func thePhonePathDerivesFromTheSelection() throws {
    let presenter = TerminalPresenter()
    #expect(PhoneStackPath.path(selectedHostID: nil, hasRequest: false).isEmpty)
    #expect(
      PhoneStackPath.path(selectedHostID: host.id, hasRequest: presenter.request != nil)
        == [.host(host.id)]
    )

    presenter.present(host: host, model: model(for: host))
    let scene = try #require(presenter.request?.scene)
    #expect(
      PhoneStackPath.path(selectedHostID: host.id, hasRequest: presenter.request != nil)
        == [.host(host.id), .pane],
      "a presented scene is the second level, pushed on the host screen"
    )
    #expect(
      PhoneStackPath.effect(ofWrite: [.host(host.id)], hadRequest: presenter.request != nil)
        == .endScene
    )
    #expect(
      PhoneStackPath.effect(ofWrite: [], hadRequest: presenter.request != nil)
        == .endSceneAndDeselect
    )

    // The effect, applied as `ContentView.phonePath`'s setter applies it.
    presenter.dismiss()
    #expect(presenter.request == nil)
    #expect(scene.isClosed, "popping past the pane has to end its scene")
    #expect(PhoneStackPath.effect(ofWrite: [], hadRequest: false) == .deselect)
  }

  // MARK: - The presentation's lifetime, not the view's

  /// A route flip (an iPad resize, Slide Over, a Pro Max phone turned to landscape) destroys
  /// one route's view and builds the other's. If a disappearing view closed the scene, a flip
  /// would end the user's shell. The close belongs to the presentation, so only `dismiss()`
  /// ends it.
  ///
  /// A unit test cannot change a size class, so this pins where the close lives.
  /// `PaneDetailColumnUITests.testTheSceneSurvivesARotation` covers the flip on the iPad.
  @Test("only dismissing ends the scene, which is what makes a route flip survivable")
  func onlyDismissingEndsTheScene() throws {
    let presenter = TerminalPresenter()
    presenter.present(host: host, model: model(for: host))
    let scene = try #require(presenter.request?.scene)

    // The flip itself, as the rule sees it: one request, two widths, two routes.
    #expect(TerminalSceneRoute.route(hasRequest: true, isRegularWidth: false) == .stack)
    #expect(TerminalSceneRoute.route(hasRequest: true, isRegularWidth: true) == .detailColumn)

    #expect(presenter.request?.scene === scene, "a flip must not replace the scene")
    #expect(!scene.isClosed, "a flip must not end the scene")

    presenter.dismiss()
    #expect(
      scene.isClosed,
      """
      Dismissing has to be what ends the scene. While a disappearing view was what closed \
      it, a size-class flip ended the user's shell.
      """
    )
  }

  /// A presentation replaced rather than dismissed has to end too, or the first host's
  /// controller is never handed back.
  @Test("presenting another host ends the scene it replaces")
  func anotherHostEndsTheFirstScene() throws {
    let presenter = TerminalPresenter()
    presenter.present(host: host, model: model(for: host))
    let first = try #require(presenter.request?.scene)

    presenter.present(host: other, model: model(for: other))
    let second = try #require(presenter.request?.scene)

    #expect(first !== second)
    #expect(first.isClosed, "the replaced scene still holds its controller")
    #expect(!second.isClosed)
  }

  /// Switching panes inside one presentation is not a presentation change.
  @Test("switching panes inside a presentation does not end the scene")
  func switchingPanesDoesNotEndTheScene() throws {
    let presenter = TerminalPresenter()
    let model = model(for: host)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))
    let scene = try #require(presenter.request?.scene)
    presenter.present(host: host, model: model, pane: pane("w1:p2"))

    #expect(presenter.request?.scene === scene)
    #expect(!scene.isClosed)
  }

  @Test("the attach command names the terminal it was built for")
  func attachCommandNamesTheTerminal() async throws {
    // `FakeControl` produces the same shape `CLIControl` does.
    let control = FakeControl()
    let pane = try #require(await control.snapshot().pane(id: "w1:p2"))
    #expect(control.attachCommand(for: pane) == "herdr terminal attach term_w1p2")
  }

  @Test("a pane herdr sent no terminal id for still gets a command")
  func attachFallsBackToThePaneID() async {
    // Driverr's protocol floor is 17, where `terminal_id` is not required.
    let control = FakeControl()
    let pane = Pane(id: "w9:p9", tabID: "w9:t1", workspaceID: "w9", title: "old herdr")
    #expect(control.attachCommand(for: pane) == "herdr agent attach w9:p9")
  }

  // MARK: - open(hostID:paneID:)

  /// `.ephemeral`, with the host's key trusted so TOFU raises no prompt, and its password
  /// seeded or not depending on whether the case is about a host that would have to ask.
  private func environment(
    hosts: [DriverrCore.Host],
    knowingThePassword: Bool,
    lastPanes: [UUID: LastPaneRecord] = [:],
    stallingTheHandshakeFor stall: Duration? = nil
  ) -> AppEnvironment {
    var environment = AppEnvironment.ephemeral
    // A handshake slow enough that the phase is certainly still an attempt when a test looks.
    // `.ephemeral`'s own stall comes from launch arguments, which a unit test does not have.
    if let stall {
      environment.makeTransport = { FakeSSHTransport(handshakeStall: stall) }
    }
    environment.hostStore = InMemoryHostStore(seeded: hosts)
    environment.knownHostsStore = InMemoryKnownHostsStore(
      seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
    )
    if knowingThePassword {
      environment.passwordStore = InMemoryPasswordStore(seeded: [host.id: "hunter2"])
    }
    // The pane a previous session left this host on, which the calm card's route resumes.
    environment.lastPanes = InMemoryLastPaneStore(seeded: lastPanes)
    return environment
  }

  /// Everything `open` needs, plus somewhere to see what it selected.
  private func configured(
    _ presenter: TerminalPresenter,
    _ environment: AppEnvironment,
    selection: Selection
  ) {
    presenter.configure(
      hostStore: environment.hostStore,
      connections: ConnectionRegistry(notifications: NotificationCenter()),
      environment: environment,
      select: { selection.id = $0 }
    )
  }

  /// A stand-in for `ContentView`'s `selectedHostID`, which `open` writes through a closure so
  /// the list stays its one owner.
  @MainActor
  private final class Selection {
    var id: DriverrCore.Host.ID?
  }

  @Test("open resolves the host id against the store and presents the pane")
  func openPresentsThePane() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host, other], knowingThePassword: true),
      selection: selection
    )

    await presenter.open(hostID: host.id, paneID: "w1:p1")

    let request = try #require(presenter.request)
    #expect(request.host.id == host.id, "the wrong host was resolved out of the store")
    #expect(request.scene.current == .pane(id: "w1:p1"))
    #expect(selection.id == host.id, "the list has to follow the cover")
  }

  @Test("open with no pane id opens the plain shell")
  func openWithoutAPaneOpensTheShell() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )

    await presenter.open(hostID: host.id)

    let request = try #require(presenter.request)
    #expect(request.scene.current == .shell)
    #expect(request.scene.openedAsShell)
  }

  /// A host Driverr would have to ask about is not connected behind the user's back, and
  /// nothing is presented over a connection that is not there. The selection still moves.
  @Test("a host that would have to ask gets the selection and no cover")
  func openAPasswordHostSelectsWithoutPresenting() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: false),
      selection: selection
    )

    await presenter.open(hostID: host.id, paneID: "w1:p1")

    #expect(presenter.request == nil, "a cover over a connection that is not up")
    #expect(selection.id == host.id, "the user has to land on the screen that can ask")
  }

  /// A notification outlives the host it was about, so this is an ordinary case, and nothing
  /// may move on screen for it.
  @Test("an id no host answers to does nothing at all")
  func openAnUnknownHostIsANoOp() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )

    await presenter.open(hostID: other.id, paneID: "w1:p1")

    #expect(presenter.request == nil)
    #expect(selection.id == nil, "an unknown id must not move the selection either")
  }

  // MARK: - The host-only intent a Live Activity needs

  /// A card saying "3 panes need you" is not about a pane, so it goes to the host's tree. The
  /// password is known, so this pins the intent, not a missing credential.
  @Test("a host intent selects the host and presents nothing")
  func aHostIntentSelectsWithoutPresenting() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )

    await presenter.open(hostID: host.id, intent: .host)

    #expect(presenter.request == nil, "a card naming no pane opened one anyway")
    #expect(selection.id == host.id, "the tap has to land on the host's own screen")
  }

  // MARK: - The calm card resumes the last pane

  /// A host request with a record for a pane the host still has opens that pane rather than
  /// its tree.
  ///
  /// The connect is part of the claim: a cold launch from a card has no connection, and a
  /// resume that did not connect would read an empty tree and fall back every time.
  @Test("a host intent resumes the pane the host was last open on")
  func aHostIntentResumesTheLastPane() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(
        hosts: [host], knowingThePassword: true,
        lastPanes: [host.id: record("w1:p1", "term_w1p1")]),
      selection: selection
    )

    await presenter.open(hostID: host.id, intent: .host)

    let request = try #require(presenter.request, "the remembered pane was not reopened")
    #expect(request.host.id == host.id)
    #expect(request.scene.current == .pane(id: "w1:p1"))
    #expect(selection.id == host.id)
  }

  /// A record naming a pane the host no longer reports opens the tree, silently. `w9:p9` is
  /// in no `FakeControl` tree.
  @Test("a remembered pane the host no longer has falls back to the tree")
  func aStaleRecordFallsBackToTheTree() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(
        hosts: [host], knowingThePassword: true,
        lastPanes: [host.id: record("w9:p9", "term_w9p9")]),
      selection: selection
    )

    await presenter.open(hostID: host.id, intent: .host)

    #expect(presenter.request == nil, "a pane the host does not have was opened anyway")
    #expect(selection.id == host.id, "the tap still has to land on the host's own screen")
  }

  /// The record names a pane the host still reports, but herdr hands pane ids out
  /// positionally, so `w1:p1` in a rebuilt session is a terminal the reader was never in. The
  /// witness from before the rebuild is the only difference from `aHostIntentResumesTheLastPane`.
  @Test("a record whose witness has gone stale opens the tree, not the pane")
  func aStaleWitnessFallsBackToTheTree() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(
        hosts: [host], knowingThePassword: true,
        lastPanes: [host.id: record("w1:p1", "term_fromABuildThatIsGone")]),
      selection: selection
    )

    await presenter.open(hostID: host.id, intent: .host)

    #expect(
      presenter.request == nil,
      "a rebuilt session's pane was opened on the strength of a reused id")
    #expect(selection.id == host.id, "the tap still has to land on the host's own screen")
  }

  /// A host that would have to ask does not connect, so there is no tree to check the record
  /// against. The host's screen is where the question can be answered.
  @Test("a host that would have to ask resumes nothing")
  func aHostThatWouldAskResumesNothing() async {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(
        hosts: [host], knowingThePassword: false,
        lastPanes: [host.id: record("w1:p1", "term_w1p1")]),
      selection: selection
    )

    await presenter.open(hostID: host.id, intent: .host)

    #expect(presenter.request == nil)
    #expect(selection.id == host.id)
  }

  /// A request naming a pane opens that pane even when the host's record names another.
  @Test("a pane intent opens the pane it names, not the remembered one")
  func aPaneIntentIgnoresTheRecord() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(
        hosts: [host], knowingThePassword: true,
        lastPanes: [host.id: record("w1:p1", "term_w1p1")]),
      selection: selection
    )

    await presenter.open(hostID: host.id, paneID: "w1:p2")

    let request = try #require(presenter.request)
    #expect(request.scene.current == .pane(id: "w1:p2"))
  }

  /// Presenting a pane is what writes the record, through the one funnel every open in the
  /// app goes through.
  @Test("presenting a pane records it as the host's last, with the pane's witness")
  func presentingAPaneRecordsIt() async throws {
    let presenter = TerminalPresenter()
    let store = InMemoryLastPaneStore()
    let model = await connected(rememberingInto: store)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))

    try await untilLastPane(store, forHost: host.id, is: record("w1:p1", "term_w1p1"))
  }

  /// Somebody whose last act was to open the plain shell was not left in a pane.
  @Test("presenting the plain shell forgets the host's record")
  func presentingTheShellForgetsTheRecord() async throws {
    let presenter = TerminalPresenter()
    let store = InMemoryLastPaneStore(seeded: [host.id: record("w1:p1", "term_w1p1")])
    let model = await connected(rememberingInto: store)

    presenter.present(host: host, model: model)

    try await untilLastPane(store, forHost: host.id, is: nil)
  }

  /// A pane chosen inside a standing scene never touches `TerminalPresenter.present`: the pane
  /// sheet, the keyboard shortcuts and the closed-pane notice call `TerminalSceneModel.select`.
  /// Recording only at the presenter would resume the pane the scene was opened on.
  @Test("switching panes inside the scene records the new one")
  func switchingInsideTheSceneRecordsIt() async throws {
    let presenter = TerminalPresenter()
    let store = InMemoryLastPaneStore()
    let model = await connected(rememberingInto: store)

    presenter.present(host: host, model: model, pane: pane("w1:p1"))
    try await untilLastPane(store, forHost: host.id, is: record("w1:p1", "term_w1p1"))

    // The switcher's own call, not a second presentation.
    try #require(presenter.request).scene.select(.pane(id: "w1:p2"))

    try await untilLastPane(store, forHost: host.id, is: record("w1:p2", "term_w1p2"))
  }

  /// The host route selects the host before it awaits anything, so `HostDetailView` starts its
  /// own connect, and the resume finds the phase `.connecting`, where
  /// `willConnectWithoutAsking()` is `false`. A bare phase check would read that as a failure.
  ///
  /// Deterministic: the handshake is stalled and the test waits for the attempt phase first.
  @Test("a resume waits for a connect that is already in flight")
  func aResumeWaitsForAnInFlightConnect() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    let environment = environment(
      hosts: [host],
      knowingThePassword: true,
      lastPanes: [host.id: record("w1:p1", "term_w1p1")],
      stallingTheHandshakeFor: .milliseconds(400)
    )
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    presenter.configure(
      hostStore: environment.hostStore,
      connections: registry,
      environment: environment,
      select: { selection.id = $0 }
    )
    // `HostDetailView`'s appearance connect, still running when the card's request lands.
    let model = registry.model(for: host, environment: environment)
    let inFlight = Task { await model.connectIfCredentialIsAvailable() }
    while model.phase == .idle { await Task.yield() }
    #expect(
      model.phase == .connecting || model.phase == .authenticating,
      "the stall did not hold the attempt open, so this run proves nothing"
    )

    await presenter.open(hostID: host.id, intent: .host)
    await inFlight.value

    let request = try #require(
      presenter.request, "a connect already in flight was read as a failure to connect")
    #expect(request.scene.current == .pane(id: "w1:p1"))
    #expect(selection.id == host.id)
  }

  /// The same wait on the `.pane` path, where an escalated card's tap and a notification tap
  /// land. Without `settledPhase` the tap would present nothing.
  @Test("a pane intent waits for a connect that is already in flight")
  func aPaneIntentWaitsForAnInFlightConnect() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    let environment = environment(
      hosts: [host],
      knowingThePassword: true,
      stallingTheHandshakeFor: .milliseconds(400)
    )
    let registry = ConnectionRegistry(notifications: NotificationCenter())
    presenter.configure(
      hostStore: environment.hostStore,
      connections: registry,
      environment: environment,
      select: { selection.id = $0 }
    )
    let model = registry.model(for: host, environment: environment)
    let inFlight = Task { await model.connectIfCredentialIsAvailable() }
    while model.phase == .idle { await Task.yield() }
    #expect(
      model.phase == .connecting || model.phase == .authenticating,
      "the stall did not hold the attempt open, so this run proves nothing"
    )

    await presenter.open(hostID: host.id, paneID: "w1:p2")
    await inFlight.value

    let request = try #require(
      presenter.request, "a card's tap presented nothing because a connect was under way")
    #expect(request.scene.current == .pane(id: "w1:p2"))
  }

  /// The write is fire-and-forget (see `ConnectionModel.noteLastPane`), so a test polls.
  private func untilLastPane(
    _ store: InMemoryLastPaneStore, forHost hostID: UUID, is expected: LastPaneRecord?
  ) async throws {
    for _ in 0..<200 {
      if await store.lastPane(forHost: hostID) == expected { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    let actual = await store.lastPane(forHost: hostID)
    Issue.record("last pane was \(actual as Any), expected \(expected as Any)")
  }

  /// Without the dismissal the tap lands on a pane: `PhoneStackPath` returns
  /// `[.host(new), .pane]` while a request stands, and the iPad's detail column shows the scene
  /// over the host screen.
  @Test("a host intent takes down a scene standing on another host")
  func aHostIntentEndsAnotherHostsScene() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host, other], knowingThePassword: true),
      selection: selection
    )
    presenter.present(host: other, model: model(for: other), pane: pane("w1:p1"))
    let standing = try #require(presenter.request)

    await presenter.open(hostID: host.id, intent: .host)

    #expect(presenter.request == nil, "the new host's tree is under the old host's pane")
    #expect(standing.scene.isClosed, "the scene that was standing was left running")
    #expect(selection.id == host.id)
  }

  /// The dismissal does not consult the host id, as in `sidebarDidSelect`. A card that says
  /// three panes need you means "show me that host", even when the reader is in a pane on it.
  @Test("a host intent takes down a scene standing on the same host")
  func aHostIntentEndsThisHostsScene() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )
    presenter.present(host: host, model: model(for: host), pane: pane("w1:p1"))
    let standing = try #require(presenter.request)

    await presenter.open(hostID: host.id, intent: .host)

    #expect(presenter.request == nil, "the pane stayed up over the tree the card asked for")
    #expect(standing.scene.isClosed)
    #expect(selection.id == host.id)
  }

  /// The dismissal happens after the host resolves. A card can outlive its host, and an
  /// unknown id must not end somebody's shell.
  @Test("a host intent for an id no host answers to moves nothing")
  func aHostIntentForAnUnknownHostIsANoOp() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )
    presenter.present(host: host, model: model(for: host), pane: pane("w1:p1"))
    let standing = try #require(presenter.request)

    await presenter.open(hostID: other.id, intent: .host)

    #expect(presenter.request?.scene === standing.scene, "an unknown id ended a live scene")
    #expect(!standing.scene.isClosed)
    #expect(selection.id == nil, "an unknown id must not move the selection either")
  }

  /// A Live Activity tap cold-launches the app: `ActivityURLRouter` records the ask from
  /// `DriverrApp.init`, before any body has run, and `ContentView` drains it after `configure`.
  @Test("a host request made before configure is drained as a selection")
  func aHostRequestBeforeConfigureIsDrained() async {
    let presenter = TerminalPresenter()
    let selection = Selection()

    presenter.requestOpen(hostID: host.id, intent: .host)
    #expect(presenter.pendingOpen == .init(hostID: host.id, intent: .host))

    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )
    await presenter.drainPendingOpen()

    #expect(presenter.request == nil, "the held host request opened a pane")
    #expect(selection.id == host.id, "the held host request was dropped")
    #expect(presenter.pendingOpen == nil)
  }

  /// A `nil` pane id means the plain shell, as a notification tap and `-uiTestingOpen` use it.
  @Test("a pane id and no pane id still make the intents they always did")
  func thePaneShapedInitIsUnchanged() {
    #expect(
      TerminalPresenter.PendingOpen(hostID: host.id, paneID: "w1:p1")
        == .init(hostID: host.id, intent: .pane("w1:p1"))
    )
    #expect(
      TerminalPresenter.PendingOpen(hostID: host.id, paneID: nil)
        == .init(hostID: host.id, intent: .shell)
    )
  }

  // MARK: - A request that arrives before configure

  /// A caller from outside the view tree, such as a notification tap, can arrive before
  /// `ContentView`'s first `.task` configures the presenter. The request has to be held rather
  /// than dropped at `guard let hostStore`.
  @Test("a request made before configure is honoured once it is")
  func aRequestBeforeConfigureIsHonouredAfterIt() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()

    await presenter.open(hostID: host.id, paneID: "w1:p1")
    #expect(presenter.request == nil, "nothing can be presented before there is a store")

    configured(
      presenter,
      environment(hosts: [host, other], knowingThePassword: true),
      selection: selection
    )
    await presenter.drainPendingOpen()

    let request = try #require(presenter.request, "the held request was dropped")
    #expect(request.host.id == host.id)
    #expect(request.scene.current == .pane(id: "w1:p1"))
    #expect(selection.id == host.id, "the list has to follow the cover")
  }

  /// One slot and one screen, so an older request is a stale answer to the same question.
  ///
  /// Both requests name the same host: `environment(hosts:)` seeds only `host`'s key and
  /// password, so with two hosts the first would be unpresentable anyway.
  @Test("two requests before configure: the last one wins")
  func theLastRequestBeforeConfigureWins() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()

    presenter.requestOpen(hostID: host.id, paneID: "w1:p1")
    presenter.requestOpen(hostID: host.id, paneID: "w1:p2")

    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )
    await presenter.drainPendingOpen()

    let request = try #require(presenter.request)
    #expect(request.scene.current == .pane(id: "w1:p2"), "an older request answered last")
  }

  /// Drained once, and not re-presented after a dismiss.
  ///
  /// This does not pin clearing the slot before the await: it awaits the first drain to
  /// completion, so clearing after would pass too. That race needs a connect suspended half-way
  /// and is documented on `drainPendingOpen`.
  @Test("the pending request is drained once")
  func thePendingRequestIsDrainedOnce() async throws {
    let presenter = TerminalPresenter()
    let selection = Selection()

    presenter.requestOpen(hostID: host.id, paneID: "w1:p1")
    configured(
      presenter,
      environment(hosts: [host], knowingThePassword: true),
      selection: selection
    )
    await presenter.drainPendingOpen()
    _ = try #require(presenter.request, "the first drain has to present something")

    presenter.dismiss()
    await presenter.drainPendingOpen()

    #expect(presenter.request == nil, "a drained request came back after a dismiss")
  }
}

/// What a launch starts on: `ContentView.restoredSelection`, the launch-time counterpart of
/// reaching a host by id through `TerminalPresenter.open`.
@MainActor
@Suite("ContentView.restoredSelection")
struct RestoredSelectionTests {
  private let workbox = DriverrCore.Host(name: "workbox", hostname: "10.1.0.9", username: "carson")
  private let edge = DriverrCore.Host(name: "edge-01", hostname: "10.1.0.99", username: "root")

  @Test("a stored host that is still in the list is what the launch starts on")
  func storedHostIsRestored() {
    #expect(
      ContentView.restoredSelection(
        stored: workbox.id.uuidString,
        hosts: [edge, workbox]
      ) == workbox.id
    )
  }

  /// The detail column would fall through to the placeholder and look right, while the sidebar
  /// holds a highlight for a row that is gone.
  @Test("a host deleted since the last launch is dropped")
  func deletedHostIsDropped() {
    #expect(ContentView.restoredSelection(stored: workbox.id.uuidString, hosts: [edge]) == nil)
    #expect(ContentView.restoredSelection(stored: workbox.id.uuidString, hosts: []) == nil)
  }

  @Test("nothing stored, and anything that is not a host id, start on the list")
  func nothingStoredStartsOnTheList() {
    #expect(ContentView.restoredSelection(stored: nil, hosts: [workbox]) == nil)
    #expect(ContentView.restoredSelection(stored: "", hosts: [workbox]) == nil)
    #expect(ContentView.restoredSelection(stored: "not-a-uuid", hosts: [workbox]) == nil)
  }
}

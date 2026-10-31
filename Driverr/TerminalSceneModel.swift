import DriverrCore
import DriverrHerdr
import DriverrTerm
import Foundation
import Observation
import UIKit

/// One host's terminal scene: the presentation, and the pane it is showing.
///
/// Presented once per host, with the current target a value inside it, so switching panes
/// never rebuilds the presentation. See `TerminalPresenter`.
///
/// **Only the current target, on its terminal surface, holds a controller.** A controller
/// resizes the pane's PTY on the user's desk and refuses every other client while held, so
/// holding several would reflow and lock several panes. Other `WarmPaneSet` members, and
/// the current pane while its chat side is showing, hold read-only observers: same cost
/// per byte, no resize, no lock. A warm pane already has an emulator, so it paints at once
/// when chosen. See `openSurface(for:)`.
///
/// Nothing here presents anything. `ContentView` pushes the scene on the phone and draws it
/// in the detail column on iPad.
@MainActor
@Observable
final class TerminalSceneModel {
  /// What a warm entry is holding open on the host.
  enum Role: Equatable {
    /// herdr's one attach token for this pane. Exclusive, and it reflows the pane on the
    /// desk while held.
    case controller
    /// A read-only `observe` stream. Invisible to the desk and cannot be typed into.
    case observer
    /// Our own pty: the plain shell, or a pane on a herdr too old to report a terminal id.
    case local
    /// herdr ended the session. The last frame stays on screen, which says more than a
    /// black rectangle.
    case ended
  }

  /// One live terminal in the scene. All are in the view hierarchy at once. Only the
  /// current one is visible, hit-testable, and allowed the keyboard.
  struct Entry: Identifiable {
    /// Unique per session, not per target, so swapping an observer for a controller gives
    /// SwiftUI a new identity. A reused view would keep rendering the old stream.
    let id: Int
    let target: TerminalTarget
    let session: TerminalSession
    var role: Role
    fileprivate var attachment: Attachment
    fileprivate var pump: Task<Void, Never>?
  }

  /// How a target's bytes are being got, and therefore how to let go of it.
  fileprivate enum Attachment {
    case controller(any PaneBridge)
    case observer(any PaneObserver)
    /// A pty; `TerminalSession.close()` closes the channel itself.
    case local
  }

  /// Something the scene has to say about the current target. One value, so two cannot be
  /// on screen at once.
  enum Notice: Equatable {
    /// Another client already controls this pane. Offers Take over, the one deliberate
    /// use of `--takeover`.
    case refused
    /// We held the controller and another client took it. Offers Take back.
    case takenOver
    /// The pane ended, or herdr ended the session for a reason this build does not know.
    case closed
    case failed(AppError)
    /// The host's link went away and Driverr is getting it back.
    ///
    /// This and the two below are about the connection, so they outrank anything about a
    /// pane. They share the enum because there is one banner slot, and "pane closed" over
    /// "Reconnecting…" describes one event twice.
    case reconnecting
    /// Reconnecting needs a password, asked for inline, because the detail column must not
    /// present (CLAUDE.md). Nothing retries on its own, because a backoff without the
    /// credential can only fail.
    case needsPassword
    /// `ReconnectSchedule` ran to its deadline. A tap is what is left.
    case disconnected
  }

  let host: DriverrCore.Host
  let model: ConnectionModel
  /// Whether iOS is suppressing the software keyboard for a hardware one. Shared by every
  /// entry, because only the current entry's view becomes first responder and writes it.
  ///
  /// The idiom is mapped from UIKit here, because `DriverrTerm` does not import UIKit.
  /// Only `.pad` changes the answer; everything else takes the phone's case.
  let keyboardNotice = KeyboardNoticeModel(
    idiom: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone,
    // See `AppEnvironment.keepsKeyboardAccessoryRow` for why UI tests keep the key row.
    keepsAccessoryRowWithHardwareKeyboard: AppEnvironment.keepsKeyboardAccessoryRow
  )
  /// Whether to say a Copy just happened. Shared for `keyboardNotice`'s reason: only the
  /// terminal on screen shows an edit menu.
  let copyNotice = TerminalCopyNotice()

  /// The current target and the panes kept warm around it.
  private(set) var warm = WarmPaneSet()
  /// Every live terminal, in no order. The view puts the current one on top.
  private(set) var entries: [Entry] = []
  /// Bumped whenever the visible terminal changes, so the new current view asks for the
  /// keyboard. Only the current view answers; see `DriverrTerminalUIView.wantsKeyboardFocus`.
  private(set) var focusRequest = 0
  /// The current pane's own controls, rebuilt whenever the current target changes so the
  /// toolbar menu always acts on the pane being looked at.
  private(set) var actions: PaneActionsModel?

  private let initialTarget: TerminalTarget
  private var notices: [TerminalTarget: Notice] = [:]
  /// How many times each target's stream has ended with no `terminal.closed` record and
  /// been reattached with no frame painted since. `TerminalEndDisposition` bounds the
  /// reattach with it.
  ///
  /// Reset by a frame and by `select`, so it counts consecutive failures. A link that drops
  /// hourly is always reattached; a herdr that kills every control stream gets one attempt
  /// and then a sentence.
  private var reattachAttempts: [TerminalTarget: Int] = [:]
  /// Targets whose reattach is in flight. The screen reads it only to stay quiet, so
  /// "The session ended." is not printed over the last frame during the round trip.
  private(set) var reattaching: Set<TerminalTarget> = []
  /// Kept terminals being retried until their new shell answers. See `awaitRestart(of:generation:)`.
  private var restarts: [TerminalTarget: Task<Void, Never>] = [:]
  /// Controllers that are open but have not painted yet. The observer they will replace
  /// is still on screen.
  private var pending: [TerminalTarget: Entry] = [:]
  /// The panes the tree held when a split was asked for, and how many more snapshots the
  /// split has to produce a new pane. `nil` when no split is waiting.
  private var pendingSplit: Set<String>?
  private var pendingSplitSnapshots = 0
  /// Keystrokes typed at a pane whose controller is not up yet. herdr drops an observer's
  /// input silently, and the promotion gap is when someone who just chose the pane types.
  private var held: [TerminalTarget: [UInt8]] = [:]
  private var nextEntryID = 0
  /// The size to open the next stream at: the phone's real size. The desk reflow is
  /// accepted for the one pane being typed into.
  private var viewportSize = TerminalSize(columns: 80, rows: 24)
  /// Whether `viewportSize` came from a terminal view, not the default above. See
  /// `measuredSize(for:)`.
  private var viewportIsMeasured = false

  /// Everything `select`, `takeOver` and `close` start, serialised.
  ///
  /// A chain because the steps must run in order (scroll home, open the replacement
  /// observer, then hand the controller back), and two quick taps must not interleave two
  /// switches over one warm set.
  private var work: Task<Void, Never> = Task {}
  private var workGeneration = 0
  /// How long one step may run before the chain stops waiting for it; see `enqueue`.
  /// Injected so a test can assert the recovery quickly.
  private let stepDeadline: Duration
  /// How long a controller's session holds its first size. Injected, like `stepDeadline`,
  /// because a core attach waits on it.
  private let openSettlingWindow: Duration
  /// How long a core attach may wait for a terminal view to report a size.
  private let coreSizeDeadline: Duration

  /// How often a lost terminal is tried, and how many times. About a minute more than the
  /// core's own backoff reaches, so a slow recovery is still caught.
  private static let restartInterval: Duration = .seconds(2)
  private static let restartAttempts = 60

  /// The same as `PaneComposerCopy.sendDeadline`: how long a herdr command that is not
  /// coming back may hold the app. Generous on purpose, because abandoning a slow open
  /// leaves the scene half-built, while abandoning a dead one costs nothing.
  static let defaultStepDeadline: Duration = .seconds(12)

  /// Which connection the live streams belong to, bumped on every loss.
  ///
  /// When the link drops, every stream's end arrives whenever the pool gets to it, which can
  /// be after the reconnect succeeded. `model.phase` is `.connected` again by then and
  /// cannot tell the old link from the new, so `sessionEnded` checks this instead, or it
  /// marks a pane closed that just came back.
  private var linkGeneration = 0

  /// Panes herdr granted this scene a controller on and that it has not handed back,
  /// tagged with the link the grant happened on.
  ///
  /// **A lost link does not hand the token back.** A phone usually loses a link without a
  /// FIN (suspension, radio loss, Wi-Fi handoff, NAT rebind), so on the host the sshd
  /// session and its `herdr terminal session control` stay up holding the attach token.
  /// Stock sshd reaps it after about two hours. Driverr reconnects long before then and
  /// herdr refuses the new controller, because our old one is still there.
  ///
  /// So a refusal against a claim from an earlier link is our own ghost and is taken
  /// over. A refusal with no claim is another device and gets the take-over prompt. Requiring
  /// an earlier link keeps a double-open on one link a refusal.
  ///
  /// Not persisted: after a force-quit nothing in this process saw the controller open, so
  /// the prompt is honest.
  ///
  /// Never expired, which leaves a known residue. If sshd reaps the orphan and another
  /// device takes the pane before this scene reopens it, that refusal is taken over without
  /// asking. It needs the scene to stay disconnected across the whole reap, and the evicted
  /// device still gets its Take back banner. A claim is forfeited only on herdr's word, so a
  /// controller stream killed outright also leaves its claim; that is harmless on the same
  /// link. Nothing can close this by cause: herdr has no client-management API and its
  /// refusal names no owner, sshd's reap time is per host, and limiting a claim to the next
  /// link would prompt on a real orphan when the reader switched panes during the outage.
  private var unreleasedControllers: [TerminalTarget: Int] = [:]

  /// The memory-warning observer, removed when this scene goes. See
  /// `ConnectionRegistry.memoryWarnings` for the `nonisolated(unsafe)` and the block observer.
  @ObservationIgnored private nonisolated(unsafe) var memoryWarnings: (any NSObjectProtocol)?

  /// Where memory warnings are listened for. Injectable for tests, like
  /// `ConnectionRegistry`'s.
  @ObservationIgnored private let notifications: NotificationCenter

  /// How a backoff step waits. See `ReconnectWaiter`.
  private let wait: ReconnectWaiter
  /// What the scene has to say about the connection, which outranks anything about a pane.
  /// `nil` whenever the link is up.
  private var connectionNotice: Notice?
  /// Whether the password last typed into the reconnect bar was refused, so the bar can
  /// tell a refusal from a first ask.
  private(set) var passwordWasRefused = false
  /// Whether the pane this scene shows was closed. Held here because
  /// `PaneActionsModel.didClose` does not survive `rebuildActions`. Cleared by `select`.
  private(set) var paneWasClosed = false
  /// The reconnect in flight: the backoff, or one attempt from a prompt or a tap.
  private var reconnectWork: Task<Void, Never>?
  /// Whether the presentation has ended. A loss arriving before this object is released
  /// must not start a reconnect nobody will see.
  ///
  /// Readable so `TerminalPresenterTests` can assert that `TerminalPresenter.dismiss()`
  /// closes the scene, not a view's `onDisappear`.
  private(set) var isClosed = false

  init(
    host: DriverrCore.Host,
    model: ConnectionModel,
    initialTarget: TerminalTarget,
    wait: @escaping ReconnectWaiter = { try? await Task.sleep(for: $0) },
    stepDeadline: Duration = TerminalSceneModel.defaultStepDeadline,
    openSettlingWindow: Duration = TerminalSession.defaultOpenSettlingWindow,
    coreSizeDeadline: Duration = DeferredPaneBridge.defaultSizeDeadline,
    notifications: NotificationCenter = .default
  ) {
    self.host = host
    self.model = model
    self.initialTarget = initialTarget
    self.wait = wait
    self.stepDeadline = stepDeadline
    self.openSettlingWindow = openSettlingWindow
    self.coreSizeDeadline = coreSizeDeadline
    self.notifications = notifications
    memoryWarnings = notifications.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in self?.evictForMemoryWarning() }
    }
  }

  deinit {
    if let memoryWarnings { notifications.removeObserver(memoryWarnings) }
  }

  // MARK: - What the screen reads

  var current: TerminalTarget { warm.current ?? initialTarget }
  var currentSession: TerminalSession? { entry(for: current)?.session }
  var currentRole: Role? { entry(for: current)?.role }
  var currentPane: Pane? {
    guard case .pane(let id) = current else { return nil }
    return pane(id: id)
  }
  /// The notice to show. The connection outranks the pane: while the link is down every
  /// stream has gone, so nothing true can be said about a pane.
  var notice: Notice? { connectionNotice ?? notices[current] }

  /// Whether the current pane is being reattached after its stream ended without a word
  /// from herdr. It only keeps `statusBanner` quiet; the last frame stays up.
  ///
  /// **Two clauses.** `reattaching` clears when `openSurface` returns, which is when the new
  /// controller lands in `pending`, not when it paints. Until then the current entry is
  /// still `.ended`, and the banner would say "The session ended." over the last frame. The
  /// second clause covers that window, and also `retryOpen`, which never sets
  /// `reattaching`. `controllerPainted`, `demote` and `drop` empty `pending`.
  var isReattaching: Bool {
    reattaching.contains(current)
      || (pending[current] != nil && entry(for: current)?.role == .ended)
  }
  /// Nothing to show yet and nothing to say: the cold-open beat. Every target has its own
  /// terminal view, so no other pane's frame can show here.
  ///
  /// Terminal side only. On the chat side a pane may hold nothing at all (an old herdr has
  /// no observer to open), and a spinner there would never end.
  var isOpening: Bool { currentSession == nil && notice == nil && surface == .terminal }
  var openedAsShell: Bool { initialTarget == .shell }

  /// Whether `target` has two surfaces to switch between: a pane with an agent. A shell
  /// pane opens straight into its terminal.
  func hasChatSurface(for target: TerminalTarget) -> Bool {
    guard case .pane(let id) = target else { return false }
    return pane(id: id)?.agent != nil
  }

  /// Whether the current target gets the `Chat | Terminal` segment.
  var showsSurfaceSegment: Bool { hasChatSurface(for: current) }

  /// Which surface `target` is showing, and therefore what it holds on the host.
  ///
  /// The pane's remembered choice first (`PaneSurfaceMemory`), so it survives a pane switch
  /// and leaving and reopening the pane. A pane never switched opens on chat, so reading a blocked agent's
  /// question needs no terminal. Anything without a chat answers `.terminal`.
  ///
  /// Resolved here, not in `TerminalScreen`, because it decides whether a target holds the
  /// exclusive attach token or an observer. See `openSurface(for:)`.
  func surface(for target: TerminalTarget) -> PaneSurface {
    guard case .pane(let id) = target, hasChatSurface(for: target) else { return .terminal }
    return model.surfaces.surface(for: id) ?? .chat
  }

  /// The surface the current target is showing.
  var surface: PaneSurface { surface(for: current) }

  /// The title bar's subject: whatever the pane calls itself, or the host for a shell.
  ///
  /// The chat side never shows the OSC title, which names whatever program last wrote one
  /// (`vim`, a `cwd`) and is not on a transcript screen. The terminal side puts it first,
  /// because there it is the most specific true name.
  var title: String {
    if surface == .chat {
      return currentPane?.title ?? host.displayName
    }
    return currentSession?.title ?? currentPane?.title ?? host.displayName
  }

  /// The line under the title: which host this is on, since pane titles look alike across
  /// machines. `nil` when it would repeat the title.
  var subtitle: String? {
    title == host.displayName ? nil : host.displayName
  }

  /// The switcher's model for this scene. The toolbar badge, the pane sheet and its
  /// thumbnails all read it, so they agree on which panes and in what order. Pure, and
  /// tested in `swift test`.
  var strip: PaneStripModel {
    PaneStripModel(
      tree: model.session?.tree ?? .empty,
      current: current,
      openedAsShell: openedAsShell
    )
  }

  /// The entries in drawing order, current last so it is on top.
  var orderedEntries: [Entry] {
    entries.filter { $0.target != current } + entries.filter { $0.target == current }
  }

  func session(for target: TerminalTarget) -> TerminalSession? { entry(for: target)?.session }
  func role(for target: TerminalTarget) -> Role? { entry(for: target)?.role }

  /// The last `count` rows a warm target shows, or `nil` when the scene holds none for it.
  ///
  /// The free half of the pane sheet's thumbnails: every warm entry keeps a laid-out
  /// terminal view, so the picture already exists. `nil`, not empty, because a cold pane's
  /// tile comes from a batched `pane read` instead.
  func visibleLines(for target: TerminalTarget, last count: Int) -> [String]? {
    entry(for: target)?.session.visibleLines(last: count)
  }

  // MARK: - What the screen presents

  /// Whether the pane sheet is up.
  ///
  /// **On the scene, not `TerminalScreen`.** On regular width the scene sits in the split
  /// view's detail column, which must not present (CLAUDE.md). The sheets attach at the
  /// root instead (`TerminalSceneSheets`), which has to read this state.
  private(set) var isShowingPaneSheet = false
  /// Whether the Settings sheet the pane menu opens is up. Here for the reason above.
  private(set) var isShowingSettings = false
  /// Whether the system Photos picker is up. `PhotosPicker` presents, so it attaches at the
  /// root beside `TerminalSceneSheets`, not in the composer bar, for the reason above.
  private(set) var isShowingPhotoPicker = false

  /// The composer asked for an image.
  ///
  /// `PhotosPicker` runs out of process, where XCUITest cannot drive it. A launch with
  /// `-uiTestingPickedImage` skips to the bytes and exercises everything after the pick.
  func requestImageAttachment() {
    if let seeded = AppEnvironment.seededPickedImage {
      attachPickedImage(seeded)
      return
    }
    isShowingPhotoPicker = true
  }

  /// The picker closed, chosen from or not.
  func hidePhotoPicker() {
    isShowingPhotoPicker = false
  }

  /// Routes picked bytes to the current pane's composer, through the composer cache, so the
  /// image has the same per-pane lifetime as staged text.
  func attachPickedImage(_ data: Data) {
    isShowingPhotoPicker = false
    // No current pane means the pane went away while the picker was up. The bytes are
    // dropped silently, since no screen the reader is on would suit a notice.
    guard let pane = currentPane else { return }
    model.composers?.model(for: pane).attachment.attach(data)
  }

  /// Built when the pane sheet first opens, so nothing polls for a sheet nobody asked for.
  /// Kept afterwards, because discarding it mid-dismissal pulls the tiles from under the
  /// animation.
  private(set) var paneThumbnails: PaneThumbnailModel?

  /// Opens the pane sheet, building its thumbnails the first time and starting their reads.
  func showPaneSheet() {
    if paneThumbnails == nil {
      paneThumbnails = PaneThumbnailModel(
        // Resolved per read and only while the link is up, so an outage does not run
        // `pane read` against an absent host for every tile.
        control: { [model] in model.liveHerdr },
        // Weak, because the scene holds this model.
        targets: { [weak self] in self?.strip.targets ?? [] },
        // Warm tiles come from their live emulators; see `visibleLines(for:last:)`.
        warmLines: { [weak self] target in
          self?.visibleLines(for: target, last: PaneThumbnailModel.lineCount)
        }
      )
    }
    paneThumbnails?.open()
    isShowingPaneSheet = true
  }

  /// Closes the pane sheet, stops its reads, and asks the terminal for the keyboard back.
  /// Idempotent, because Done and the sheet's own dismissal both arrive for one dismissal.
  func hidePaneSheet() {
    guard isShowingPaneSheet else { return }
    isShowingPaneSheet = false
    paneThumbnails?.close()
    focusRequest += 1
  }

  /// Opens Settings over the scene.
  func showSettings() {
    isShowingSettings = true
  }

  /// Closes Settings and asks the terminal for the keyboard back, or the terminal looks
  /// focused and swallows every keystroke.
  func hideSettings() {
    guard isShowingSettings else { return }
    isShowingSettings = false
    focusRequest += 1
  }

  // MARK: - Driving it

  /// Opens the scene on the target it was presented for. Safe to call again, because a
  /// `.task` re-runs on identity changes.
  func start() {
    // Registered here, not in `init`, so a scene built but never shown cannot take the
    // reconnect from the one that is. Weak, so a dismissed scene stops reconnecting.
    model.onLoss = { [weak self] in self?.connectionLost() }
    guard warm.current == nil else { return }
    select(initialTarget)
  }

  /// Makes `target` the one being looked at.
  ///
  /// **Synchronous up to the paint.** The warm set moves and the view switches before this
  /// returns, so an observed pane shows in the tap's frame. Host work is queued behind it.
  func select(_ target: TerminalTarget) {
    guard target != warm.current else { return }

    // Bank the leaving pane's scroll position before the warm set forgets it, and carry its
    // size forward for the next stream.
    if let leaving = warm.current, let session = session(for: leaving) {
      warm.setScrolledRows(session.scrolledRows, for: leaving)
      if let size = session.reportedSize {
        viewportSize = size
        viewportIsMeasured = true
      }
    }

    // Recorded here too, because in-scene switches (the sheet, keyboard shortcuts, the
    // closed-pane jump) never go through `TerminalPresenter.present`.
    model.noteLastPane(for: target)

    let selection = warm.select(target)
    notices[target] = nil
    // A deliberate arrival resets the reattach budget.
    reattachAttempts[target] = nil
    // A new pane has not been closed, whatever happened to the last one.
    paneWasClosed = false
    focusRequest += 1
    rebuildActions(for: target)
    enqueue(on: target) { [weak self] in await self?.reconcile(selection, to: target) }
  }

  /// Tries the current target again after a failed open. Most failures are transient.
  ///
  /// `select` returns early for the current target, so this clears the notice and queues
  /// the open itself.
  func retryOpen() {
    guard !isClosed, let selection = warm.current else { return }
    let target = selection
    notices[target] = nil
    // Retry restores the reattach budget, or Retry after a give-up could only fail again.
    reattachAttempts[target] = nil
    focusRequest += 1
    enqueue(on: target) { [weak self] in await self?.openSurface(for: target) }
  }

  /// The `Chat | Terminal` segment moved, for the current target.
  ///
  /// **What is on screen is what the pane holds on the host.** The terminal side promotes
  /// to a controller and the chat side hands it back at once. Holding it "in case" would
  /// keep the pane locked and reflowed on the desk while someone only reads.
  func show(_ surface: PaneSurface) {
    let target = current
    guard self.surface(for: target) != surface else { return }
    // Remembered on the connection, so it outlives this scene.
    if case .pane(let id) = target { model.surfaces.remember(surface, for: id) }
    // Before `start()` nothing is open, and a scene never shown must take nothing on the
    // host. `start()` opens whatever this recorded.
    guard warm.current != nil else { return }
    enqueue(on: target) { [weak self] in await self?.openSurface(for: target) }
  }

  /// Reply asked for the composer, and it has not been served yet.
  ///
  /// A one-shot, consumed rather than observed: a switch to Terminal and back rebuilds the
  /// bar, and a bar that focused on every appearance would raise the keyboard every time.
  private(set) var wantsComposerFocus = false

  /// Asks for the composer. See `wantsComposerFocus`.
  func focusComposer() {
    wantsComposerFocus = true
  }

  /// Answers once, and then stops answering.
  func takeComposerFocusRequest() -> Bool {
    defer { wantsComposerFocus = false }
    return wantsComposerFocus
  }

  /// Evicts whoever holds this pane and takes the controller: Take over after `.refused`,
  /// Take back after `.takenOver`.
  ///
  /// Never automatic, because the other client is most likely the user at their own desk.
  func takeOver() {
    let target = current
    notices[target] = nil
    enqueue(on: target) { [weak self] in await self?.openController(for: target, takeover: true) }
  }

  /// Splits the current pane and goes to whatever the split made.
  ///
  /// **The next snapshot identifies the new pane, not the command.** `pane split` returns no
  /// id, so the ids present at the tap are banked and the first new one to appear is
  /// adopted. A refresh is asked for at once rather than waiting for the poll.
  ///
  /// Only from a pane; the plain shell is not one.
  ///
  /// Known limitation: if the split step is abandoned, Retry on its `Notice.failed` calls
  /// `retryOpen()`, which re-opens the surface and does not split again. `Notice` cannot
  /// tell the two apart.
  func newPane() {
    guard case .pane(let paneID) = current, let herdr = model.herdr else { return }
    let target = current
    pendingSplit = Set(model.session?.tree.allPanes.map(\.id) ?? [])
    pendingSplitSnapshots = Self.splitAdoptionSnapshots
    enqueue(on: target) { [weak self] in
      guard let self else { return }
      do {
        try await herdr.perform(.split(.right), on: paneID)
      } catch {
        // No split, no pane to adopt. A bank left set would jump to the next pane the user
        // opens at their desk.
        pendingSplit = nil
        return
      }
      await model.session?.refresh()
      adoptNewPane()
    }
  }

  /// Goes to the pane a `newPane()` made, once a snapshot lists it.
  ///
  /// Called on every tree change, because herdr can answer `pane split` before the pane is
  /// in a snapshot. After `splitAdoptionSnapshots` trees with nothing new the bank is
  /// dropped, so a split that did nothing cannot hijack the user's next desk pane.
  func adoptNewPane() {
    guard let known = pendingSplit else { return }
    guard let new = model.session?.tree.allPanes.first(where: { !known.contains($0.id) })
    else {
      pendingSplitSnapshots -= 1
      if pendingSplitSnapshots <= 0 { pendingSplit = nil }
      return
    }
    pendingSplit = nil
    select(.pane(id: new.id))
  }

  /// How many snapshots a split gets to produce its pane before the scene stops watching.
  private static let splitAdoptionSnapshots = 3

  /// Leaving the scene: the controller and every observer go back, and the shell ends.
  ///
  /// **The hand-back must outlive this object.** `close()` only queues the work, and
  /// `TerminalPresenter.dismiss()` drops the scene in the same turn, so it deinits within
  /// milliseconds. A `[weak self]` body would find `nil` and release nothing. Nothing else
  /// closes the channel (`NIOSSHTransport` has no `deinit` teardown by design), so the remote
  /// `herdr terminal session control` would keep the attach token and refuse the next open.
  /// So the hand-back goes through the `static` `handBack(_:)`, and the claims are forfeited
  /// here synchronously.
  ///
  /// It also lowers the sheet flags, so a scene cannot come back with a sheet raised, and
  /// stops the thumbnail poll. The flags are written directly, not through
  /// `hidePaneSheet()`/`hideSettings()`, which would ask a released terminal for the
  /// keyboard.
  func close() {
    isClosed = true
    isShowingPaneSheet = false
    isShowingSettings = false
    paneThumbnails?.close()
    reconnectWork?.cancel()
    reconnectWork = nil
    stopAwaitingRestarts()
    let all = entries
    let opening = Array(pending.values)
    entries = []
    pending = [:]
    held = [:]
    for entry in all + opening where entry.role == .controller {
      unreleasedControllers[entry.target] = nil
    }
    // **Bounded per entry, not once for the whole loop.** One deadline around the loop would
    // let a first hung `handBack` starve every entry behind it, and their tokens would never
    // return. Chained onto `work` by hand, like `enqueue`, so it still queues behind the
    // scene's work. The full `stepDeadline` costs the user nothing, because the scene has
    // already left the screen.
    let handedBack = all + opening
    let previous = work
    workGeneration += 1
    work = Task { @MainActor [stepDeadline] in
      await previous.value
      for entry in handedBack {
        await Self.bounded({ await Self.handBack(entry) }, by: stepDeadline)
      }
    }
  }

  /// A memory warning releases every warm target except the current one, which is never
  /// interrupted. Targets go through `drop(_:)`, which already spares a non-current
  /// `.shell`, because closing its pty would kill what runs in it.
  func evictForMemoryWarning() {
    let dropped = warm.evictObservers()
    guard !dropped.isEmpty else { return }
    // Untargeted: no user is waiting on this, and a stuck release leaves no stuck UI.
    enqueue { [weak self] in
      for target in dropped { await self?.drop(target) }
    }
  }

  /// Waits for everything the calls above started, including the reconnect. For
  /// `DriverrTests`, where the ordering of wire commands can be checked.
  ///
  /// Every await is bounded (`ConnectionModel.setUpDeadline`,
  /// `ConnectionCoordinator.withHandshakeDeadline`, `stepDeadline`), but bounded is not
  /// quick: a full backoff against a stalling host takes the schedule plus a set-up deadline
  /// per attempt, so tests inject both.
  func settle() async {
    while true {
      let generation = workGeneration
      await work.value
      // The reconnect runs on its own task, not in the chain, because it sleeps through a
      // backoff and leaving the scene must not queue behind that. Its re-open goes through
      // the chain, so the loop catches it.
      await reconnectWork?.value
      for restart in Array(restarts.values) { await restart.value }
      if generation == workGeneration { return }
    }
  }

  // MARK: - The switch itself

  private func reconcile(_ selection: WarmPaneSet.Selection, to target: TerminalTarget) async {
    if let demoted = selection.demoted { await demote(demoted) }
    if let evicted = selection.evicted { await drop(evicted) }
    await openSurface(for: target)
  }

  /// Opens what the surface on screen entitles `target` to, and hands back the rest: a
  /// controller for the terminal side, an observer for the chat side. See the type's note.
  ///
  /// - Parameter automatic: whether the scene opened this itself (the reattach) rather than
  ///   the user. An automatic open is **silent about failing**. Its usual cause is a link
  ///   that died during suspension with the loss not yet recorded, and `openPaneBridge`
  ///   would mark the connection `.failed`, replacing the loss so the reconnect never
  ///   starts. `aReattachReclaimsOurOwnController(order: .streamEndFirst)` catches it.
  ///
  /// **A warm core pane comes back watching.** `surface(for:)` says what a pane shows when
  /// looked at, not that anyone is, and a core's typing viewer takes the terminal's size as it
  /// opens. One crash ends every warm pane at once, so each would take the size and hold it.
  private func openSurface(for target: TerminalTarget, automatic: Bool = false) async {
    if automatic, target != current, case .pane(let id) = target, CorePaneID.isCore(id) {
      await openObserver(for: target)
      return
    }
    switch surface(for: target) {
    case .terminal: await openController(for: target, takeover: false, automatic: automatic)
    case .chat: await readOnly(target)
    }
  }

  /// The pane is only being read: give the desk back, and keep watching it.
  ///
  /// Each step is a no-op unless it has work. `demote` opens the replacement observer
  /// before releasing a controller, so the pane is never unread. `openObserver` only has
  /// work for a target opening straight onto its chat. The emulator survives.
  ///
  /// The exception is a pane on a herdr too old to report a terminal id, reached through a
  /// pty running `agent attach`. That holds the pane like a controller with no read-only
  /// fallback, so it is ended. `drop` refuses `.shell`, which has no chat anyway.
  private func readOnly(_ target: TerminalTarget) async {
    if entry(for: target)?.role == .local { await drop(target) }
    await demote(target)
    await openObserver(for: target)
  }

  /// Opens the read-only half for a target that has nothing open.
  ///
  /// Silent about failure, like `ConnectionModel.observePane`: the reader did not ask for an
  /// observer, and an unobservable pane still has a conversation to read.
  private func openObserver(for target: TerminalTarget) async {
    guard !isClosed else { return }
    // **`.ended` counts as nothing open.** Otherwise a chat pane whose observe stream ended
    // could never reopen one.
    guard entry(for: target).map({ $0.role == .ended }) ?? true, pending[target] == nil
    else { return }
    guard let observer = await makeObserver(for: target) else { return }
    await install(observer)
  }

  /// A read-only stream on a pane, wrapped as an entry ready to install.
  ///
  /// `nil` when there is nothing to observe: the plain shell, a pane on an old herdr, a
  /// refused stream, or a scene that has been left.
  ///
  /// The `isClosed` guard matters because `demote` calls this directly and an abandoned
  /// step can outlive `close()`, which has already snapshotted `entries`. A stream opened
  /// after that would never be handed back.
  private func makeObserver(for target: TerminalTarget) async -> Entry? {
    guard !isClosed else { return nil }
    guard case .pane(let paneID) = target, let terminalID = terminalID(for: paneID),
      let observer = await model.observePane(
        paneID: paneID, terminalID: terminalID, size: viewportSize)
    else { return nil }
    // Checked again after the await. The stream is open on the host by now, so it is
    // released, not dropped.
    guard !isClosed else {
      await observer.release()
      return nil
    }
    let (feed, pump) = observerFeed(observer: observer, target: target)
    let session = TerminalSession(feed: feed)
    session.start()
    return Entry(
      id: nextID(),
      target: target,
      session: session,
      role: .observer,
      attachment: .observer(observer),
      pump: pump
    )
  }

  /// Gives a pane's desk back: scroll it home, warm it as an observer, and only then hand
  /// the controller over. Called when the pane is left (`reconcile`) or only read
  /// (`readOnly`).
  private func demote(_ target: TerminalTarget) async {
    // A controller that never painted is unwanted; release its token.
    if let opening = pending.removeValue(forKey: target) {
      await release(opening)
    }

    guard let index = entries.firstIndex(where: { $0.target == target }) else { return }
    let leaving = entries[index]
    guard case .controller(let bridge) = leaving.attachment else {
      // A pty or an ended session holds nothing away from anybody.
      return
    }

    // Leave the desk as the user found it, because a phone drag scrolls their view of the
    // pane. **Awaited**, because a scroll that lands after the release reaches nobody.
    // `scrolledRows` counts only scrolls herdr answered with a frame, so an alt-screen or
    // mouse-reporting pane may still get one wheel event or arrow key here.
    //
    // Banked first, because the call clears it. `restoreScroll(rows:)` reads it back.
    warm.setScrolledRows(leaving.session.scrolledRows, for: target)
    await leaving.session.scrollToBottom()

    // **An abandoned step can resume after `close()`.** Opening an observer then would add
    // it to an emptied scene where nothing releases it. `close()` already banked this entry
    // and hands its bridge back.
    guard !isClosed else { return }

    // The observer first, so the pane is always being read and a return is not a cold open.
    let replacement = await makeObserver(for: target)
    guard !isClosed else {
      if let replacement { await release(replacement) }
      return
    }

    // Found again, because `index` predates two awaits. **Matched by `Entry.id` as well as
    // target**: an abandoned demote can resume after the user opened a fresh controller on
    // the same pane, and overwriting that would orphan its attach token.
    if let current = entries.firstIndex(where: { $0.target == target && $0.id == leaving.id }) {
      if let replacement {
        entries[current] = replacement
      } else {
        entries.remove(at: current)
      }
    } else if let replacement {
      // The entry here is not the one being demoted, so this replacement is released. A
      // second entry would be a second stream on one pane.
      await release(replacement)
    }

    leaving.pump?.cancel()
    leaving.session.close()
    // Typed input goes out before the hand-back, or herdr drops it.
    await leaving.session.pendingWritesSent()
    // Handed back on a live link, so the claim ends. See `unreleasedControllers`.
    unreleasedControllers[target] = nil
    await bridge.release()
  }

  /// A target that fell out of the warm set entirely.
  private func drop(_ target: TerminalTarget) async {
    // **Never the shell.** It is our own pty with the user's scrollback and maybe a running
    // command. It goes back in `close()`.
    guard target != .shell else { return }

    if let opening = pending.removeValue(forKey: target) { await release(opening) }
    held[target] = nil
    notices[target] = nil
    reattachAttempts[target] = nil
    reattaching.remove(target)
    restarts.removeValue(forKey: target)?.cancel()
    guard let index = entries.firstIndex(where: { $0.target == target }) else { return }
    await release(entries.remove(at: index))
  }

  private func openController(
    for target: TerminalTarget,
    takeover: Bool,
    automatic: Bool = false
  ) async {
    // A left scene takes nothing new. A switch queued before the scene was left would open a
    // controller after `close()` banked the entries, and nothing would hand it back.
    guard !isClosed else { return }

    if !takeover {
      // Already holding one, or already opening one.
      if let entry = entry(for: target), entry.role == .controller || entry.role == .local {
        return
      }
      if pending[target] != nil { return }
    }

    switch target {
    case .shell:
      guard entry(for: .shell) == nil else { return }
      guard let session = await model.openTerminal(size: viewportSize) else {
        notices[.shell] = .failed(
          model.failure ?? .channelFailed(reason: "The terminal could not be opened.")
        )
        return
      }
      session.start()
      await install(
        Entry(
          id: nextID(),
          target: .shell,
          session: session,
          role: .local,
          attachment: .local,
          pump: nil
        )
      )

    case .pane(let paneID):
      guard let pane = pane(id: paneID) else { return }
      if let terminalID = pane.terminalID {
        await openBridge(
          target: target,
          paneID: paneID,
          terminalID: terminalID,
          takeover: takeover,
          automatic: automatic
        )
      } else {
        // A herdr older than the control bridge has no terminal id, so the pane is attached
        // through a pty with a command typed into it.
        guard entry(for: target) == nil, let herdr = model.herdr else { return }
        guard let session = await model.openTerminal(size: viewportSize) else {
          notices[target] = .failed(
            model.failure ?? .channelFailed(reason: "The pane could not be opened.")
          )
          return
        }
        session.start()
        session.send(text: herdr.attachCommand(for: pane) + "\n")
        await install(
          Entry(
            id: nextID(),
            target: target,
            session: session,
            role: .local,
            attachment: .local,
            pump: nil
          )
        )
      }
    }
  }

  private func openBridge(
    target: TerminalTarget,
    paneID: String,
    terminalID: String,
    takeover: Bool,
    automatic: Bool = false
  ) async {
    guard
      let bridge = await model.openPaneBridge(
        paneID: paneID,
        terminalID: terminalID,
        size: viewportSize,
        measuredSize: measuredSize(for: target),
        sizeDeadline: coreSizeDeadline,
        takeover: takeover,
        recordsFailure: !automatic
      )
    else {
      // An automatic reattach fails silently; see `openSurface`. The last frame stays. A
      // bridge command opens a stream, so a reattach that fails ends again and meets
      // `TerminalEndDisposition`'s bound. A refused core attach opens nothing, so
      // `reattach(_:generation:)` says so itself and `awaitRestart` goes on trying.
      guard !automatic else { return }
      notices[target] = .failed(
        model.failure ?? .channelFailed(reason: "The pane could not be opened.")
      )
      return
    }

    let (feed, pump) = controllerFeed(bridge: bridge, target: target)
    let session = TerminalSession(feed: feed, openSettlingWindow: openSettlingWindow)
    session.start()
    let opened = Entry(
      id: nextID(),
      target: target,
      session: session,
      role: .controller,
      attachment: .controller(bridge),
      pump: pump
    )

    // An abandoned step can resume after `close()` emptied both lists. Installing then would
    // attach a pane nothing will hand back.
    guard !isClosed else {
      await release(opened)
      return
    }

    // A deferred attach goes straight in: only a view can report the size it is waiting for,
    // and an entry in `pending` has no view.
    if keepsPaintingUntilPromoted(target), !(bridge is DeferredPaneBridge) {
      // The existing emulator keeps painting until this controller's first frame. See
      // `controllerPainted`.
      //
      // **Release any controller already pending first.** The re-entry guards run before
      // this function's await, so an abandoned open and its retry can both be in flight.
      // Overwriting the first would orphan its attach token, and herdr would refuse the next
      // open against Driverr's own stream.
      if let superseded = pending.removeValue(forKey: target) { await release(superseded) }
      pending[target] = opened
    } else {
      await install(opened)
    }

    // Input typed at the observer meanwhile goes out now, in order.
    flushHeld(to: session, for: target)

    // One scroll back to where the phone left off, undoing the scroll-to-bottom sent on the
    // way out.
    let rows = warm.scrolledRows(for: target)
    if rows > 0 { session.restoreScroll(rows: rows) }
  }

  /// The size a terminal view measured to open `target` at, or `nil` if none has yet.
  ///
  /// The entry's own first, which is the one laid out in this slot, then one carried from the
  /// last pane. `viewportSize` alone is not enough: nothing writes it until a switch, so a
  /// reattach on the first pane of a scene would be back at the default.
  private func measuredSize(for target: TerminalTarget) -> TerminalSize? {
    entry(for: target)?.session.reportedSize ?? (viewportIsMeasured ? viewportSize : nil)
  }

  /// Whether what is on screen for `target` stays until the opening controller paints.
  ///
  /// True for an observer and for an `.ended` entry, since both hold a real last frame.
  /// `install(_:)` would give the replacement a new `Entry.id`, so a new, empty terminal
  /// view, with no banner. Through `pending`, `controllerPainted` swaps on herdr's first
  /// frame. `switchingToAnObservedPaneSwapsOnTheFirstFrame` and
  /// `aReattachKeepsTheLastFrameUntilTheNewOnePaints` cover the two cases.
  ///
  /// **Not a core observer.** Its bytes arrive at the terminal's width, not the phone's, so
  /// what it shows is garbled and blank for one round trip beats keeping it up.
  private func keepsPaintingUntilPromoted(_ target: TerminalTarget) -> Bool {
    guard let role = entry(for: target)?.role else { return false }
    if role == .observer, case .pane(let id) = target, CorePaneID.isCore(id) { return false }
    return role == .observer || role == .ended
  }

  /// herdr's first frame on a controller stream: the attach token is ours.
  ///
  /// The claim is recorded here, not at open, because a refused open also opens a stream.
  /// Only a frame proves the token is ours. See `unreleasedControllers`.
  private func controllerGranted(_ target: TerminalTarget, generation: Int, cancelled: Bool) {
    unreleasedControllers[target] = linkGeneration
    streamPainted(target, generation: generation, cancelled: cancelled)
    controllerPainted(target)
  }

  /// The controller's first frame has arrived, so it can take over the screen.
  ///
  /// herdr's first frame is always `full: true, seq: 1`, an exact copy of the pane, so there
  /// is no half-drawn state to swap through.
  private func controllerPainted(_ target: TerminalTarget) {
    guard let entry = pending.removeValue(forKey: target) else { return }
    guard let index = entries.firstIndex(where: { $0.target == target }) else {
      entries.append(entry)
      focusRequest += 1
      return
    }
    let observing = entries[index]
    entries[index] = entry
    if target == current { focusRequest += 1 }
    // Untargeted, like `evictForMemoryWarning`: the new controller is already installed, so
    // a stuck release leaves no frozen tap.
    enqueue { [weak self] in await self?.release(observing) }
  }

  /// A bridge session ended, and for `.streamEnded` it ended without a word from herdr.
  ///
  /// Never called for a stream the scene put down itself: `controllerFeed` filters those
  /// out while the cause is known.
  /// - Parameter statedByHerdr: whether a `terminal.closed` record was read off the stream.
  ///   Passed in, not derived, because `controllerFeed` labels an ordinary `paneClosed` as
  ///   `.streamEnded` for the token accounting. `TerminalEndDisposition` recombines them.
  private func sessionEnded(
    _ target: TerminalTarget,
    reason: TerminalCloseReason,
    statedByHerdr: Bool,
    generation: Int
  ) {
    // A stream from a lost connection says nothing about this one; see `linkGeneration`.
    // Dropped, not deferred, because waiting for an order that does not exist is a timeout.
    guard generation == linkGeneration else { return }

    // herdr ending a session drops its token (`remove_client` takes the attach owner), so a
    // claim ends here. See `unreleasedControllers`.
    //
    // A refusal is the exception. The refused stream never painted, so a same-link claim
    // belongs to another stream and stays. A claim from an earlier link is our own ghost:
    // it is consumed and reclaimed, which bounds the reclaim to one attempt.
    //
    // **`.streamEnded` consumes nothing.** A lost link's stream ends arrive from the pump,
    // unordered against the loss notification, so `linkGeneration` cannot turn them all
    // away. A `terminal.closed` record is herdr speaking and a dead link cannot speak, so
    // reading the cause gives the same answer in either order.
    let claim = unreleasedControllers[target]
    let isOurOwnGhost = reason == .refused && (claim.map { $0 < linkGeneration } ?? false)
    // `.processFailed` counts as heard-from, by deduction: the bridge process exited, its
    // socket to herdr closed, and `remove_client` ran. Only `.streamEnded` may leave a claim
    // held on the host.
    let heardFromHerdr = reason != .streamEnded
    if heardFromHerdr, reason != .refused || isOurOwnGhost {
      unreleasedControllers[target] = nil
    }
    // Only news about this pane while the link is up. When the link went, every stream
    // ended together, and "pane closed" over the reconnect banner names the wrong event.
    if model.phase == .connected {
      switch reason {
      // Our own ghost: reclaim rather than say another device has it. The claim is
      // consumed, so a refused reclaim falls through to the prompt instead of looping.
      case .refused where isOurOwnGhost:
        enqueue(on: target) { [weak self] in await self?.openController(for: target, takeover: true) }
      case .refused: notices[target] = .refused
      case .takenOver: notices[target] = .takenOver
      // **`.streamEnded` is not a close.** herdr's own close carries a `terminal.closed`
      // record. A bare stream end is a channel ending (suspension, herdr restart, the
      // command exiting), and "This pane was closed." over a running pane sends the user
      // away. `.processFailed` means the command refused, usually with herdr's reason.
      // `TerminalEndDisposition` owns the rule and is tested in `swift test`.
      //
      // The `detached` receipt for our own `terminal.release` never gets here: both feeds
      // drop it on `Task.isCancelled`.
      case .paneClosed, .other, .streamEnded, .detached, .serverShuttingDown, .processFailed,
        .lost, .neverAttached:
        switch TerminalEndDisposition.forSessionThatEnded(
          reason: reason,
          statedByHerdr: statedByHerdr,
          paneIsStillInTree: paneIsStillInTree(target),
          reattachAttempts: reattachAttempts[target, default: 0]
        ) {
        case .closed: notices[target] = .closed
        case .failed(let message):
          notices[target] = .failed(.channelFailed(reason: message))
        case .reattach: reattach(target, generation: generation)
        case .awaitRestart: awaitRestart(of: target, generation: generation)
        }
      }
    }

    // A refusal never painted, so there is nothing of it on screen to keep.
    if let opening = pending.removeValue(forKey: target) {
      opening.pump?.cancel()
      opening.session.close()
      return
    }
    // Otherwise the emulator stays with its last frame, and only the role changes, so a
    // Take back can open a new controller on the same target.
    //
    // **An observer's end moves the role too.** A dead observer still marked `.observer`
    // would make every reopen of a pane being read return without opening anything.
    if let index = entries.firstIndex(where: { $0.target == target }),
      entries[index].role == .controller || entries[index].role == .observer
    {
      entries[index].role = .ended
    }
  }

  /// Whether a close reason came from a `terminal.closed` record herdr wrote.
  ///
  /// `.streamEnded` (no record) and `.processFailed` (the exit status) come from the channel,
  /// and `.neverAttached` from this side, not from herdr. This is a fact about the record only;
  /// `TerminalEndDisposition` decides what it means.
  private static func statedByHerdr(_ reason: TerminalCloseReason) -> Bool {
    switch reason {
    case .streamEnded, .processFailed, .neverAttached: return false
    case .refused, .takenOver, .paneClosed, .detached, .serverShuttingDown, .lost, .other:
      return true
    }
  }

  /// Whether herdr's latest snapshot still lists this pane. `false` for the shell, which
  /// never reaches `sessionEnded` anyway.
  private func paneIsStillInTree(_ target: TerminalTarget) -> Bool {
    guard case .pane(let id) = target else { return false }
    return pane(id: id) != nil
  }

  /// Opens `target`'s surface again after its stream ended without a word from herdr.
  ///
  /// Silent: the last frame stays, and a working reattach repaints it. The usual cause is a
  /// link that died during suspension before the loss was recorded.
  ///
  /// Counted before the attempt, so an end caused by the reattach itself is the second and
  /// gets `.failed`. `select` and any painted frame reset the count.
  private func reattach(_ target: TerminalTarget, generation: Int) {
    notices[target] = nil
    reattachAttempts[target, default: 0] += 1
    reattaching.insert(target)
    // Untargeted, so a timeout writes no notice about a step the user never asked for.
    enqueue { [weak self] in
      guard let self else { return }
      defer { self.reattaching.remove(target) }
      // Re-checked after the queue: a `close()` or a loss in between makes the open wrong.
      guard !self.isClosed, self.linkGeneration == generation else { return }
      await self.openSurface(for: target, automatic: true)
      // A refused core attach opens no stream, so no second end will reach the bound, and
      // nothing else would offer a Retry.
      if case .pane(let id) = target, CorePaneID.isCore(id), self.role(for: target) == .ended,
        self.pending[target] == nil, self.notices[target] == nil
      {
        self.notices[target] = .failed(
          .channelFailed(reason: TerminalEndDisposition.reattachFailedMessage))
      }
    }
  }

  /// Keeps trying a kept terminal that lost its program, until its new shell answers.
  ///
  /// **A timer, not `treeChanged()`.** `.onChange` fires only on a change, and a lost terminal
  /// stays in the tree, so a restart inside one poll would never be seen. Runs until the
  /// entry stops being `.ended`, the pane leaves the tree, or the link changes.
  ///
  /// An attempt refused as unavailable is silent and counts against nothing, because that is
  /// what the wait is. The sentence stays up until a frame clears it, in `streamPainted`.
  private func awaitRestart(of target: TerminalTarget, generation: Int) {
    notices[target] = .failed(
      .channelFailed(reason: TerminalEndDisposition.awaitingRestartMessage))
    restarts[target]?.cancel()
    restarts[target] = Task { [weak self, wait] in
      for _ in 0..<Self.restartAttempts {
        await wait(Self.restartInterval)
        guard let self, !Task.isCancelled else { return }
        guard !isClosed, linkGeneration == generation,
          entry(for: target)?.role == .ended
        else { return }
        guard paneIsStillInTree(target) else {
          notices[target] = .closed
          return
        }
        // Untargeted, so a timeout writes no notice over the one up. Awaited, so a slow host
        // gets one attempt at a time and the chain does not fill with them.
        enqueue { [weak self] in await self?.openSurface(for: target, automatic: true) }
        await work.value
      }
      guard let self, !Task.isCancelled, entry(for: target)?.role == .ended else { return }
      notices[target] = .failed(
        .channelFailed(reason: TerminalEndDisposition.reattachFailedMessage))
    }
  }

  /// A frame arrived, so whatever went wrong before it is over. Called for observers too,
  /// because a painting observer proves the pane answers.
  ///
  /// It also clears a `.closed` or `.failed` notice, which `select` cannot for the pane on
  /// screen. `.refused` and `.takenOver` stay, because the offer is still true.
  ///
  /// **Only a live stream clears one.** A cancelled pump still drains buffered frames and
  /// never reports its own end, so clearing for it would leave no banner at all. A stream
  /// from a lost link is stale too.
  private func streamPainted(_ target: TerminalTarget, generation: Int, cancelled: Bool) {
    reattachAttempts[target] = nil
    guard !cancelled, generation == linkGeneration else { return }
    switch notices[target] {
    case .closed, .failed: notices[target] = nil
    default: break
    }
  }

  // MARK: - Losing the link, and getting it back

  /// The link went away. `ConnectionModel` calls this when its phase becomes `.lost`, never
  /// for a Disconnect the user asked for.
  private func connectionLost() {
    guard !isClosed else { return }

    // Bank the scroll amount to re-issue on the way back. The position itself is the
    // pane's, on the desk.
    if let session = currentSession {
      warm.setScrolledRows(session.scrolledRows, for: current)
    }
    // Every stream died with the link. The warm set stays, so the way back is the way the
    // user left. Bumped before the drop, so every end from here on is stale.
    linkGeneration += 1
    dropEverySession()
    stopAwaitingRestarts()
    notices = [:]
    // The link explains every end, so none counts against the reattach budget.
    reattachAttempts = [:]
    reattaching = []
    // A pending split is abandoned. An outage can last minutes, so a new pane afterwards
    // may be one the user opened at the desk.
    pendingSplit = nil
    connectionNotice = .reconnecting
    startReconnecting()
  }

  /// The inline prompt's answer, for a host whose password was never remembered. Sent as
  /// `.promptEveryTime`, so a dropped network never writes it to the Keychain.
  func reconnect(with password: String) {
    guard !isClosed else { return }
    connectionNotice = .reconnecting
    reconnectWork?.cancel()
    reconnectWork = Task { [weak self] in
      guard let self else { return }
      await model.connect(password: password, persistence: .promptEveryTime)
      guard model.phase == .connected else {
        // Refused, or the host is still absent. Ask again, with the refusal said, rather
        // than back off on a rejected credential.
        passwordWasRefused = true
        connectionNotice = .needsPassword
        return
      }
      passwordWasRefused = false
      restoreAfterReconnect()
    }
  }

  /// The Reconnect the banner offers once the schedule has run out. Starts it over.
  func reconnectNow() {
    guard !isClosed else { return }
    connectionNotice = .reconnecting
    startReconnecting()
  }

  private func startReconnecting() {
    reconnectWork?.cancel()
    reconnectWork = Task { [weak self] in await self?.runReconnect() }
  }

  /// Try now; then `ReconnectSchedule`; then hand it to the user.
  private func runReconnect() async {
    if await model.needsPasswordToReconnect() {
      // The first ask, so nothing has been refused yet.
      passwordWasRefused = false
      connectionNotice = .needsPassword
      return
    }
    connectionNotice = .reconnecting

    // At once, before any backoff: after a network change or a lock screen the link is
    // often already back.
    if await attemptReconnect() { return }
    for delay in ReconnectSchedule() {
      await wait(delay)
      if Task.isCancelled { return }
      if await attemptReconnect() { return }
    }
    // Past the schedule, retrying only drains the battery. A tap is left.
    connectionNotice = .disconnected
  }

  private func attemptReconnect() async -> Bool {
    await model.reconnect()
    // A second loss mid-attempt starts a fresh reconnect, so the replaced attempt must not
    // restore too.
    guard !Task.isCancelled, model.phase == .connected else { return false }
    restoreAfterReconnect()
    return true
  }

  /// Back on the host: re-open what was being looked at, and nothing else.
  ///
  /// The connection notice clears before the step is queued, because `notice` prefers it,
  /// and a stale `.reconnecting` would hide a timeout the step writes.
  private func restoreAfterReconnect() {
    notices = [:]
    connectionNotice = nil
    // Through the chain, so a `select` tapped during the outage runs first, and `current`
    // is read when the step runs. Only the current target; others reopen when chosen.
    //
    // Targeted, so an abandoned re-open shows a notice. A silent one would leave a blank
    // pane under a clear banner, which looks like a working reconnect.
    enqueue(on: { [weak self] in self?.current }) { [weak self] in
      guard let self else { return }
      // The new session's tree is empty until asked, and it maps pane ids to terminal ids.
      // Inside the chain, so `stepDeadline` bounds it if the host goes quiet.
      await model.session?.refresh()
      // By surface, so a pane being read does not come back holding the controller.
      await openSurface(for: current)
      focusRequest += 1
    }
  }

  /// Puts down every session at once, without handing anything back, because a release
  /// would write `terminal.release` down a dead stream.
  ///
  /// The token may still be held on the host (see `unreleasedControllers`), so the claims
  /// deliberately survive this call.
  private func dropEverySession() {
    let all = entries + Array(pending.values)
    entries = []
    pending = [:]
    held = [:]
    for entry in all {
      entry.pump?.cancel()
      entry.session.close()
    }
  }

  private func stopAwaitingRestarts() {
    for restart in restarts.values { restart.cancel() }
    restarts = [:]
  }

  // MARK: - Feeds

  /// The controller's frames, tapped on the way past for two things a `TerminalSession`
  /// cannot see: the first frame, and why herdr stopped.
  private func controllerFeed(
    bridge: any PaneBridge,
    target: TerminalTarget
  ) -> (TerminalFeed, Task<Void, Never>) {
    // Captured now, so this stream is forever tagged with the connection it opened on.
    let generation = linkGeneration
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    let pump = Task { [weak self] in
      var painted = false
      do {
        for try await chunk in bridge.output {
          continuation.yield(chunk)
          if !painted {
            painted = true
            self?.controllerGranted(
              target,
              generation: generation,
              cancelled: Task.isCancelled
            )
          }
        }
        continuation.finish()
        // A clean finish is one of two opposite things.
        //
        // **Cancelled from this side** (a hand-back or `dropEverySession()`): nothing
        // happened to the pane. Reporting it would put "This pane was closed." over every
        // switch to Chat, and could drop the controller a switch back just opened. The
        // hand-back already forfeited the claim.
        //
        // Otherwise it is herdr's own `paneClosed`, the only end `BridgeFramePump` finishes
        // cleanly; every other end throws. It is labelled `.streamEnded` so the claim is not
        // forfeited here, and `statedByHerdr: true` says herdr spoke, so it keeps its banner
        // instead of reattaching (`anOrdinaryCloseKeepsTheBanner`).
        guard !Task.isCancelled else { return }
        self?.sessionEnded(
          target,
          reason: .streamEnded,
          statedByHerdr: true,
          generation: generation
        )
      } catch let reason as TerminalCloseReason {
        continuation.finish()
        // **The same cancellation rule as above.** `handBack` cancels this pump and then
        // writes `terminal.release`, and herdr answers with a `detached` record, which
        // throws and lands here. `detached` maps to a reattach, so without the guard a switch
        // to Chat would re-take the token it just gave up. No test covers it:
        // `FakeSSHTransport` does not answer `terminal.release`.
        guard !Task.isCancelled else { return }
        self?.sessionEnded(
          target,
          reason: reason,
          statedByHerdr: Self.statedByHerdr(reason),
          generation: generation
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    if let raw = bridge as? any RawTerminalStream {
      let feed = TerminalFeed(
        raw: raw,
        output: stream,
        send: { try await bridge.send(bytes: $0) },
        resize: { try await bridge.resize(to: $0) }
      )
      return (feed, pump)
    }
    let feed = TerminalFeed(
      output: stream,
      send: { try await bridge.send(bytes: $0) },
      resize: { try await bridge.resize(to: $0) },
      // The scene releases, in order; see `demote(_:)`. A session releasing itself could not
      // be sequenced against the observer replacing it.
      close: {},
      scroll: { direction, lines in try await bridge.scroll(direction, lines: lines) },
      click: { try await bridge.click($0) }
    )
    return (feed, pump)
  }

  /// An observer's frames, with input held for the controller.
  ///
  /// **Not `TerminalFeed.readOnly`.** This stream is on screen during the promotion gap,
  /// and what is typed at it must survive until the controller is up. `send` is
  /// `@MainActor` so keystrokes cannot overtake each other into the buffer.
  private func observerFeed(
    observer: any PaneObserver,
    target: TerminalTarget
  ) -> (TerminalFeed, Task<Void, Never>) {
    // Captured now; see `controllerFeed`.
    let generation = linkGeneration
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self
    )
    let pump = Task { [weak self] in
      var painted = false
      do {
        for try await chunk in observer.output {
          continuation.yield(chunk)
          // The first frame proves the pane answers, which resets the reattach budget.
          if !painted {
            painted = true
            self?.streamPainted(target, generation: generation, cancelled: Task.isCancelled)
          }
        }
        continuation.finish()
        // Reported, so a pane closed on the desk while its chat is read gets a banner.
        // Stated by herdr, because a clean finish is herdr's `paneClosed` or our own
        // `cancel()`, never a vanished channel, so it must not reattach. The chat's reattach
        // comes from the throwing `.streamEnded` path below. The cancellation guard is
        // `controllerFeed`'s.
        guard !Task.isCancelled else { return }
        self?.sessionEnded(
          target,
          reason: .streamEnded,
          statedByHerdr: true,
          generation: generation
        )
      } catch let reason as TerminalCloseReason {
        continuation.finish()
        // `controllerFeed`'s guard. Here a `detached` receipt would reopen an observer
        // nobody asked for.
        guard !Task.isCancelled else { return }
        // A warm pane that ended is reported too, since the user may come back to it.
        self?.sessionEnded(
          target,
          reason: reason,
          statedByHerdr: Self.statedByHerdr(reason),
          generation: generation
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }

    let send: @Sendable (Data) async throws -> Void = { @MainActor [weak self] data in
      // Promoted, so this session is the controller now, and `accept` would hand the bytes
      // straight back to it.
      if case .controller(let bridge)? = self?.entry(for: target)?.attachment,
        bridge as AnyObject === observer as AnyObject
      {
        try await bridge.send(bytes: data)
      } else {
        self?.accept(data, from: target)
      }
    }
    if let raw = observer as? any RawTerminalStream {
      // Credit as usual, and `focus`, which an observer ignores, so that SwiftTerm's report of
      // a paint's `?1004h` is dropped rather than held and typed at the controller. A size
      // goes through too: a core ignores it from an observer, and a promotion needs it.
      let feed = TerminalFeed(
        raw: raw,
        output: stream,
        send: send,
        resize: { try await (observer as? any PaneBridge)?.resize(to: $0) }
      )
      return (feed, pump)
    }
    let feed = TerminalFeed(
      output: stream,
      send: send,
      resize: { _ in },
      close: {},
      scroll: nil,
      click: nil
    )
    return (feed, pump)
  }

  /// Where a keystroke goes when the controller may not be up yet.
  ///
  /// Once anything is held, later bytes join it rather than overtake it. `install` makes the
  /// controller findable before `flushHeld` runs, and a keystroke arriving in that gap
  /// would otherwise reach herdr ahead of earlier ones.
  private func accept(_ data: Data, from target: TerminalTarget) {
    if held[target]?.isEmpty ?? true, let controller = controllerSession(for: target) {
      controller.send(ArraySlice(data))
    } else {
      held[target, default: []].append(contentsOf: data)
    }
  }

  private func flushHeld(to session: TerminalSession, for target: TerminalTarget) {
    guard let bytes = held.removeValue(forKey: target), !bytes.isEmpty else { return }
    session.send(bytes[...])
  }

  /// The session that can actually write to this pane, painted or not.
  private func controllerSession(for target: TerminalTarget) -> TerminalSession? {
    if let opening = pending[target] { return opening.session }
    guard let entry = entry(for: target) else { return nil }
    return entry.role == .controller || entry.role == .local ? entry.session : nil
  }

  // MARK: - Housekeeping

  private func install(_ entry: Entry) async {
    // The scene can be left while an open is suspended past `openController`'s guard. The stream is
    // up on the host, so it is handed back, not just skipped.
    guard !isClosed else {
      await release(entry)
      return
    }
    guard let index = entries.firstIndex(where: { $0.target == entry.target }) else {
      entries.append(entry)
      return
    }
    let replaced = entries[index]
    entries[index] = entry
    await release(replaced)
  }

  private func release(_ entry: Entry) async {
    // Only a live controller's hand-back ends the claim. An `.ended` entry's claim is
    // already settled, and clearing here would wipe its replacement's new claim.
    if entry.role == .controller { unreleasedControllers[entry.target] = nil }
    await Self.handBack(entry)
  }

  /// Puts one entry down and gives back whatever it was holding on the host.
  ///
  /// **`static`**, so it keeps working after the scene is gone, which is when `close()`
  /// needs it.
  private static func handBack(_ entry: Entry) async {
    entry.pump?.cancel()
    entry.session.close()
    switch entry.attachment {
    case .controller(let bridge):
      // Queued input first, bounded, so a stuck write cannot keep the token.
      await entry.session.pendingWritesSent()
      await bridge.release()
    case .observer(let observer): await observer.release()
    // The session's own `close()` closed the channel; there is nothing held on the host.
    case .local: break
    }
  }

  private func entry(for target: TerminalTarget) -> Entry? {
    entries.first { $0.target == target }
  }

  private func pane(id: String) -> Pane? { model.session?.tree.pane(id: id) }

  private func terminalID(for paneID: String) -> String? { pane(id: paneID)?.terminalID }

  private func nextID() -> Int {
    nextEntryID += 1
    return nextEntryID
  }

  /// The tree changed: adopt a pane a split created, then rebuild the actions against the
  /// tree, which clears them when the current pane has left. Otherwise the menu would act on
  /// a pane id that is gone.
  func treeChanged() {
    // **Bank the close before the rebuild throws it away.** `rebuildActions` replaces the
    // model holding `didClose`, with `nil` once the pane has left, which is when the closed
    // banner is wanted. `PaneActionsUITests.testClosingAPaneAsksFirstAndThenLetsYouLeave`
    // covers it.
    if actions?.didClose == true { paneWasClosed = true }
    adoptNewPane()
    rebuildActions(for: current)
    promoteObserverLeftOnItsTerminal()
    demoteViewerLeftBehindItsChat()
  }

  /// Watches a core pane again if an agent has started in it, so the chat is on screen.
  ///
  /// `surface(for:)` turned to `.chat` with nobody asking, and a viewer that has typed would go
  /// on holding the terminal's size while only the conversation is read. Only a core pane,
  /// which is the only place a promotion leaves one. `show(_:)` covers the segment.
  private func demoteViewerLeftBehindItsChat() {
    let target = current
    guard case .pane(let id) = target, CorePaneID.isCore(id), surface(for: target) == .chat,
      entry(for: target)?.role == .controller
    else { return }
    enqueue(on: target) { [weak self] in await self?.openSurface(for: target) }
  }

  /// Makes the pane on screen typable if its chat has just gone from under an observer.
  ///
  /// When an agent quits, `surface(for:)` turns to `.terminal` with nobody asking, so the pane
  /// shows a terminal on a stream that cannot type, and a tap would raise the keyboard on it.
  /// Only the current pane: a warm one opens when it is chosen, and a host can lose every
  /// agent at once. A notice stops this asking again on every tree, and Retry opens the pane
  /// as any open does.
  private func promoteObserverLeftOnItsTerminal() {
    let target = current
    guard notices[target] == nil, surface(for: target) == .terminal,
      let watched = entry(for: target), watched.role == .observer,
      case .observer(let observer) = watched.attachment,
      let promotable = observer as? any PromotableObserver
    else { return }

    enqueue(on: target) { [weak self] in
      // Rechecked, because an agent can start while this waits its turn.
      guard let self, !isClosed, entry(for: target)?.id == watched.id,
        entry(for: target)?.role == .observer, surface(for: target) == .terminal
      else { return }
      guard let bridge = try? await promotable.promote() else {
        notices[target] = .failed(.channelFailed(reason: "The pane could not be opened."))
        return
      }
      guard let index = entries.firstIndex(where: { $0.id == watched.id }) else { return }
      entries[index].role = .controller
      entries[index].attachment = .controller(bridge)
      flushHeld(to: entries[index].session, for: target)
    }
  }

  /// Where to send someone whose pane has gone: the nearest live pane.
  ///
  /// **Offered, not taken.** The banner names it and the reader taps it, so the screen is
  /// not pulled away mid-read.
  ///
  /// `nil` when the current pane is alive, when there is no tree, or when no pane is left.
  var nearestLivePane: Pane? {
    guard case .pane(let id) = current else { return nil }
    guard let tree = model.session?.tree else { return nil }
    guard tree.pane(id: id) == nil else { return nil }
    // Urgency order, like `PaneStripModel`: a blocked pane is where the reader most wants to
    // land.
    return tree.panesByUrgency.first
  }

  private func rebuildActions(for target: TerminalTarget) {
    guard case .pane(let paneID) = target, let pane = pane(id: paneID),
      let herdr = model.herdr
    else {
      actions = nil
      return
    }
    let replaced = actions
    let rebuilt = PaneActionsModel(
      pane: pane,
      control: herdr,
      // Re-read at once. A sheet still listing a closed pane reads as a failed tap, and the
      // second tap does damage elsewhere.
      onChanged: { [herdrSession = model.session] in await herdrSession?.refresh() },
      // A closed pane is not where to resume this host. Only a record naming this pane is
      // forgotten.
      onClosed: { [model, paneID] in model.forgetLastPane(paneID) }
    )
    // **Carry the open prompt over.** This runs on every tree change, and a poll would
    // otherwise discard a half-typed rename. Only for the same pane.
    if let replaced, replaced.pane.id == pane.id { rebuilt.adoptPrompt(from: replaced) }
    actions = rebuilt
  }

  /// Puts one operation at the end of the chain, and stops waiting on it after
  /// `stepDeadline`.
  ///
  /// **The bound prevents a soft-lock.** Every step awaits herdr, and nothing under
  /// `CLIControl` or `execStream` has a deadline. One command that never answers would park
  /// the chain, and every later `show(_:)`, pane action and `close()` queues behind it: the
  /// app draws, reports nothing, and ignores every tap.
  ///
  /// Abandoned, not cancelled, for `PaneComposerModel.bounded`'s reason: nothing below
  /// checks cancellation. An abandoned step can land its writes late, which is why the steps
  /// re-check `isClosed` and re-find entries after every await.
  ///
  /// `target`, when given, is what the step was about. A timeout leaves `Notice.failed` on
  /// it with a Retry, because an abandoned step is a tap that did nothing. For example, a
  /// hung demote in `reconcile` means `openSurface(for:)` never runs, and the new target
  /// would paint nothing and say nothing.
  private func enqueue(
    on target: TerminalTarget? = nil,
    _ operation: @escaping @MainActor () async -> Void
  ) {
    enqueue(on: { target }, operation)
  }

  /// The same, for a step whose subject is known only when it runs.
  ///
  /// `restoreAfterReconnect` re-opens whichever target is current when the chain reaches
  /// it, since a `select` tapped during the outage may run first. Resolving at queue time
  /// would put the timeout notice on the pane the user just left.
  private func enqueue(
    on target: @escaping @MainActor () -> TerminalTarget?,
    _ operation: @escaping @MainActor () async -> Void
  ) {
    let previous = work
    workGeneration += 1
    work = Task { @MainActor [weak self, stepDeadline] in
      // Only the operation is bounded. `previous` ran its own step under the same deadline.
      await previous.value
      // Read before the step, which may move `current`.
      let target = target()
      let (finishedInTime, running) = await Self.bounded(operation, by: stepDeadline)
      guard !finishedInTime, let target, let self, !self.isClosed else { return }
      self.notices[target] = .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer))
      // **The notice is true only until the step finishes.** An abandoned step can still
      // succeed by several paths, and its own completion covers them all. Cleared only if
      // the notice is still this exact value, so a later notice is left alone.
      Task { @MainActor [weak self, target] in
        await running.value
        guard let self, !self.isClosed,
          self.notices[target] == .failed(.herdrCommandFailed(reason: PaneComposerCopy.noAnswer))
        else { return }
        self.notices[target] = nil
      }
    }
  }

  /// Runs one step, and returns after `deadline` whether or not it has finished.
  ///
  /// Not a task group, for `PaneComposerModel.bounded`'s reason.
  ///
  /// Returns whether `step` finished in time (`false` means abandoned, not failed) and the
  /// `Task` running it, so `enqueue(on:_:)` can clear its notice when the step lands.
  @discardableResult
  private static func bounded(
    _ step: @escaping @MainActor () async -> Void,
    by deadline: Duration
  ) async -> (finishedInTime: Bool, running: Task<Void, Never>) {
    let running = Task { @MainActor in await step() }
    let finishedInTime = await withCheckedContinuation { continuation in
      let race = StepRace(continuation)
      Task { @MainActor in
        await running.value
        race.settle(true)
      }
      race.deadline = Task { @MainActor in
        try? await Task.sleep(for: deadline)
        guard !Task.isCancelled else { return }
        race.settle(false)
      }
    }
    return (finishedInTime, running)
  }
}

/// Whichever of a chain step and its deadline finishes first, resolved exactly once, with
/// whether the step won.
///
/// `PaneComposerModel.SendRace`'s twin. Separate because a send reports a result and a
/// step only reports whether it beat the deadline. Resolving twice would crash.
@MainActor
private final class StepRace {
  private var continuation: CheckedContinuation<Bool, Never>?
  var deadline: Task<Void, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func settle(_ finishedInTime: Bool) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    continuation.resume(returning: finishedInTime)
  }
}

/// How the scene waits out one step of a reconnect backoff.
///
/// Injected so a test controls time. `ReconnectSchedule` runs for over a minute, and a
/// recording waiter lets a test assert the schedule without living through it.
typealias ReconnectWaiter = @MainActor (Duration) async -> Void

import DriverrCore
import DriverrHerdr
import Foundation

/// Opens tmux panes live, through control-mode clients (`tmux -C`).
///
/// **One client per session, shared and counted.** A control client attaches to a session and
/// hears the output of every pane in it, so two panes open in one session share one exec channel.
/// The last pane to leave closes it.
///
/// **Attached with `-t $S`, never a pane or a window.** `attach-session -t %N` makes that pane's
/// window current in its session, so the desk's view would move with the phone.
///
/// **What it does to the desk's window size, measured on tmux 3.7c:**
/// - An attach alone changes nothing. The first window size a control client sets gives the
///   client a size of its own, 80x24 unless told, and that takes the session's current window.
///   So the attach line also sets the client's size to the current window's own.
/// - `refresh-client -C @W:WxH` sizes one window, current or not, and `@W:` hands it back. A
///   window the desk views returns to the desk at once. With a desk attached, one it is not
///   viewing keeps the phone's size until it does; with none, it returns to the client's size.
///   So the hand-back is `@W:P ; @W:`, with `P` the size the window had before the first size
///   from this client: that gives a window the desk is not viewing its own size back, and the
///   desk still takes it over when it views it.
/// - A client that never sets a window size leaves the desk in charge, through desk resizes and
///   window changes. That is the setting-off path.
/// - With `window-size smallest` or `largest` and a desk attached, the attach line's client size
///   holds the desk's windows at that size when the desk grows or shrinks past it. Not fixed.
///
/// **tmux before 3.3, measured on 3.2a:** `refresh-client -C` takes only `WxH`, and anything
/// else answers `bad size argument`, so a window cannot be sized. A client size there is not
/// one window's: it holds every window in the session, under `smallest` and `largest` with a
/// desk and under any setting without one. So the attach line puts `@W:` first, which 3.2
/// refuses, and tmux skips the rest of the line. The desk stays in charge, as with the setting
/// off. 3.3 and later run all three, and `@W:` on a window nobody sized changes nothing.
///
/// **A pane moved to another session**, measured on 3.2a and 3.7c: after `move-pane`,
/// `join-pane`, `break-pane -t B:` or `move-window -t B:`, the old session's client hears
/// `%layout-change` or `%unlinked-window-close` and then none of the pane's output. Moving a
/// session's last pane ends that client with `%exit`. So the viewer moves to the new session's
/// client and is painted again there.
final class TmuxAttacher: PaneAttacher, @unchecked Sendable {
  private let binary: String
  private let run: CommandRunner
  private let open: StreamRunner
  private let resizesWindow: @Sendable () async -> Bool

  private let lock = NSLock()
  private var clients: [String: TmuxSessionClient] = [:]
  private var starting: [String: Task<TmuxSessionClient, any Error>] = [:]
  /// One count for every client, so a viewer that moves between them keeps a unique id.
  private let ids = TmuxViewerIDs()

  /// `binary` is the tmux command as `TmuxControl` runs it, quoted and with `-u`.
  init(
    binary: String,
    run: @escaping CommandRunner,
    open: @escaping StreamRunner,
    resizesWindow: @escaping @Sendable () async -> Bool
  ) {
    self.binary = binary
    self.run = run
    self.open = open
    self.resizesWindow = resizesWindow
  }

  func open(terminalID: String, size: TerminalSize) async throws -> any PaneBridge {
    try await attach(terminalID, size: size, asController: true)
  }

  func observe(terminalID: String, size: TerminalSize) async throws -> any PaneObserver {
    try await attach(terminalID, size: size, asController: false)
  }

  /// The setting is read here, at open, for an observer too: one promoted later sizes the window
  /// by the same answer.
  private func attach(
    _ terminalID: String,
    size: TerminalSize,
    asController: Bool
  ) async throws -> TmuxAttachment {
    guard let pane = TmuxID.rawPane(of: terminalID) else {
      throw AppError.herdrCommandFailed(reason: "\(terminalID) is not a tmux pane on this host.")
    }
    let place = try await locate(pane)
    let resizes = await resizesWindow()
    let client = try await client(for: place)
    return try await client.attach(
      pane: pane, window: place.window, size: size, asController: asController,
      resizes: resizes)
  }

  /// Where a pane is: its session, its window, and the size of the session's current window.
  struct Place: Equatable {
    var session: String
    var window: String
    var currentWindowSize: String?
  }

  /// One `display-message` for all three. The `W:` loop walks the pane's session's windows, and
  /// only the current one prints its size.
  static let placeFormat =
    "#{session_id} #{window_id} #{W:#{?window_active,#{window_width}x#{window_height},}}"

  static func place(from output: String) -> Place? {
    let words = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard words.count >= 2,
      let session = TmuxID.validRaw(String(words[0]), kind: .session),
      let window = TmuxID.validRaw(String(words[1]), kind: .window)
    else { return nil }
    let size = words.count > 2 ? String(words[2]) : nil
    let isSize = size.map { $0.split(separator: "x").count == 2 && $0.allSatisfy { $0 == "x" || $0.isNumber } } ?? false
    return Place(session: session, window: window, currentWindowSize: isSize ? size : nil)
  }

  private func locate(_ pane: String) async throws -> Place {
    let command =
      "\(binary) display-message -p -t \(shellQuoted(pane)) \(shellQuoted(Self.placeFormat))"
    let result: CommandResult
    do {
      result = try await run(command)
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not run tmux on this host.")
    }
    guard result.exitStatus == 0 else {
      throw TmuxControl.failure(exitStatus: result.exitStatus, standardError: result.standardError)
    }
    guard let place = Self.place(from: result.standardOutput) else {
      throw AppError.herdrResponseUnreadable
    }
    return place
  }

  /// The command that starts a control client on `session`, sized to its current window.
  ///
  /// `@W:` goes first, so tmux before 3.3 refuses it and skips the client size. See the type's
  /// comment.
  static func attachCommand(binary: String, place: Place) -> String {
    var command = "\(binary) -C attach-session -t \(shellQuoted(place.session))"
    if let size = place.currentWindowSize {
      command += " \\; refresh-client -C \(place.window): \\; refresh-client -C \(size)"
    }
    return command
  }

  /// Where `pane` is now, and its session's client, for a viewer that follows it there.
  private func relocate(_ pane: String) async throws -> (TmuxSessionClient, String) {
    let place = try await locate(pane)
    return (try await client(for: place), place.window)
  }

  /// The session's client, starting one if none is up. Concurrent opens share one start.
  private func client(for place: Place) async throws -> TmuxSessionClient {
    let task: Task<TmuxSessionClient, any Error> = lock.withLock {
      if let running = starting[place.session] { return running }
      if let client = clients[place.session], client.isUsable {
        return Task { client }
      }
      let task = Task { [binary, run, open, ids] () throws -> TmuxSessionClient in
        let stream = try await open(Self.attachCommand(binary: binary, place: place))
        return TmuxSessionClient(
          session: place.session, binary: binary, run: run, stream: stream, ids: ids)
      }
      starting[place.session] = task
      return task
    }
    do {
      let client = try await task.value
      lock.withLock {
        if starting[place.session] == task { starting[place.session] = nil }
        if clients[place.session] !== client {
          clients[place.session] = client
          client.onFinished = { [weak self] finished in self?.forget(finished) }
          client.relocate = { [weak self] pane in
            guard let self else { throw TerminalCloseReason.streamEnded }
            return try await self.relocate(pane)
          }
        }
      }
      return client
    } catch {
      lock.withLock { if starting[place.session] == task { starting[place.session] = nil } }
      throw error
    }
  }

  private func forget(_ client: TmuxSessionClient) {
    lock.withLock {
      if clients[client.session] === client { clients[client.session] = nil }
    }
  }

  /// How many session clients are up, for the tests.
  var clientCount: Int { lock.withLock { clients.values.filter(\.isUsable).count } }
}

/// Viewer ids, unique across every client of one attacher.
final class TmuxViewerIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var last = 0

  func next() -> Int {
    lock.withLock {
      last += 1
      return last
    }
  }
}

/// Why a command came back without its answer.
enum TmuxCommandFailure: Error, Equatable {
  /// tmux answered `%error`, with these lines.
  case refused(String)
  /// The client went before the answer came.
  case ended
}

/// One control client on one session, and every pane open through it.
///
/// **Commands are answered in the order they were written**, so a write and its place in the
/// queue are taken under one lock. A reply is acted on by the reader, in the same pass that
/// parsed it, before the next line: a paint's last `%end` and the pane's next `%output` are in
/// that order, and a hop to another task would let the output win.
final class TmuxSessionClient: @unchecked Sendable {
  let session: String
  private let binary: String
  private let run: CommandRunner
  private let stream: any HerdrStream
  private let ids: TmuxViewerIDs

  private let lock = NSLock()
  private var queue: [Pending] = []
  private var attachments: [Int: TmuxAttachment] = [:]
  /// `false` once tmux refused a window size as one before 3.3 does.
  private var sizesWindows = true
  /// The windows this client sized, by window.
  private var sizings: [String: Sizing] = [:]
  private var isEnded = false
  private var isClosing = false
  private let writes: AsyncStream<Data>.Continuation
  private var tasks: [Task<Void, Never>] = []

  /// Called once, when the client has ended or closed.
  var onFinished: (@Sendable (TmuxSessionClient) -> Void)? {
    get { lock.withLock { finished } }
    set { lock.withLock { finished = newValue } }
  }
  private var finished: (@Sendable (TmuxSessionClient) -> Void)?

  /// Finds a pane that left this session: the client of the session it is in now, and its
  /// window there.
  var relocate: (@Sendable (String) async throws -> (TmuxSessionClient, String))? {
    get { lock.withLock { relocating } }
    set { lock.withLock { relocating = newValue } }
  }
  private var relocating: (@Sendable (String) async throws -> (TmuxSessionClient, String))?

  private struct Pending {
    let expected: Int
    var replies: [[Data]] = []
    let done: @Sendable (Result<[[Data]], TmuxCommandFailure>) -> Void
  }

  /// One window this client sized: who sized it, and the size to give back.
  private struct Sizing {
    /// The viewers holding it, oldest first, each with the size it set. The last one's is on.
    var holders: [(id: Int, size: String)] = []
    /// The size the window had before this client's first size, once tmux has said. `""` when
    /// tmux answered with no size, which it does for a window that is gone.
    var prior: String?
    /// Hand-backs that wait for `prior`, because the last holder left before tmux said it.
    var waiting: [@Sendable () -> Void] = []
  }

  init(
    session: String,
    binary: String,
    run: @escaping CommandRunner,
    stream: any HerdrStream,
    ids: TmuxViewerIDs = TmuxViewerIDs()
  ) {
    self.session = session
    self.binary = binary
    self.run = run
    self.stream = stream
    self.ids = ids
    let (lines, writes) = AsyncStream.makeStream(of: Data.self)
    self.writes = writes
    let writer = Task { [stream] in
      for await line in lines {
        do { try await stream.send(line) } catch { break }
      }
    }
    let reader = Task { [weak self, stream] in
      var parser = TmuxControlParser()
      do {
        for try await chunk in stream.output {
          for event in parser.consume(chunk) { self?.handle(event) }
        }
      } catch {}
      await self?.ended()
    }
    tasks = [writer, reader]
  }

  var isUsable: Bool { lock.withLock { !isEnded && !isClosing } }

  // MARK: Commands

  /// Writes one command line that answers `replies` blocks, and calls `done` from the reader.
  func send(
    _ line: String,
    replies: Int = 1,
    done: @escaping @Sendable (Result<[[Data]], TmuxCommandFailure>) -> Void = { _ in }
  ) {
    let accepted = lock.withLock { enqueue(line, replies: replies, done: done) }
    if !accepted { done(.failure(.ended)) }
  }

  /// `send`'s write, with the lock held, so a caller can decide what to write under it too.
  private func enqueue(
    _ line: String,
    replies: Int,
    done: @escaping @Sendable (Result<[[Data]], TmuxCommandFailure>) -> Void
  ) -> Bool {
    guard !isEnded else { return false }
    queue.append(Pending(expected: replies, done: done))
    writes.yield(Data((line + "\n").utf8))
    return true
  }

  func command(_ line: String, replies: Int = 1) async throws -> [[Data]] {
    try await withCheckedThrowingContinuation { continuation in
      send(line, replies: replies) { continuation.resume(with: $0) }
    }
  }

  // MARK: Panes

  func attach(
    pane: String,
    window: String,
    size: TerminalSize,
    asController: Bool,
    resizes: Bool
  ) async throws -> TmuxAttachment {
    let attachment: TmuxAttachment? = lock.withLock {
      guard !isEnded, !isClosing else { return nil }
      let attachment = TmuxAttachment(
        id: ids.next(), client: self, pane: pane, window: window, size: size,
        asController: asController, resizes: resizes)
      attachments[attachment.id] = attachment
      return attachment
    }
    guard let attachment else { throw TerminalCloseReason.streamEnded }
    do {
      if asController { await attachment.sizeWindow() }
      try await attachment.paint(history: asController ? TmuxPaint.historyLines : 0)
      return attachment
    } catch {
      await attachment.release()
      if let error = error as? AppError { throw error }
      if case .refused(let message)? = error as? TmuxCommandFailure {
        throw AppError.herdrCommandFailed(reason: message)
      }
      throw AppError.channelFailed(reason: "The pane could not be opened.")
    }
  }

  /// Takes on a viewer whose pane moved here from another session's client: sizes its window and
  /// paints it again, clearing what it showed.
  func adopt(_ attachment: TmuxAttachment, window: String) async throws {
    let accepted: Bool = lock.withLock {
      guard !isEnded, !isClosing else { return false }
      attachments[attachment.id] = attachment
      return true
    }
    guard accepted else { throw TerminalCloseReason.streamEnded }
    guard attachment.moved(to: self, window: window) else {
      // Released on the way here.
      await detach(attachment)
      return
    }
    await attachment.sizeWindow()
    try await attachment.paint(history: attachment.paintsHistory ? TmuxPaint.historyLines : 0, clearing: true)
  }

  /// Sizes `window` to `size` for `attachment`, unless tmux has said it cannot, and waits for
  /// tmux's answer.
  ///
  /// **The first size reads the window's own size in the same line**, so it is read before any
  /// size from here lands, and the choice of line is made under the lock that orders the writes.
  func size(_ window: String, to size: TerminalSize, for attachment: TmuxAttachment) async {
    let columns = min(max(size.columns, 1), 10_000)
    let rows = min(max(size.rows, 1), 10_000)
    let target = "\(columns)x\(rows)"
    await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
      let sent: Bool = lock.withLock {
        guard sizesWindows, attachments[attachment.id] === attachment else { return false }
        let first = sizings[window] == nil
        var sizing = sizings[window] ?? Sizing()
        sizing.holders.removeAll { $0.id == attachment.id }
        sizing.holders.append((attachment.id, target))
        sizings[window] = sizing
        let line =
          first
          ? "display-message -p -t \(window) '#{window_width}x#{window_height}' ; refresh-client -C \(window):\(target)"
          : "refresh-client -C \(window):\(target)"
        let id = attachment.id
        return enqueue(line, replies: first ? 2 : 1) { [weak self] result in
          self?.sized(window, by: id, first: first, result)
          waiting.resume()
        }
      }
      if !sent { waiting.resume() }
    }
  }

  /// tmux answered a size for `window`. On the reader.
  private func sized(
    _ window: String, by id: Int, first: Bool, _ result: Result<[[Data]], TmuxCommandFailure>
  ) {
    let handBack: (line: String, replies: Int, waiting: [@Sendable () -> Void])? = lock.withLock {
      guard var sizing = sizings[window] else { return nil }
      switch result {
      case .success(let replies):
        guard first else { return nil }
        let reported = replies.first?.first.map { String(decoding: $0, as: UTF8.self) } ?? ""
        sizing.prior = Self.isSize(reported) ? reported : ""
      case .failure(.refused(let message)):
        if Self.refusesEveryWindowSize(message) {
          // tmux before 3.3. Nothing here sized a window, so nothing goes back.
          sizesWindows = false
          defer { sizings = [:] }
          return ("", 0, sizings.values.flatMap(\.waiting))
        }
        guard first else { return nil }
        // Not sized, so this viewer holds nothing, and with nobody else nothing goes back.
        sizing.holders.removeAll { $0.id == id }
        sizing.prior = ""
        if sizing.holders.isEmpty {
          sizings[window] = nil
          return ("", 0, sizing.waiting)
        }
      case .failure(.ended):
        return ("", 0, sizing.waiting)
      }
      guard sizing.holders.isEmpty else {
        let waiting = sizing.waiting
        sizing.waiting = []
        sizings[window] = sizing
        return ("", 0, waiting)
      }
      // Everyone left before tmux answered.
      sizings[window] = nil
      return (Self.handBackLine(window, prior: sizing.prior ?? ""), 0, sizing.waiting)
    }
    guard let handBack else { return }
    if handBack.line.isEmpty {
      for resume in handBack.waiting { resume() }
    } else {
      let waiting = handBack.waiting
      send(handBack.line, replies: Self.handBackReplies(handBack.line)) { _ in
        for resume in waiting { resume() }
      }
    }
  }

  /// Only tmux before 3.3 answers this to a window size; any other refusal is about one size.
  static func refusesEveryWindowSize(_ message: String) -> Bool {
    message.contains("bad size argument")
  }

  private static func isSize(_ text: String) -> Bool {
    let parts = text.split(separator: "x", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
  }

  /// `@W:P ; @W:` when the window's own size is known, which gives a window the desk is not
  /// viewing its size back. `@W:` alone otherwise.
  private static func handBackLine(_ window: String, prior: String) -> String {
    prior.isEmpty
      ? "refresh-client -C \(window):"
      : "refresh-client -C \(window):\(prior) ; refresh-client -C \(window):"
  }

  private static func handBackReplies(_ line: String) -> Int {
    line.contains(" ; ") ? 2 : 1
  }

  /// Types `bytes` into `pane`, as hex keys so no byte is read as a key name or a flag.
  ///
  /// In chunks, because one command line holds a whole paste otherwise. They go in order, and
  /// nothing waits for tmux's answers.
  func type(_ bytes: Data, into pane: String) throws {
    guard isUsable else { throw TerminalCloseReason.streamEnded }
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let end = bytes.index(index, offsetBy: Self.keyChunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
      let hex = bytes[index..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
      send("send-keys -t \(pane) -H \(hex)")
      index = end
    }
  }

  /// Bytes per `send-keys -H` line.
  static let keyChunk = 256

  /// How long a hand-back waits for tmux. A release must not hang on a link that went quiet:
  /// the scene awaits it, and the channel closes anyway, which hands every window back.
  static let handBackDeadline: Duration = .seconds(1)
  /// How long the listing after a stream ends may take, over its own exec channel.
  static let listingDeadline: Duration = .seconds(5)

  /// Takes `attachment` off this client, hands back the windows it sized, and closes the client
  /// with the last one.
  ///
  /// **The last one asks for its window too.** A client leaving hands every window back, but
  /// after the release has returned, measured on 3.7c, and with a desk attached a window it is
  /// not viewing keeps the phone's size. Asked first, the window is back at its own size when
  /// the release returns, or `handBackDeadline` has passed.
  func detach(_ attachment: TmuxAttachment) async {
    let (closes, windows) = takeOff(attachment)
    for window in windows { await leave(window, by: attachment.id) }
    if closes { await close() }
  }

  /// Removes `attachment`, and answers whether that closes the client and which windows it held.
  private func takeOff(_ attachment: TmuxAttachment) -> (closes: Bool, windows: [String]) {
    lock.withLock {
      guard attachments[attachment.id] === attachment else { return (false, []) }
      attachments[attachment.id] = nil
      let closes = attachments.isEmpty && !isEnded && !isClosing
      if closes { isClosing = true }
      let windows = sizings.filter { $0.value.holders.contains { $0.id == attachment.id } }.map(\.key)
      return (closes, windows)
    }
  }

  /// Viewer `id` no longer holds `window`. The newest size still held goes back on, or, with none
  /// left, the window's own size. Waits at most `handBackDeadline` for tmux's answer.
  func leave(_ window: String, by id: Int) async {
    _ = await FirstAnswer.within(Self.handBackDeadline, otherwise: false) { answer in
      let next: String? = self.lock.withLock {
        guard self.sizesWindows, !self.isEnded, var sizing = self.sizings[window],
          let index = sizing.holders.firstIndex(where: { $0.id == id })
        else { return nil }
        let left = sizing.holders.remove(at: index)
        if let newest = sizing.holders.last {
          self.sizings[window] = sizing
          // Only the newest holder's size is on screen.
          let isOn = index == sizing.holders.count
          return isOn && newest.size != left.size ? "refresh-client -C \(window):\(newest.size)" : nil
        }
        guard let prior = sizing.prior else {
          // tmux has not said the window's own size yet; its answer hands the window back.
          sizing.waiting.append { answer.resume(true) }
          self.sizings[window] = sizing
          return ""
        }
        self.sizings[window] = nil
        return Self.handBackLine(window, prior: prior)
      }
      switch next {
      case nil: answer.resume(true)
      case ""?: break
      case let line?: self.send(line, replies: Self.handBackReplies(line)) { _ in answer.resume(true) }
      }
    }
  }

  /// A pane moved to `window` in this session: the window it held goes back, and the new one
  /// takes its size.
  private func follow(_ attachment: TmuxAttachment, to window: String) {
    guard let left = attachment.moved(to: window) else { return }
    Task {
      await self.leave(left, by: attachment.id)
      await attachment.sizeWindow()
    }
  }

  /// A pane moved to another session, whose client never hears its output. The viewer leaves
  /// this client at once, on the reader, so a `%exit` right behind the move does not end it.
  /// Then the window it held goes back, and the other session's client takes it on.
  private func moveAway(_ attachment: TmuxAttachment) {
    attachment.startMove()
    let (closes, windows) = takeOff(attachment)
    let relocate = self.relocate
    Task {
      for window in windows { await self.leave(window, by: attachment.id) }
      if closes { await self.close() }
      do {
        guard let relocate else { throw TerminalCloseReason.streamEnded }
        let (client, window) = try await relocate(attachment.pane)
        try await client.adopt(attachment, window: window)
      } catch {
        attachment.end(paneClosed: false)
      }
    }
  }

  private func close() async {
    writes.finish()
    await stream.close()
    for task in lock.withLock({ tasks }) { task.cancel() }
    finish()
  }

  private func finish() {
    let callback: (@Sendable (TmuxSessionClient) -> Void)? = lock.withLock {
      defer { finished = nil }
      return finished
    }
    callback?(self)
  }

  // MARK: Reading

  private func handle(_ event: TmuxControlEvent) {
    switch event {
    case .reply(_, let fromClient, let lines, let failed):
      guard fromClient else { return }
      let completed: (Pending, Result<[[Data]], TmuxCommandFailure>)? = lock.withLock {
        guard var first = queue.first else { return nil }
        if failed {
          queue.removeFirst()
          let message = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
          return (first, .failure(.refused(message)))
        }
        first.replies.append(lines)
        guard first.replies.count == first.expected else {
          queue[0] = first
          return nil
        }
        queue.removeFirst()
        return (first, .success(first.replies))
      }
      if let (pending, result) = completed { pending.done(result) }
    case .output(let pane, let bytes):
      for attachment in viewers(of: pane) { attachment.deliver(bytes) }
    case .layoutChange(let window, let panes):
      for attachment in viewers(inWindow: window) where !panes.contains(attachment.pane) {
        check(attachment.pane)
      }
    case .windowClosed(let window):
      for attachment in viewers(inWindow: window) { check(attachment.pane) }
    case .exit:
      // The end of the stream follows, and `ended()` reads what it means.
      break
    }
  }

  private func viewers(of pane: String) -> [TmuxAttachment] {
    lock.withLock { attachments.values.filter { $0.pane == pane }.sorted { $0.id < $1.id } }
  }

  private func viewers(inWindow window: String) -> [TmuxAttachment] {
    lock.withLock { attachments.values.filter { $0.window == window } }
  }

  /// Whether a pane that left its window's layout has closed or only moved, and where to. Asked
  /// of tmux, because a pane broken out to a window of its own leaves a layout too.
  ///
  /// **The answer names the pane, because a missing one is not an error.** `display-message`'s
  /// target may fail, so for a pane that is gone tmux 3.7c answers an empty `%end`.
  private func check(_ pane: String) {
    send("display-message -p -t \(pane) '#{pane_id} #{window_id} #{session_id}'") {
      [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let replies):
        let words = replies.first?.first.map { String(decoding: $0, as: UTF8.self) }?
          .split(separator: " ").map(String.init) ?? []
        guard words.count == 3, words[0] == pane,
          TmuxID.validRaw(words[1], kind: .window) != nil,
          TmuxID.validRaw(words[2], kind: .session) != nil
        else {
          for attachment in self.viewers(of: pane) { attachment.end(paneClosed: true) }
          return
        }
        for attachment in self.viewers(of: pane) {
          if words[2] == self.session {
            self.follow(attachment, to: words[1])
          } else {
            self.moveAway(attachment)
          }
        }
      case .failure(.refused):
        for attachment in self.viewers(of: pane) { attachment.end(paneClosed: true) }
      case .failure(.ended):
        break
      }
    }
  }

  /// The stream is over. Each pane open through it closed or not, which tmux says, not the end.
  ///
  /// `%exit` comes both when the session goes with its last pane and when the link or the server
  /// does, so the panes are listed once more over a fresh exec channel. A pane missing from the
  /// list closed. One still there, or no answer, is `.streamEnded`, which the scene reattaches.
  private func ended() async {
    let (pending, open, closing): ([Pending], [TmuxAttachment], Bool) = lock.withLock {
      isEnded = true
      defer { queue = [] }
      return (queue, Array(attachments.values), isClosing)
    }
    writes.finish()
    for item in pending { item.done(.failure(.ended)) }
    if !closing, !open.isEmpty {
      let living = await livingPanes()
      for attachment in open {
        attachment.end(paneClosed: living.map { !$0.contains(attachment.pane) } ?? false)
      }
    }
    finish()
  }

  /// The server's panes, or `nil` when tmux could not be asked within `listingDeadline`. No
  /// server means no panes.
  private func livingPanes() async -> Set<String>? {
    let (run, binary) = (run, binary)
    let answer: CommandResult?? = await FirstAnswer.within(Self.listingDeadline, otherwise: nil) {
      answer in
      Task { answer.resume(.some(try? await run("\(binary) list-panes -a -F '#{pane_id}'"))) }
    }
    guard let answer, let result = answer else { return nil }
    if result.exitStatus != 0 {
      return TmuxControl.isNoServer(result.standardError) ? [] : nil
    }
    return Set(result.standardOutput.split(separator: "\n").map(String.init))
  }
}

/// One pane, live, through its session's control client.
///
/// A `PaneBridge` and a `PromotableObserver` both, as a core's viewer is, and raw: the bytes are
/// the program's own and the history is local.
///
/// **Output before the paint's last `%end` is dropped.** tmux runs the paint's commands back to
/// back, so the capture already holds every byte written before it, and every byte after comes
/// as `%output` behind the `%end`.
final class TmuxAttachment: PaneBridge, PromotableObserver, RawTerminalStream, @unchecked Sendable {
  let id: Int
  let pane: String
  let output: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  /// The session's client, which changes when the pane moves to another session.
  private var owner: TmuxSessionClient
  private var currentWindow: String
  private var isController: Bool
  private let resizes: Bool
  private var size: TerminalSize
  /// Promoted, and nobody has touched it. See `touched()`.
  private var awaitsTouch = false
  /// Drops output until a paint lands. True from the start, because a controller sizes its window
  /// before the first paint, and output meanwhile is in that paint.
  private var isPainting = true
  private var isReleased = false

  init(
    id: Int,
    client: TmuxSessionClient,
    pane: String,
    window: String,
    size: TerminalSize,
    asController: Bool,
    resizes: Bool
  ) {
    self.id = id
    owner = client
    self.pane = pane
    currentWindow = window
    self.size = size
    isController = asController
    self.resizes = resizes
    (output, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
  }

  var window: String { lock.withLock { currentWindow } }

  private var client: TmuxSessionClient { lock.withLock { owner } }

  /// Whether a paint carries history: a controller's does, an observer's does not.
  var paintsHistory: Bool { lock.withLock { isController && !awaitsTouch } }

  // MARK: From the client

  func deliver(_ bytes: Data) {
    guard !lock.withLock({ isPainting || isReleased }) else { return }
    continuation.yield(bytes)
  }

  /// Follows the pane to `window`. Answers `nil` when it was already there, and otherwise the
  /// window it left, which this viewer no longer holds.
  func moved(to window: String) -> String? {
    lock.withLock {
      guard currentWindow != window else { return nil }
      defer { currentWindow = window }
      return currentWindow
    }
  }

  /// The pane is moving to another session. Its output stops until the new client's paint.
  func startMove() { lock.withLock { isPainting = true } }

  /// Follows the pane to `window` on `client`. Answers `false` when it was released meanwhile.
  func moved(to client: TmuxSessionClient, window: String) -> Bool {
    lock.withLock {
      guard !isReleased else { return false }
      owner = client
      currentWindow = window
      return true
    }
  }

  /// `PaneBridge.output`'s contract: a clean finish for a pane that closed, `.streamEnded` for
  /// anything else.
  func end(paneClosed: Bool) {
    if paneClosed {
      continuation.finish()
    } else {
      continuation.finish(throwing: TerminalCloseReason.streamEnded)
    }
  }

  /// Paints the pane's screen, and `history` rows above it. `clearing` wipes what the emulator
  /// shows first, scrollback included, for a repaint.
  func paint(history: Int, clearing: Bool = false) async throws {
    lock.withLock { isPainting = true }
    let (line, replies) = TmuxPaint.commands(pane: pane, history: history)
    let painted: Result<Void, any Error> = await withCheckedContinuation { waiting in
      client.send(line, replies: replies) { [self] result in
        // On the reader, before the next line is parsed.
        switch result {
        case .success(let replies):
          if let bytes = TmuxPaint.bytes(from: replies, clearing: clearing) {
            lock.withLock { isPainting = false }
            continuation.yield(bytes)
            waiting.resume(returning: .success(()))
          } else {
            lock.withLock { isPainting = false }
            waiting.resume(returning: .failure(AppError.herdrResponseUnreadable))
          }
        case .failure(let failure):
          lock.withLock { isPainting = false }
          waiting.resume(returning: .failure(failure))
        }
      }
    }
    try painted.get()
  }

  /// Sizes the window to this viewer, if it is one that does.
  func sizeWindow() async {
    let target: (window: String, size: TerminalSize, client: TmuxSessionClient)? = lock.withLock {
      guard isController, resizes, !awaitsTouch, !isReleased else { return nil }
      return (currentWindow, size, owner)
    }
    guard let target else { return }
    await target.client.size(target.window, to: target.size, for: self)
  }

  // MARK: PaneBridge

  func send(text: String) async throws {
    try await send(bytes: Data(text.utf8))
  }

  func send(bytes: Data) async throws {
    try await touched()
    guard !lock.withLock({ isReleased }) else { throw TerminalCloseReason.streamEnded }
    try client.type(bytes, into: pane)
  }

  /// Remembered for a promotion that nobody has touched yet, and for an observer.
  func resize(to size: TerminalSize) async throws {
    let changed: Bool = lock.withLock {
      defer { self.size = size }
      return self.size != size
    }
    if changed { await sizeWindow() }
  }

  /// A drag and a tap are worked out on the local emulator, so a feed over this has neither.
  func scroll(_ direction: ScrollDirection, lines: Int) async throws {}
  func click(_ cell: TerminalCell) async throws {}

  func release() async {
    let client: TmuxSessionClient? = lock.withLock {
      guard !isReleased else { return nil }
      isReleased = true
      return owner
    }
    guard let client else { return }
    continuation.finish()
    await client.detach(self)
  }

  // MARK: PromotableObserver

  /// Becomes a viewer that can type, on the same stream. The window keeps its size until someone
  /// touches this one.
  func promote() async throws -> any PaneBridge {
    try lock.withLock {
      guard !isReleased else { throw TerminalCloseReason.streamEnded }
      isController = true
      awaitsTouch = true
    }
    return self
  }

  /// The first touch of a promoted viewer: the window comes to its size, and the screen is
  /// painted again, with history, at that size. An observer's paint had neither.
  private func touched() async throws {
    let isFirst: Bool = lock.withLock {
      guard awaitsTouch else { return false }
      awaitsTouch = false
      // The window's new size reflows the pane, and the repaint covers it.
      isPainting = true
      return true
    }
    guard isFirst else { return }
    await sizeWindow()
    try await paint(history: TmuxPaint.historyLines, clearing: true)
  }

  // MARK: RawTerminalStream

  /// tmux's output to a control client is not held to credit.
  func consumed(_ bytes: Int) {}

  /// A gain is a touch for a promoted viewer, as a core's is. tmux takes no focus from a control
  /// client, so nothing else is sent.
  func focus(_ gained: Bool) async throws {
    if gained { try await touched() }
  }

  /// The first paint carries the normal screen behind an alternate one, so there is nothing to
  /// fetch.
  func leftAlternateScreen() {}
}

/// Resumes a wait once, with whichever answer comes first: the work's, or `otherwise` after the
/// deadline. Not a task group, because a group waits for the child that never answers.
final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: CheckedContinuation<Value, Never>?
  private var sleeper: Task<Void, Never>?

  private init() {}

  /// The first call answers the wait and cancels the deadline's sleeper; later ones do nothing.
  func resume(_ value: Value) {
    let (waiting, sleeper) = lock.withLock {
      defer {
        self.waiting = nil
        self.sleeper = nil
      }
      return (self.waiting, self.sleeper)
    }
    sleeper?.cancel()
    waiting?.resume(returning: value)
  }

  /// Starts the work with `start`, which calls `resume` when it has an answer.
  static func within(
    _ limit: Duration,
    otherwise fallback: Value,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ start: @escaping @Sendable (FirstAnswer<Value>) -> Void
  ) async -> Value {
    let answer = FirstAnswer<Value>()
    return await withCheckedContinuation { continuation in
      answer.lock.withLock { answer.waiting = continuation }
      // In place before `start`, which can answer before it returns.
      let sleeper = Task {
        do { try await sleep(limit) } catch { return }
        answer.resume(fallback)
      }
      answer.lock.withLock { answer.sleeper = sleeper }
      start(answer)
    }
  }
}

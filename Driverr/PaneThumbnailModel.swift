import DriverrCore
import DriverrHerdr
import Foundation
import Observation
import os

/// What each tile in the pane sheet draws, and what it costs.
///
/// - Warm: the current pane and its observers have a live emulator in the view
///   hierarchy, so their lines come from `TerminalSession.visibleLines(last:)` at no cost.
/// - Cold: everything else is one batched `readPanes` per tick while the sheet is open.
///   One exec channel for the whole grid, not one per tile.
///
/// A live `observe` stream per cold tile would run a herdr process per tile on the user's
/// machine. The two look the same on screen, so `PaneThumbnailModelTests` asserts which
/// one runs.
@MainActor
@Observable
final class PaneThumbnailModel {
  /// How many rows a tile draws: enough to tell a build log from a question.
  static let lineCount = 6

  /// How many batches in a row must fail before the sheet says so. One failure is swallowed,
  /// because the picture on screen is a better answer than a notice gone in one tick.
  static let failedReadsBeforeReporting = 2

  /// How many successful but entirely empty batches in a row are logged as suspicious.
  static let emptyReadsBeforeReporting = 3

  private static let logger = Logger(
    subsystem: "com.cunderw.driverr",
    category: "paneThumbnails"
  )

  /// The last lines read for each cold pane, keyed by pane id. Kept across a failed read,
  /// because a stale picture says more than an empty rectangle.
  private(set) var cold: [String: [String]] = [:]

  /// Why the cold tiles have stopped updating, or `nil` while reads work and through the
  /// first failure. See `failedReadsBeforeReporting`.
  private(set) var readFailure: String?

  /// Whether any batch has come back, however it went. The sheet draws a redacted
  /// placeholder until then, because an empty tile looks like an empty pane. A failed batch
  /// sets it too, so an outage does not shimmer for ever.
  private(set) var hasRead = false

  /// Every cold pane has answered with nothing, several ticks running.
  ///
  /// Logged, not shown. A broken read that exits 0 with empty output looks like this, but so
  /// does a session of quiet panes, so a notice would cry wolf. `private(set)` so a test can
  /// assert it without reading the log.
  private(set) var isReadingNothing = false

  /// Consecutive batches that threw, and consecutive batches that answered emptily. Two
  /// counters because "could not ask" and "asked and got nothing" are different failures.
  @ObservationIgnored private var failedReads = 0
  @ObservationIgnored private var emptyReads = 0

  /// Resolved per read, because the connection can go while the sheet is open.
  @ObservationIgnored private let control: @MainActor () -> (any HerdrControl)?
  /// The tiles the sheet is showing, in its order, so nothing is read for a tile off
  /// screen.
  @ObservationIgnored private let targets: @MainActor () -> [TerminalTarget]
  /// A target's own emulator, when the scene is holding one for it.
  @ObservationIgnored private let warmLines: @MainActor (TerminalTarget) -> [String]?
  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private var poll: Task<Void, Never>?

  /// - Parameter interval: how often to re-read the cold panes. `SessionModel`'s poll
  ///   interval by default, so the tiles and the Panes button's count do not drift apart.
  init(
    control: @escaping @MainActor () -> (any HerdrControl)?,
    targets: @escaping @MainActor () -> [TerminalTarget],
    warmLines: @escaping @MainActor (TerminalTarget) -> [String]?,
    interval: Duration = SessionModel.defaultPollInterval
  ) {
    self.control = control
    self.targets = targets
    self.warmLines = warmLines
    self.interval = interval
  }

  /// The rows to draw in one tile: live if the scene is holding that target, the last
  /// batch's if not, and nothing at all if neither has anything to say yet.
  func lines(for target: TerminalTarget) -> [String] {
    if let warm = warmLines(target) { return warm }
    guard case .pane(let id) = target else { return [] }
    return cold[id] ?? []
  }

  /// The sheet appeared: read the cold panes now, and keep them current while it is up.
  /// Idempotent, because `.onChange` can fire more than once for one change.
  func open() {
    guard poll == nil else { return }
    poll = Task { [weak self, interval] in
      // Read first, then wait, so the grid does not sit empty for a whole tick.
      await self?.refresh()
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { return }
        await self.refresh()
      }
    }
  }

  /// The sheet went away. Stop reading the host.
  func close() {
    poll?.cancel()
    poll = nil
    // The pictures survive a close and the failure state does not. This model outlives the
    // sheet, so a kept notice would greet the next opening before any read.
    readFailure = nil
    failedReads = 0
    isReadingNothing = false
    emptyReads = 0
    // A tile with a held picture draws it, so this only redacts panes not yet known.
    hasRead = false
  }

  /// One batch for every tile the scene holds no emulator for.
  ///
  /// Warmth is re-checked every tick, because picking a pane from the sheet changes the
  /// warm set. Internal, one tick per call, so tests can assert which tick first reports a
  /// failure.
  func refresh() async {
    let showing = targets()
    let coldIDs = showing.compactMap { target -> String? in
      guard warmLines(target) == nil, case .pane(let id) = target else { return nil }
      return id
    }
    // Drop panes that closed or warmed up since the last read.
    cold = cold.filter { coldIDs.contains($0.key) }
    // Every tile is warm, so there is nothing to wait for.
    guard !coldIDs.isEmpty else {
      hasRead = true
      return
    }
    // **No control counts as a failed read, not a skipped one.** `control` is `nil` while
    // the link is down, and skipping would freeze the tiles with no notice.
    guard let control = control() else {
      noteFailure(AppError.notConnected(host: "this host"))
      return
    }

    let read: [String: [String]]
    do {
      read = try await control.readPanes(ids: coldIDs, lines: Self.lineCount)
    } catch {
      noteFailure(error)
      return
    }

    hasRead = true
    failedReads = 0
    readFailure = nil
    cold.merge(read) { _, new in new }
    noteEmptiness(of: read)
  }

  /// A batch that could not run. The pictures stay. One failure is swallowed and a run is
  /// reported.
  private func noteFailure(_ error: any Error) {
    hasRead = true
    failedReads += 1
    guard failedReads >= Self.failedReadsBeforeReporting else { return }
    let reason = (error as? AppError)?.errorDescription ?? error.localizedDescription
    // Logged once, on the tick the failure becomes a run, not on every tick after.
    if failedReads == Self.failedReadsBeforeReporting {
      // The reason can hold text the remote host produced, so it takes `Logger`'s default
      // redaction. The kind is a case or type name from this source, so it is `.public`.
      let kind =
        Mirror(reflecting: error).children.first?.label ?? String(describing: type(of: error))
      Self.logger.error(
        """
        pane thumbnails: \(Self.failedReadsBeforeReporting) reads in a row failed \
        (\(kind, privacy: .public)): \(reason)
        """
      )
    }
    readFailure = "Couldn't read the other panes. \(reason)"
  }

  /// A batch that answered nothing for every pane. See `isReadingNothing`.
  private func noteEmptiness(of read: [String: [String]]) {
    guard read.values.allSatisfy(\.isEmpty) else {
      emptyReads = 0
      isReadingNothing = false
      return
    }
    emptyReads += 1
    guard emptyReads >= Self.emptyReadsBeforeReporting else { return }
    if !isReadingNothing {
      Self.logger.warning(
        """
        pane thumbnails: \(read.count) panes read back with no lines at all, \
        \(Self.emptyReadsBeforeReporting) ticks running. Either the session is entirely \
        quiet or the read itself is wrong.
        """
      )
    }
    isReadingNothing = true
  }
}

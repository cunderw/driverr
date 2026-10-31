import Foundation

/// What to do about a bridge session that ended. Three facts in, one of three answers out,
/// so `swift test` can hold the rule.
///
/// A stream ending is not a pane closing. `.streamEnded` is the case herdr never stated: the
/// channel went with no `terminal.closed` record, as on a phone whose link died while
/// suspended or against a restarted herdr. `detached` (a client leaving) and `server is
/// shutting down` are stated by herdr but are not closes either. Every other unrecognised
/// reason still reads as a close. A bridge process that exits nonzero (`.processFailed`) is
/// answered with `.failed` and no reattach, because rerunning a command that refused is a
/// loop.
public enum TerminalEndDisposition: Equatable, Sendable {
  /// Reopen the pane's surface silently. The last frame stays on screen, so a reattach that
  /// works is invisible.
  case reattach
  /// The pane is gone: the closed banner.
  case closed
  /// Driverr cannot get the pane back: a sentence and a Retry, never the closed banner,
  /// because saying a pane closed when Driverr does not know is the thing to avoid. The
  /// sentence travels with the case because each arrival is different news.
  case failed(message: String)
  /// A new shell is coming to this terminal. Try again until it answers, and say so meanwhile.
  case awaitRestart

  /// What a terminal says while `awaitRestart` runs.
  public static let awaitingRestartMessage = "Waiting for a new shell."

  /// The sentence for a reattach that did not take. Pinned by a test.
  ///
  /// It says what happened, not why, because a restarted herdr, a host killing streams and
  /// an exited command look identical from here. No mechanism words, and short enough (the
  /// bar's notices run 18 to 41 characters) to fit the phone's bar on one line.
  public static let reattachFailedMessage = "This pane stopped answering."

  /// The sentence for a herdr that said it was shutting down, the one end where Driverr has
  /// herdr's word for the cause. Naming herdr is actionable, because the reader can restart
  /// it. Within the same 18 to 41 character band.
  public static let serverStoppedMessage = "herdr stopped on the host."

  /// The fallback for a bridge process that exited nonzero with nothing on stderr. When
  /// herdr wrote something, its own words are shown instead.
  ///
  /// "attach", not "open this pane", because the pane may still be running.
  public static let paneFailedMessage = "herdr could not attach."

  /// The sentence for a held-back core attach that never happened, the same one a refused
  /// open gets.
  public static let neverAttachedMessage = "The pane could not be opened."

  /// The lead-in for a message from the far side, so the bar never seems to speak in
  /// Driverr's voice.
  ///
  /// herdr writes fragments (lowercase, no full stop, sometimes a bare path). Editing them
  /// would mangle the least prose-like ones, so the lead-in carries the register and says
  /// whose claim it is.
  public static let remoteMessageLeadIn = "herdr said: "

  /// How long a message from the far side may be before it is truncated.
  ///
  /// A display rule: the notice bar has no `lineLimit`, and 120 characters is about two
  /// lines on the narrowest supported phone. Applied where the message becomes a notice, so
  /// no caller can skip it.
  public static let messageLimit = 120

  /// Trims, attributes and bounds a message from the far side, or returns `nil` for an empty
  /// or whitespace-only one. The bound covers the lead-in too, because it protects the bar's
  /// width.
  static func boundedMessage(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let line = remoteMessageLeadIn + trimmed
    guard line.count > messageLimit else { return line }
    // One character goes to the ellipsis, so the result is exactly `messageLimit` long.
    return String(line.prefix(messageLimit - 1)) + "\u{2026}"
  }

  /// Reads a session's end.
  ///
  /// - Parameters:
  ///   - reason: why the bridge session ended. `.refused` and `.takenOver` are answered by
  ///     the scene before this is asked, and read as `.closed` here so the function is total.
  ///   - statedByHerdr: whether a `terminal.closed` record was read off the stream. **Not the
  ///     same as `reason != .streamEnded`.** herdr's ordinary `paneClosed` finishes the stream
  ///     cleanly, and `TerminalSceneModel.controllerFeed` labels that `.streamEnded` for its
  ///     token accounting. A stated close is a close whatever its label, except `.detached`
  ///     and `.serverShuttingDown`, which are read before this flag.
  ///   - paneIsStillInTree: whether herdr's latest snapshot lists this pane. A pane missing
  ///     from it is closed even if the record was lost. A pane closed a moment ago is still
  ///     listed and gets one pointless reattach, which herdr answers with a close.
  ///   - reattachAttempts: automatic reattaches since the last painted frame. A frame resets
  ///     it, so a flaky link always gets a retry and a host that kills every stream gets one.
  ///     This bound stops a loop.
  public static func forSessionThatEnded(
    reason: TerminalCloseReason,
    statedByHerdr: Bool,
    paneIsStillInTree: Bool,
    reattachAttempts: Int
  ) -> TerminalEndDisposition {
    // herdr's own non-close reasons are read before `statedByHerdr`, or the stated-close
    // case below would give them the closed banner.
    switch reason {
    // A kept terminal stays listed through a loss, so a pane gone from the tree has been
    // removed since, and no shell is coming to it.
    case .lost:
      return paneIsStillInTree ? .awaitRestart : .closed
    // No stream ever ran, so there is nothing to reattach and nothing to call closed.
    case .neverAttached:
      return .failed(message: neverAttachedMessage)
    // The bridge process ran and refused. It arrives with no `terminal.closed` record, and
    // the pane may still be running. No reattach: the same command would get the same
    // answer, so retrying is the reader's Retry. Shows herdr's own words when it left any.
    case .processFailed(_, let message):
      return .failed(message: boundedMessage(message) ?? paneFailedMessage)
    // herdr is stopping. Nothing to reattach to, and trying again does not help.
    case .serverShuttingDown:
      return .failed(message: serverStoppedMessage)
    // A `detached` that reaches here is herdr dropping our client for its own reason, so it
    // reads like a stream that stopped. Our own hand-back never reaches here, because
    // `controllerFeed` and `observerFeed` check `Task.isCancelled` first. Without that check
    // this would re-take the attach token the user's switch to Chat just released.
    case .detached:
      return afterAnEndThatLeftThePaneRunning(
        paneIsStillInTree: paneIsStillInTree,
        reattachAttempts: reattachAttempts
      )
    // herdr spoke, so the answer is herdr's. See `statedByHerdr`.
    case .streamEnded where statedByHerdr:
      return .closed
    // The scene's own banners, plus `.other`: an unknown reason from a newer herdr is safer
    // over-reported as a close than silently reattached against.
    case .paneClosed, .other, .refused, .takenOver:
      return .closed
    case .streamEnded:
      return afterAnEndThatLeftThePaneRunning(
        paneIsStillInTree: paneIsStillInTree,
        reattachAttempts: reattachAttempts
      )
    }
  }

  /// The answer for an end that says nothing about the pane: is it still there, and has a
  /// reattach already been tried?
  private static func afterAnEndThatLeftThePaneRunning(
    paneIsStillInTree: Bool,
    reattachAttempts: Int
  ) -> TerminalEndDisposition {
    if !paneIsStillInTree {
      return .closed
    } else if reattachAttempts < 1 {
      return .reattach
    } else {
      return .failed(message: reattachFailedMessage)
    }
  }
}

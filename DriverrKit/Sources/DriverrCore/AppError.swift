import Foundation

/// Every failure Driverr shows a human, in the app's own vocabulary.
///
/// `DriverrSSH` and `DriverrHerdr` map their upstream errors into these cases, so no
/// upstream error type or wording reaches a view.
public enum AppError: Error, Hashable, Sendable, LocalizedError {
  case connectionFailed(host: String, reason: String)
  case authenticationFailed(host: String)
  /// A password host was asked to connect with nothing to offer.
  ///
  /// Not `authenticationFailed`: nothing was sent, so "refused by the server" would send
  /// the user to check their account when the password field in front of them is empty.
  case passwordRequired(host: String)
  /// The host presented a different key than the one trusted. Distinct from
  /// `hostKeyRejected`, because this is the man-in-the-middle shape.
  case hostKeyMismatch(host: String)
  /// The user declined to trust a host key they were shown.
  case hostKeyRejected(host: String)
  case channelFailed(reason: String)
  /// Driverr has no live connection to use: the guard before a send, a screen read or a
  /// transcript fetch.
  ///
  /// Its own case, with its own sentence, so a dropped link does not read as "the session
  /// could not start" on every surface at once.
  case notConnected(host: String)
  case disconnected(reason: String)
  /// An imported key could not be used. `reason` is already user-facing.
  case keyImportFailed(reason: String)
  /// herdr is not on the host, or not where Driverr looked. Never rendered like a wrong
  /// password, because the next action is entirely different.
  case herdrNotInstalled
  /// A tmux Driverr found stopped running as a command. Its own case, because the herdr one
  /// would send the user to install herdr on a host that never needed it.
  case tmuxNotInstalled
  /// Driverr has no way to show this pane's terminal yet. Not retryable: asking again opens
  /// the same nothing.
  ///
  /// A tmux pane, until the live tmux terminal lands. Its chat and its composer still work.
  case paneTerminalUnavailable
  /// herdr, herdr-core or tmux ran and refused, or failed. Carries what that program said.
  case herdrCommandFailed(reason: String)
  /// The host was reached and the SSH handshake completed, but the search for herdr and tmux
  /// never finished. The sentence names both, because the search has not yet said which.
  ///
  /// Not `connectionFailed`, whose "Could not reach <host>" would contradict itself and send
  /// the reader to check the network. Not `herdrCommandFailed`, which would drop the host
  /// name and the retryable shape.
  case herdrDidNotAnswer(host: String)
  /// herdr, herdr-core or tmux answered with something Driverr could not parse, most likely a
  /// newer protocol. The sentence says "the host", because all three throw it.
  case herdrResponseUnreadable
  /// A transcript Driverr had located could not be read off the host: deleted since, or not
  /// readable by the login account. A file that ends mid-record or holds no conversation is
  /// a `Transcript` outcome, not this.
  case transcriptUnreadable(reason: String)
  /// A folder the user asked to browse could not be opened on the host: missing, not a
  /// folder, or not readable by the login account. `path` is what the user asked for.
  case directoryUnavailable(path: String)
  /// An agent's first message is too long to type into a new shell. Nothing was opened. See
  /// `AgentLaunch.typedLineLimit`.
  case agentPromptTooLong
  /// A workspace, window or terminal was opened for an agent, and the agent did not start in
  /// it. The pane stays open, so the person can read what the shell said there.
  ///
  /// `paneID` is that pane, so a caller can open it. `place` is the folder's name, which is
  /// what the new workspace, window or space is called.
  case agentDidNotStart(paneID: String, place: String, reason: String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case let .connectionFailed(host, reason):
      "Could not reach \(host). \(reason)"
    case let .authenticationFailed(host):
      "Authentication was refused by \(host). Check the username and credentials."
    case let .passwordRequired(host):
      "Enter the password for \(host) to connect."
    case let .hostKeyMismatch(host):
      // Names the button that gets out of it, "Forget Host Key…", so a rebuilt server does
      // not read as a permanent lockout.
      """
      The host key for \(host) has changed. This can mean the server was rebuilt, \
      or that the connection is being intercepted. Driverr will not connect until you \
      choose Forget Host Key.
      """
    case let .hostKeyRejected(host):
      "The host key for \(host) was not trusted, so the connection was stopped."
    case let .channelFailed(reason):
      // The reason alone, as with `herdrCommandFailed`. A fixed headline would contradict
      // some reasons.
      reason
    case let .notConnected(host):
      "Driverr isn't connected to \(host)."
    case let .disconnected(reason):
      "The connection dropped. \(reason)"
    case let .keyImportFailed(reason):
      reason
    case .herdrNotInstalled:
      // An SSH exec channel runs a non-login shell, so this does not say "login shell's
      // PATH": a user would find herdr there and conclude Driverr is broken.
      "herdr is not installed on this host, or isn't on the PATH this connection uses."
    case .tmuxNotInstalled:
      "tmux is not installed on this host, or isn't on the PATH this connection uses."
    case .paneTerminalUnavailable:
      "Driverr can't show this pane's terminal yet."
    case let .herdrCommandFailed(reason):
      reason
    case let .herdrDidNotAnswer(host):
      "Reached \(host), but it stopped answering while Driverr looked for herdr and tmux."
    case .herdrResponseUnreadable:
      "The host answered with something this version of Driverr does not understand."
    case let .transcriptUnreadable(reason):
      // The reason alone. `TranscriptNotice(failure:)`'s title already says the file could
      // not be read.
      reason
    case let .directoryUnavailable(path):
      "Could not open \(path) on this host. Check that the folder exists and that you can read it."
    case .agentPromptTooLong:
      "The first message is too long to start an agent with. Shorten it, and send the rest once the agent is running."
    case let .agentDidNotStart(_, place, reason):
      "Opened \(place), but the agent did not start there. \(reason)"
    case .cancelled:
      "Cancelled."
    }
  }

  /// Whether a Retry button makes sense. Never for a key mismatch, where retrying is the
  /// wrong response to a possible interception.
  public var isRetryable: Bool {
    switch self {
    case .connectionFailed, .disconnected, .channelFailed, .notConnected: true
    case .authenticationFailed, .hostKeyMismatch, .hostKeyRejected, .cancelled: false
    // The missing thing is a password, and the field is on screen.
    case .passwordRequired: false
    case .keyImportFailed: false
    // Retrying a missing binary or an unreadable protocol changes nothing. A failed command
    // may succeed next time.
    case .herdrNotInstalled, .tmuxNotInstalled, .herdrResponseUnreadable: false
    case .paneTerminalUnavailable: false
    case .herdrCommandFailed: true
    // The far side stopped answering, which a second attempt can clear.
    case .herdrDidNotAnswer: true
    // A session file can be rotated out from under a read, so asking again is reasonable.
    case .transcriptUnreadable: true
    // A missing or locked folder stays that way until the user picks another.
    case .directoryUnavailable: false
    // The same message stays too long.
    case .agentPromptTooLong: false
    // The pane is open with the shell's answer in it. Another attempt would open another one.
    case .agentDidNotStart: false
    }
  }
}

/// Which herdr session something names: a socket path, a herdr client's `--session` flag, or a
/// herdr pane's environment.
///
/// Two of these are equal when they name the same session. A host is bound to one by
/// `Host.herdrSocketPath`, and a pane that shows a herdr session names one, so the two compare.
public enum HerdrSessionKey: Hashable, Sendable {
  /// The session herdr runs with no `--session`.
  case standard
  /// A session started with `--session <name>`.
  case named(String)
  /// A socket path herdr's own layout does not explain, compared as it is written.
  case socket(String)

  /// The session a socket path belongs to. `nil` or empty is the standard session.
  ///
  /// herdr keeps a named session's socket at `…/sessions/<name>/herdr.sock` and the standard
  /// session's at `…/herdr.sock`, under its configuration directory. Only the end of the path is
  /// read, so `~` and `$HOME` spellings of one directory agree. Any other path is compared
  /// whole.
  public init(socketPath: String?) {
    self = .standard
  }

  /// The file name of herdr's socket in every session's directory.
  static let socketName = "herdr.sock"
}

/// One pane that shows another source of panes on the same host, and the herdr session the host
/// must list for that pane to be a duplicate.
///
/// One shape covers both ways round:
///
/// - **herdr in tmux.** A tmux pane runs a herdr client. `paneID` is the tmux pane, and
///   `session` is the herdr session the client shows.
/// - **tmux in herdr.** A herdr pane runs a tmux client. `paneID` is the herdr pane, from the
///   client's `HERDR_PANE_ID`, and `session` is the herdr session that pane is in.
///
/// Either way the panes behind it are listed on their own. A claim hides nothing unless the
/// host lists that herdr session, because otherwise the mirror is the only way to its panes.
public struct MirrorClaim: Hashable, Sendable {
  /// The pane to hide, as the tree's ids spell it.
  public let paneID: String
  public let session: HerdrSessionKey

  public init(paneID: String, session: HerdrSessionKey) {
    self.paneID = paneID
    self.session = session
  }
}

extension SessionTree {
  /// This tree with `paneIDs` marked `isMirror`, and every other field as it was.
  public func markingMirrors(_ paneIDs: Set<String>) -> SessionTree {
    self
  }

  /// This tree without its mirror panes, then without the tabs and workspaces that left empty.
  ///
  /// `paneID` stays whatever it is, for a scene already open on it. A focused pane that is
  /// hidden is no longer the focus. A tab or workspace that was empty already stays.
  public func hidingMirrors(keeping paneID: String? = nil) -> SessionTree {
    self
  }
}

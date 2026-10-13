/// Whether the host screen shows the connection details, or just the pill they fold
/// behind.
///
/// Tapping a host row starts a connect, so showing the details during that connect would
/// flash an unrequested form (address, password, Keychain footer) for the length of the
/// handshake. So the answer depends on who started the connect.
public enum ConnectionDetailsDisclosure {

  /// Who asked for the connect that is running.
  public enum Attempt: Sendable, Hashable {
    /// The screen started it on appearance, with a credential Driverr could offer unasked.
    case unattended
    /// Somebody typed a password or pressed Connect. If it fails on a typo, the field to fix
    /// is the one they just used.
    case user
  }

  /// Whether the details are showing.
  ///
  /// - Parameters:
  ///   - isConnected: Whether the connection is up. Then the tree is the screen.
  ///   - attempt: The connect in flight, and who started it, or `nil` when none is.
  ///   - userChoice: What the person looking at the screen last said by tapping the
  ///     disclosure itself, or `nil` if they have not said anything.
  public static func isShowing(
    isConnected: Bool,
    attempt: Attempt?,
    userChoice: Bool?
  ) -> Bool {
    // A tap always wins, in both directions.
    if let userChoice { return userChoice }
    // Connected: the pill and the session tree.
    if isConnected { return false }
    // An unattended attempt looks like a connected one, so the tap moves the screen through
    // one appearance, not two. Cancel sits beside the pill for this reason; see
    // `HostDetailView.connectionSection`.
    if attempt == .unattended { return false }
    // Idle, failed, lost, or a user's attempt: the details are the answer.
    return true
  }
}

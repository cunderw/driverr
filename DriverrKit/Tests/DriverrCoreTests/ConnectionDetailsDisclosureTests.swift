import Testing

@testable import DriverrCore

/// Whether the host screen shows its connection details. Tapping a host connects at once,
/// and the form must not flash on the way.
@Suite("ConnectionDetailsDisclosure")
struct ConnectionDetailsDisclosureTests {
  private func isShowing(
    isConnected: Bool = false,
    attempt: ConnectionDetailsDisclosure.Attempt? = nil,
    userChoice: Bool? = nil
  ) -> Bool {
    ConnectionDetailsDisclosure.isShowing(
      isConnected: isConnected,
      attempt: attempt,
      userChoice: userChoice
    )
  }

  /// Covers the frames before the handshake starts too: the phase is idle while
  /// `HostDetailView` reads the saved password, and the attempt is already `.unattended`.
  @Test("an unattended attempt keeps the details folded away")
  func unattendedFolds() {
    #expect(isShowing(attempt: .unattended) == false)
  }

  /// Someone who typed a password may need to fix a typo.
  @Test("an attempt the user started leaves the details open")
  func userAttemptStaysOpen() {
    #expect(isShowing(attempt: .user))
  }

  @Test("a connected host folds them away")
  func connectedFolds() {
    #expect(isShowing(isConnected: true) == false)
  }

  /// The form is the only thing on the screen that does anything.
  @Test("an idle host shows them")
  func idleShows() {
    #expect(isShowing())
  }

  /// Asserted as a transition: the fold ends with the attempt. A single `attempt: nil`
  /// assertion would repeat `idleShows`.
  @Test("the fold ends when the attempt does")
  func settledShows() {
    #expect(isShowing(attempt: .unattended) == false)
    #expect(isShowing(attempt: nil))
  }

  /// A dropped link must not leave Reconnect folded away. The predicate cannot tell a loss
  /// from an idle host; `HostDetailView.onChange(of:)` clears the user's choice when the phase
  /// leaves `.connected`, and this pins that a cleared choice opens the details.
  @Test("clearing the user's choice is what reopens them after a loss")
  func lostShows() {
    #expect(isShowing(userChoice: false) == false)
    #expect(isShowing(userChoice: nil))
  }

  @Test("a tap to open wins over an unattended attempt")
  func tapOpenWins() {
    #expect(isShowing(attempt: .unattended, userChoice: true))
    #expect(isShowing(isConnected: true, userChoice: true))
  }

  @Test("a tap to close wins over an idle host")
  func tapCloseWins() {
    #expect(isShowing(userChoice: false) == false)
    #expect(isShowing(attempt: .user, userChoice: false) == false)
  }
}

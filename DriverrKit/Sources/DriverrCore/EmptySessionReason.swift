/// Why a host's session tree draws no rows, so the empty copy does not say there is nothing
/// there when there is.
///
/// A host's shown tree is its reported tree without the machines another connected host shows
/// as its own (`SessionTree.hidingMachines(coveredBy:keeping:)`). When every group is covered,
/// the shown tree is empty while the host still reported terminals.
public enum EmptySessionReason: Equatable, Sendable {
  /// The host reported nothing open.
  case nothingOpen
  /// The host reported terminals, and another connected host shows all of them.
  case shownUnderAnotherHost

  /// `nil` when `shown` has rows to draw.
  public init?(shown: SessionTree, reported: SessionTree) {
    guard shown.isEmpty else { return nil }
    self = .nothingOpen
  }
}

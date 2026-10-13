/// Which way a terminal's history scrolls.
///
/// Here because `DriverrTerm` produces it from a drag and `DriverrHerdr` sends it as
/// `terminal.scroll`, and neither may import the other.
public enum ScrollDirection: String, Hashable, Sendable {
  /// Back through history.
  case up
  /// Forward, towards the live output.
  case down
}

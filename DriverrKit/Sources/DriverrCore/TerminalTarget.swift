/// What a terminal scene can show: the plain shell it was opened with, or a herdr pane.
///
/// One scene per host, showing one thing at a time. Switching changes this value; it is
/// not a new presentation.
public enum TerminalTarget: Hashable, Sendable {
  case shell
  case pane(id: String)
}

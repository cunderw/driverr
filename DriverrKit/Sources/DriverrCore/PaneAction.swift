/// Which way a pane splits.
///
/// Two cases because herdr has two. The switcher's New pane cell only asks for `.right`,
/// but both stay mapped in `CLIControl.arguments`.
public enum SplitDirection: String, Hashable, Sendable {
  case right
  case down
}

/// Something Driverr can do to one pane, other than typing into it.
///
/// One type, so the UI can list actions, the fake can record them, and a test can compare
/// one value. Sending text is not here; the composer does that with its own payload.
public enum PaneAction: Hashable, Sendable {
  case split(SplitDirection)
  case rename(String)
  case close

  /// Whether doing this can lose work.
  ///
  /// Only `close` can: it ends the pane and what runs in it. The UI confirms it.
  public var isDestructive: Bool {
    switch self {
    case .close: true
    case .split, .rename: false
    }
  }
}

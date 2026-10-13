import Foundation

/// Something other than a pane that Driverr can rename.
///
/// A pane's rename is a `PaneAction`, alongside its other actions. A workspace and a tab
/// have only rename from a phone, so this is a target that `HerdrControl.rename(_:to:)`
/// takes beside the label. No `.pane` case, which would give one command two spellings.
public enum RenameTarget: Hashable, Sendable {
  case workspace(id: String)
  case tab(id: String)

  /// herdr's id for the thing being renamed, the command's first argument.
  public var id: String {
    switch self {
    case .workspace(let id), .tab(let id): id
    }
  }
}

/// What a label has to be before it is worth sending.
///
/// An enum of statics rather than a method on `RenameTarget`, because the rule is about the
/// label, whatever is being renamed.
public enum RenameLabel {
  /// The label as it should go over, or `nil` when there is nothing there to send.
  ///
  /// Empty and whitespace-only give `nil`, not a trimmed empty string. `shellQuoted` sends
  /// `''` faithfully, so this is the only place an unreadable empty name is caught before
  /// herdr. Only the ends are trimmed; interior spacing is part of the name.
  public static func sanitised(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Whether this draft would change anything if it were sent.
  ///
  /// An unchanged label is a cancel, as `PaneActionsModel.commitRename` treats it for panes.
  /// Sending it could still fail and show an error for nothing.
  public static func isWorthSending(_ raw: String, whenCurrentLabelIs current: String) -> Bool {
    guard let label = sanitised(raw) else { return false }
    return label != current
  }
}

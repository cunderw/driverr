/// The sub-agent conversations a pane's chat has opened, newest on top.
///
/// A pane's chat shows its own conversation when this is empty and the top entry when it is
/// not. Nothing is pushed onto the navigation stack for it: `PhoneStackPath` does not change,
/// and a back bar in the chat pops this instead.
///
/// Generic over the entry so the rule is asserted here without the app's model type. The app
/// holds one per pane, on `PaneTranscriptModel`.
public struct SubagentStack<Entry> {
  public private(set) var entries: [Entry] = []

  public init() {}

  /// How many sub-agents deep the chat is. `0` is the pane's own conversation.
  public var depth: Int { entries.count }

  public var isEmpty: Bool { entries.isEmpty }

  /// What the chat shows, or `nil` for the pane's own conversation.
  public var top: Entry? { entries.last }

  public mutating func push(_ entry: Entry) {
    entries.append(entry)
  }

  /// Removes the top entry and returns it. `nil`, and no change, when the chat already shows
  /// the pane's own conversation.
  @discardableResult
  public mutating func pop() -> Entry? {
    entries.popLast()
  }

  /// Back to the pane's own conversation, and every entry that was open, top first.
  @discardableResult
  public mutating func removeAll() -> [Entry] {
    defer { entries = [] }
    return entries.reversed()
  }
}

extension SubagentStack: Sendable where Entry: Sendable {}

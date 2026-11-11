/// The sub-agent conversations a pane's chat has opened, newest on top.
///
/// On the phone a non-empty stack is `PhoneStackPath.Route.subagent`, pushed over the pane's
/// own chat, and the system back button pops it. On iPad the detail column cannot push, so the
/// pane's chat shows the top entry in place and a named back control pops it. The app opens at
/// most one at a time.
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

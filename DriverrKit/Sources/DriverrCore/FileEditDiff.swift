import Foundation

/// The change an agent's `Edit`, `MultiEdit` or `Write` call asked for, read off the call's
/// own arguments, and the diff that draws it.
///
/// **Built from the strings, never parsed as a patch.** A `new_string` line that opens with
/// `@@ ` or `+++ ` is file content, and `TranscriptDiff.parse` would read it as a hunk header
/// or a file header. Each side is split into lines and compared with
/// `Array.difference(from:)`, so every line keeps the type the comparison gave it.
///
/// The arguments say what the agent asked for, not what reached the disk. A call that came
/// back failed still carries its edit.
public struct FileEdit: Hashable, Sendable {
  /// One `old_string` and the `new_string` that replaces it.
  public struct Replacement: Hashable, Sendable {
    public let old: String
    public let new: String

    public init(old: String, new: String) {
      self.old = old
      self.new = new
    }
  }

  public enum Change: Hashable, Sendable {
    /// An `Edit` (one replacement) or a `MultiEdit` (several, applied in order).
    case replacements([Replacement])
    /// A `Write`: the file's whole new content.
    case write(String)
  }

  /// The path exactly as the call gave it, usually absolute.
  public let filePath: String
  public let change: Change
  /// The change as diff lines. Computed once here, because a chat row's body is evaluated
  /// on every poll and scroll.
  public let diff: TranscriptDiff

  public init(filePath: String, change: Change) {
    self.filePath = filePath
    self.change = change
    self.diff = TranscriptDiff(filePath: filePath, lines: Self.lines(of: change))
  }

  // MARK: - How much of it a card draws

  /// How many lines a card draws before `Show All`. About a phone screen's third at the
  /// default text size, so several edits in one run stay readable together.
  public static let collapsedLines = 12

  /// The most lines a card draws even when expanded. A `Write` can carry a whole file (one
  /// real call was 1,920 lines), and every line is a row in the view.
  public static let expandedLineCap = 400

  /// Whether the card has more lines than it draws collapsed, which is when it offers
  /// `Show All`.
  public var isCollapsible: Bool { diff.lines.count > Self.collapsedLines }

  /// The lines a card draws, collapsed or expanded.
  public func shownLines(isExpanded: Bool) -> [TranscriptDiff.Line] {
    let limit = isExpanded ? Self.expandedLineCap : Self.collapsedLines
    return Array(diff.lines.prefix(limit))
  }

  /// How many lines the card leaves out, collapsed or expanded.
  public func hiddenLineCount(isExpanded: Bool) -> Int {
    diff.lines.count - shownLines(isExpanded: isExpanded).count
  }

  /// The key a chat stores an expanded card under, beside the turn ids it already stores.
  ///
  /// `callIndex` is the call's position in the whole run, which does not change as the run
  /// grows. The position among the named rows does.
  public static func expansionKey(turnID: String, callIndex: Int) -> String {
    "\(turnID).edit.\(callIndex)"
  }

  // MARK: - Building the lines

  private static func lines(of change: Change) -> [TranscriptDiff.Line] {
    switch change {
    case .write(let content):
      return fileLines(content).map { .addition($0) }
    case .replacements(let replacements):
      guard replacements.count > 1 else {
        return replacements.first.map { lines(from: $0.old, to: $0.new) } ?? []
      }
      // A separator before every edit, the first included. `TranscriptDiff.body` starts at
      // the first hunk line, so a separator only between edits would hide the first.
      return replacements.enumerated().flatMap { offset, replacement in
        [.hunk(TranscriptChatCopy.editSeparator(offset + 1, of: replacements.count))]
          + lines(from: replacement.old, to: replacement.new)
      }
    }
  }

  /// `old` to `new`, line by line: removals before additions at each changed place, and
  /// the lines both share as context.
  static func lines(from old: String, to new: String) -> [TranscriptDiff.Line] {
    let before = fileLines(old)
    let after = fileLines(new)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in after.difference(from: before) {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }

    var lines: [TranscriptDiff.Line] = []
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < before.count || newIndex < after.count {
      if oldIndex < before.count, removed.contains(oldIndex) || newIndex >= after.count {
        lines.append(.removal(before[oldIndex]))
        oldIndex += 1
      } else if newIndex < after.count, inserted.contains(newIndex) || oldIndex >= before.count {
        lines.append(.addition(after[newIndex]))
        newIndex += 1
      } else {
        // Neither removed nor inserted, so the two lines are the one the sides share.
        lines.append(.context(before[oldIndex]))
        oldIndex += 1
        newIndex += 1
      }
    }
    return lines
  }

  /// A string's lines. An empty string has none, and a final newline ends the last line
  /// rather than starting an empty one.
  static func fileLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = TranscriptDiff.normalizedLines(of: text).map(String.init)
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    return lines
  }
}

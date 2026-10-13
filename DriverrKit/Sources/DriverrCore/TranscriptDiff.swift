import Foundation

/// A unified diff, split into the lines a view colours differently.
///
/// Drawn flat, a diff's `+` and `-` are the only signal, they wrap into the next line, and
/// the file header is lost among the rest. Everything here is a fact about the text, so
/// `swift test` decides it; colours and scrolling are the view's.
public struct TranscriptDiff: Hashable, Sendable {
  /// One line of the diff, typed by what the first column said it was.
  ///
  /// `meta` is not `context`, though both are drawn quietly: `--- a/pool.rs` is the diff
  /// describing itself, and a context line is the file's content.
  public enum Line: Hashable, Sendable {
    /// `@@ -12,7 +12,9 @@ fn acquire()`: the whole header, because the section name after the
    /// second `@@` is the most useful part.
    case hunk(String)
    /// A line the change adds, without its `+`.
    case addition(String)
    /// A line the change removes, without its `-`.
    case removal(String)
    /// A line that is in both sides, without its leading space.
    case context(String)
    /// `diff --git`, `index`, `--- a/…`, `+++ b/…`, `\ No newline at end of file`: the diff's
    /// own bookkeeping, verbatim.
    case meta(String)

    /// What the line says, without its marker column (kept for `meta` and `hunk`, where it
    /// is part of the text).
    public var text: String {
      switch self {
      case .hunk(let text), .addition(let text), .removal(let text),
        .context(let text), .meta(let text):
        text
      }
    }
  }

  /// The file the diff is about, for the card's header: `+++ b/<path>`, falling back to
  /// `--- a/<path>` for a deletion. `nil` for a bare hunk, which is a valid shape.
  public let filePath: String?
  public let lines: [Line]

  public init(filePath: String?, lines: [Line]) {
    self.filePath = filePath
    self.lines = lines
  }

  /// `+12 −3` as counts. The view decides how to say it.
  public var additions: Int { lines.filter { if case .addition = $0 { true } else { false } }.count }
  public var removals: Int { lines.filter { if case .removal = $0 { true } else { false } }.count }

  /// The lines worth drawing: everything from the first hunk header on.
  ///
  /// The preamble repeats the filename the card's header already states, and four lines is
  /// most of what fits above the fold on a phone. `looksLikeDiff` guarantees a hunk header,
  /// so this cannot empty a block.
  public var body: [Line] {
    guard let start = lines.firstIndex(where: { if case .hunk = $0 { true } else { false } })
    else { return lines }
    return Array(lines[start...])
  }

  /// `+3 −1`: the change, as small as it goes.
  public var changeSummary: String { "+\(additions) −\(removals)" }

  /// The whole card as one sentence, so VoiceOver is not handed forty unlabelled rows: which
  /// file changed and by how much. The lines stay selectable text.
  public var accessibilityLabel: String {
    let added = additions == 1 ? "1 line added" : "\(additions) lines added"
    let removed = removals == 1 ? "1 line removed" : "\(removals) lines removed"
    guard let filePath else { return "Diff, \(added), \(removed)" }
    return "Diff of \(filePath), \(added), \(removed)"
  }

  /// Whether `text` is a unified diff. A hunk header is required. Anything weaker mistakes a
  /// changelog or a list of `+`/`-` lines for a patch, and prose in red and green is worse
  /// than a diff in one colour.
  public static func looksLikeDiff(_ text: String) -> Bool {
    normalizedLines(of: text).contains { isHunkHeader($0) }
  }

  /// Splits `text` into typed lines. An unrecognised line becomes `meta` rather than being
  /// dropped, so a half-understood diff loses no line of the file.
  public static func parse(_ text: String) -> TranscriptDiff {
    var lines: [Line] = []
    var fromPath: String?
    var toPath: String?

    for raw in normalizedLines(of: text) {
      let line = String(raw)
      if isHunkHeader(raw) {
        lines.append(.hunk(line))
        continue
      }
      // Checked before the `+`/`-` cases, on the marker alone, not on whether a usable path
      // comes back. `--- /dev/null` and `+++ /dev/null` are headers with no usable path, and
      // falling through would count them as a removal and an addition.
      if line.hasPrefix("--- ") {
        fromPath = filePath(inHeader: line, marker: "--- ")
        lines.append(.meta(line))
        continue
      }
      if line.hasPrefix("+++ ") {
        toPath = filePath(inHeader: line, marker: "+++ ")
        lines.append(.meta(line))
        continue
      }
      if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("\\") {
        lines.append(.meta(line))
        continue
      }
      if line.hasPrefix("+") {
        lines.append(.addition(String(line.dropFirst())))
        continue
      }
      if line.hasPrefix("-") {
        lines.append(.removal(String(line.dropFirst())))
        continue
      }
      if line.hasPrefix(" ") {
        lines.append(.context(String(line.dropFirst())))
        continue
      }
      // An empty line in a hunk is a context line whose single space was trimmed. Anything
      // else is bookkeeping this parser has no name for.
      lines.append(line.isEmpty ? .context("") : .meta(line))
    }

    // `+++` names where the file is going. `---` is the fallback, so a deletion still says
    // what was deleted.
    return TranscriptDiff(filePath: toPath ?? fromPath, lines: lines)
  }

  /// Splits `text` into lines, first collapsing `\r\n` to `\n`.
  ///
  /// Swift treats `\r\n` as one `Character`, so splitting on `"\n"` would leave a CRLF diff
  /// as one line that never matches a hunk header. Nothing upstream normalises line endings,
  /// so `TranscriptMarkdown` uses this too.
  static func normalizedLines(of text: String) -> [Substring] {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
  }

  /// `@@ -12,7 +12,9 @@` and anything after it. Checked as `@@ … @@` rather than with a
  /// regular expression that has to spell out the optional counts.
  static func isHunkHeader(_ line: Substring) -> Bool {
    guard line.hasPrefix("@@ ") else { return false }
    return line.dropFirst(3).contains("@@")
  }

  /// `--- a/src/pool.rs` → `src/pool.rs`. Strips git's `a/`/`b/` and returns `nil` for
  /// `/dev/null`.
  private static func filePath(inHeader line: String, marker: String) -> String? {
    guard line.hasPrefix(marker) else { return nil }
    // Up to the first tab: some formats append a timestamp after one.
    let rest = line.dropFirst(marker.count).split(separator: "\t", maxSplits: 1)
    guard var path = rest.first.map(String.init)?.trimmingCharacters(in: .whitespaces),
      !path.isEmpty, path != "/dev/null"
    else { return nil }
    if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
    return path.isEmpty ? nil : path
  }
}

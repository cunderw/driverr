/// What the captured-screen surface says, and how a screen is laid out to be drawn.
///
/// `PaneScreen` is the data. This is the wording and the two layouts. The captured screen is
/// the permanent view for most agent kinds, so nothing here apologises or claims more than
/// the screen shows. Nothing offers a route to earlier output either: a herdr agent pane's
/// history is its visible screen, and what a host keeps beyond the screen is not read here.

// MARK: - How wide a screen is

extension PaneScreen {
  /// The widest row on this screen, in the characters the parser counts.
  ///
  /// Measured from the bytes, never taken from herdr. herdr reports no column count, and
  /// its `rect.width` includes the pane's chrome and can disagree with the capture, so do not
  /// use it here. No caption states the width any more, but tests assert this measurement.
  public var columns: Int {
    lines.map(\.text.count).max() ?? 0
  }

  /// How far a wrapped line's continuations hang, in columns: two, as Claude Code indents
  /// its own continuations. The view adds it as leading space, because spaces inserted into
  /// the text would look like spaces the pane printed.
  public static let continuationIndent = 2

  /// The rows to draw, in order.
  ///
  /// `columns` is the available width, or `nil` for the clipped layout: one row per screen
  /// line. Wrapping cuts at the column, not at a word, because a terminal screen is a grid
  /// and reflowing words would draw something the pane never printed.
  public func rows(wrappedTo columns: Int?) -> [PaneScreenRow] {
    var drawn: [PaneScreenRow] = []
    for (index, line) in lines.enumerated() {
      drawn.append(
        contentsOf: Self.rows(for: line, at: index, wrappedTo: columns, from: drawn.count)
      )
    }
    return drawn
  }

  private static func rows(
    for line: PaneScreenLine,
    at index: Int,
    wrappedTo columns: Int?,
    from identifier: Int
  ) -> [PaneScreenRow] {
    guard let columns, columns > 0 else {
      return [
        PaneScreenRow(
          id: identifier,
          line: index,
          spans: line.spans,
          marker: line.marker,
          isContinuation: false,
          isTruncated: line.isTruncated
        )
      ]
    }

    // Continuations pay for the hanging indent. At least one column, so a narrow phone at a
    // large text size cannot loop forever.
    let continuationWidth = max(1, columns - continuationIndent)
    var remaining = line.spans
    var rows: [PaneScreenRow] = []
    var width = columns

    while !remaining.isEmpty {
      let (head, tail) = split(remaining, at: width)
      rows.append(
        PaneScreenRow(
          id: identifier + rows.count,
          line: index,
          spans: head,
          marker: line.marker,
          isContinuation: !rows.isEmpty,
          // The boundary cut the line, so only the row where the text stops is marked.
          isTruncated: line.isTruncated && tail.isEmpty
        )
      )
      remaining = tail
      width = continuationWidth
    }

    // A blank line is still a row, or gaps the pane drew would close up.
    if rows.isEmpty {
      rows.append(
        PaneScreenRow(
          id: identifier,
          line: index,
          spans: line.spans,
          marker: line.marker,
          isContinuation: false,
          isTruncated: line.isTruncated
        )
      )
    }
    return rows
  }

  /// The first `width` characters of `spans`, and everything after them, with each span's
  /// style carried onto both sides of a cut that falls inside it.
  private static func split(
    _ spans: [PaneScreenSpan],
    at width: Int
  ) -> (head: [PaneScreenSpan], tail: [PaneScreenSpan]) {
    var head: [PaneScreenSpan] = []
    var tail: [PaneScreenSpan] = []
    var taken = 0

    for span in spans {
      if taken >= width {
        tail.append(span)
        continue
      }
      let room = width - taken
      if span.text.count <= room {
        head.append(span)
        taken += span.text.count
        continue
      }
      let cut = span.text.index(span.text.startIndex, offsetBy: room)
      head.append(PaneScreenSpan(text: String(span.text[..<cut]), style: span.style))
      tail.append(PaneScreenSpan(text: String(span.text[cut...]), style: span.style))
      taken = width
    }
    return (head, tail)
  }

  /// The label over the rows Driverr can say are the agent's latest message, or `nil`
  /// when the screen shows none, which is common. Takes the agent's name so a Codex pane is
  /// never labelled as Claude.
  public func agentMessageLabel(agentName: String) -> String? {
    agentMessage == nil ? nil : "\(agentName)'s latest message"
  }
}

// MARK: - The two honest layouts

/// How the screen's lines are laid out.
///
/// Wrapped hangs its continuations so a wrapped line never reads as a new one. Clipped keeps
/// one row per line, so box-drawn output stays intact and long lines run off the edge. A
/// global setting (`TerminalSettings.wrapsScreenLines`, mapped by
/// `TerminalSettings.screenLayout`), with no per-screen override.
public enum PaneScreenLayout: String, Hashable, Sendable, CaseIterable {
  case wrapped
  case clipped
}

/// One row as it is drawn: a screen line, or the tail of one that was wrapped.
public struct PaneScreenRow: Identifiable, Hashable, Sendable {
  /// Its position in the drawn list, the only stable identity, since two continuations of
  /// one line can be identical.
  public let id: Int
  /// Which screen line this row came from. Several rows share one when a line wrapped.
  public let line: Int
  public let spans: [PaneScreenSpan]
  /// Carried onto every row a line wrapped into, so emphasis does not stop half way.
  public let marker: PaneScreenMarker?
  /// Whether this row continues a line that did not fit. The hanging indent hangs off it.
  public let isContinuation: Bool
  /// Whether the boundary cut this line (see `PaneScreenLine.isTruncated`). Only true on
  /// the row where the text stops.
  public let isTruncated: Bool

  public init(
    id: Int,
    line: Int,
    spans: [PaneScreenSpan],
    marker: PaneScreenMarker? = nil,
    isContinuation: Bool = false,
    isTruncated: Bool = false
  ) {
    self.id = id
    self.line = line
    self.spans = spans
    self.marker = marker
    self.isContinuation = isContinuation
    self.isTruncated = isTruncated
  }

  public var text: String { spans.map(\.text).joined() }
}

// MARK: - The caption

/// The one sentence above a captured screen. It makes the surface read as a screen, not a
/// conversation.
public struct PaneScreenCaption: Equatable, Sendable {
  /// `The last 9 lines of the pane — earlier output is not kept.`
  ///
  /// It states what is not kept instead of offering a way to it, because there is no earlier
  /// output to open: herdr returns only the visible screen. Where the host does keep it, the
  /// sentence stops at what is shown.
  public let lines: String

  public init(screen: PaneScreen, earlierOutputIsKept: Bool = false) {
    let count = screen.lines.count
    let counted = count == 1 ? "The last line" : "The last \(count) lines"
    let shown = "\(counted) of the pane"
    lines = earlierOutputIsKept ? "\(shown)." : "\(shown) — earlier output is not kept."
  }

  /// What VoiceOver is given: one statement about the screen below.
  public var accessibilityLabel: String { lines }
}

// MARK: - The surface's fixed words

/// Everything the captured-screen surface says that is not derived from a screen.
///
/// A refusal is a fault and a blank screen is an answer. Empty stdout with exit 1 and
/// stderr is herdr declining; empty stdout with exit 0 is a pane showing nothing. Only the
/// refusal offers a retry.
public enum PaneScreenCopy {
  /// What the spinner says. It always resolves, because the model owns the read.
  public static let reading = "Reading the pane…"

  /// The pane read back empty. An answer, so no retry.
  public static let blankTitle = "This pane is showing nothing"
  public static let blankMessage =
    "The pane's screen came back empty. Nothing has been printed here, or the screen has "
    + "been cleared."

  /// herdr declined the read, typically `agent_not_idle` on a working pane. Asking again can
  /// answer differently, so this one retries.
  public static let refusalTitle = "Couldn't read the pane"
  public static let retry = "Retry"

  /// The Settings row that picks `PaneScreenLayout` for every captured screen. The footer
  /// explains the layouts once, here, instead of on every pane.
  public static let wrapTitle = "Wrap Long Lines"
  public static let wrapFooter =
    "Long lines wrap with a hanging indent. Turn this off to keep one row per screen "
    + "line, so a long line runs off the edge instead."
}

/// One pane's visible screen, safe to put in a SwiftUI text view.
///
/// Untrusted remote output is not safe in a `Text` the way it is in a terminal emulator:
/// `Text` has no parser. Escape sequences, control characters and unbounded lines are dealt
/// with once, at this boundary.
///
/// What comes out is small: rows of styled spans and a per-row marker. The styles are the
/// sixteen palette colours plus bold, dim and italic, because the screen is drawn in the
/// terminal theme and anything richer would invent an appearance the pane never had.
public struct PaneScreen: Hashable, Sendable {
  public let lines: [PaneScreenLine]

  public init(lines: [PaneScreenLine]) {
    self.lines = lines
  }

  /// A screen with nothing on it. Distinct from a failed read, which throws, so a blank pane
  /// is never mistaken for a fault or the reverse.
  public static let blank = PaneScreen(lines: [])

  public var isEmpty: Bool { lines.isEmpty }

  /// Every row, unstyled, newline-separated, for tests and accessibility labels.
  public var text: String { lines.map(\.text).joined(separator: "\n") }

  /// The rows holding the agent's latest message, or `nil` when the screen shows none.
  ///
  /// `nil` is ordinary: many screens show no assistant message, and most agent kinds have no
  /// screen convention Driverr can read. A caption must say nothing when this is `nil`.
  public var agentMessage: Range<Int>? {
    guard let start = lines.firstIndex(where: { $0.marker == .agentMessage }) else { return nil }
    var end = start
    while end < lines.count, lines[end].marker == .agentMessage { end += 1 }
    return start..<end
  }

  /// Rows Driverr is willing to say a person sent. Usually none on a real screen.
  public var userTurns: [Int] {
    lines.indices.filter { lines[$0].marker == .userTurn }
  }

  /// The longest line this boundary hands on, in characters. Wider than any pane worth
  /// reading on a phone. The point is that the far side never chooses a line's length.
  public static let maximumLineLength = 512

  /// The most rows this boundary hands on. herdr and the viewport bound it too, but those
  /// are the far side's promises and this is the near side's.
  public static let maximumLines = 200
}

/// One row of a screen.
public struct PaneScreenLine: Hashable, Sendable {
  /// The row's text, split wherever its styling changes.
  public let spans: [PaneScreenSpan]
  /// What Driverr is willing to say this row is. `nil` on almost every row.
  public let marker: PaneScreenMarker?
  /// Whether this row exceeded `PaneScreen.maximumLineLength` and was cut. A flag rather
  /// than an ellipsis in the text, which would look like something the pane printed.
  public let isTruncated: Bool

  public init(spans: [PaneScreenSpan], marker: PaneScreenMarker? = nil, isTruncated: Bool = false) {
    self.spans = spans
    self.marker = marker
    self.isTruncated = isTruncated
  }

  public var text: String { spans.map(\.text).joined() }

  /// Whether the row has nothing visible. Spaces count as nothing, because a screen is a
  /// grid.
  public var isBlank: Bool { text.allSatisfy(\.isWhitespace) }
}

/// A run of characters sharing one style.
public struct PaneScreenSpan: Hashable, Sendable {
  public let text: String
  public let style: PaneScreenStyle

  public init(text: String, style: PaneScreenStyle = .plain) {
    self.text = text
    self.style = style
  }
}

/// The whole style vocabulary a screen can carry across this boundary.
public struct PaneScreenStyle: Hashable, Sendable {
  public let foreground: PaneScreenColor?
  public let background: PaneScreenColor?
  public let isBold: Bool
  public let isDim: Bool
  public let isItalic: Bool

  public init(
    foreground: PaneScreenColor? = nil,
    background: PaneScreenColor? = nil,
    isBold: Bool = false,
    isDim: Bool = false,
    isItalic: Bool = false
  ) {
    self.foreground = foreground
    self.background = background
    self.isBold = isBold
    self.isDim = isDim
    self.isItalic = isItalic
  }

  /// The terminal's defaults, drawn when the pane said nothing.
  public static let plain = PaneScreenStyle()
}

/// The sixteen colours a terminal palette names.
///
/// A `Theme` owns what each looks like. A 216-cube index, greyscale ramp or 24-bit literal
/// is dropped rather than approximated, which would invent a colour. Real captures use both.
public enum PaneScreenColor: String, Hashable, Sendable, CaseIterable {
  case black, red, green, yellow, blue, magenta, cyan, white
  case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta
  case brightCyan, brightWhite

  /// The colour at a 256-colour palette index, for the sixteen with names. The case order
  /// above is the palette, 0–15, so do not reorder it.
  /// `PaneScreenTests.paletteIndicesAreTheAnsiOrder` pins it.
  init?(paletteIndex: Int) {
    guard paletteIndex >= 0, paletteIndex < Self.allCases.count else { return nil }
    self = Self.allCases[paletteIndex]
  }
}

/// What Driverr is willing to say a row is. Never guessed. A marker is drawn as emphasis and
/// a caption, never a chat bubble, which would assert speaker, order and boundary at once.
public enum PaneScreenMarker: String, Hashable, Sendable {
  /// The agent's latest message, marked only where the screen shows one.
  case agentMessage
  /// A turn a person sent, marked only where the screen shows both signals that distinguish
  /// it from composer text.
  case userTurn
}

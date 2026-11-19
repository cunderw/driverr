import DriverrCore
import Foundation

/// What a pane's screen is doing beside its text: where the cursor is, which screen is up, and
/// the modes a program set. Read with `display-message`, because `capture-pane` prints text and
/// colour only.
///
/// A format variable an older tmux does not know expands to nothing, and reads as off.
/// `bracket_paste_flag` is one: tmux added it in 3.7.
struct TmuxPaneState: Equatable, Sendable {
  var alternateScreen = false
  var cursorColumn = 0
  var cursorRow = 0
  var cursorVisible = true
  var applicationCursorKeys = false
  var applicationKeypad = false
  var autowrap = true
  var insert = false
  var originMode = false
  var scrollTop = 0
  var scrollBottom = 0
  var mouseStandard = false
  var mouseButton = false
  var mouseAny = false
  var mouseSGR = false
  var bracketedPaste = false
  var height = 0

  /// The format `display-message -p` expands, one field per variable, spaces between.
  static let format = [
    "alternate_on", "cursor_x", "cursor_y", "cursor_flag", "keypad_cursor_flag", "keypad_flag",
    "wrap_flag", "insert_flag", "origin_flag", "scroll_region_upper", "scroll_region_lower",
    "mouse_standard_flag", "mouse_button_flag", "mouse_any_flag", "mouse_sgr_flag",
    "bracket_paste_flag", "pane_height",
  ].map { "#{\($0)}." }.joined()

  /// Each field ends in `.`, so an empty one still has its place.
  init?(_ line: Data) {
    let fields = String(decoding: line, as: UTF8.self).split(
      separator: ".", omittingEmptySubsequences: false
    ).map { Int($0) }
    guard fields.count >= 17, let height = fields[16], height > 0 else { return nil }
    func flag(_ index: Int) -> Bool { fields[index] == 1 }
    alternateScreen = flag(0)
    cursorColumn = fields[1] ?? 0
    cursorRow = fields[2] ?? 0
    cursorVisible = fields[3] != 0
    applicationCursorKeys = flag(4)
    applicationKeypad = flag(5)
    autowrap = fields[6] != 0
    insert = flag(7)
    originMode = flag(8)
    scrollTop = fields[9] ?? 0
    scrollBottom = fields[10] ?? (height - 1)
    mouseStandard = flag(11)
    mouseButton = flag(12)
    mouseAny = flag(13)
    mouseSGR = flag(14)
    bracketedPaste = flag(15)
    self.height = height
  }

  init() {}
}

/// The bytes that put a pane's screen into a fresh emulator, from what tmux printed.
///
/// `capture-pane -e` prints each row as text with its colours, and always prints every row of the
/// screen, empty ones included, so the last `height` lines of a capture are the screen and the
/// rest is history. Rows are joined with CRLF and the last row gets none, so nothing scrolls past
/// the bottom.
///
/// **On the alternate screen the normal one comes from `capture-pane -a`.** tmux keeps the normal
/// screen aside while a program such as Claude Code holds the alternate one, and `-a` prints it.
/// It is painted first and `?1049h` follows, so leaving the alternate screen later shows the
/// shell that was there. The history stays with the normal screen.
enum TmuxPaint {
  /// Scrollback to paint at the head of a controller: what SwiftTerm keeps by default, and what
  /// a core paints.
  static let historyLines = 500

  /// The commands, on one line, so tmux runs them back to back with no pane output between.
  ///
  /// Three replies: the state, the screen with history, and the normal screen. tmux skips the
  /// rest of a line after a command fails, so a pane that has gone answers one `%error`.
  static func commands(pane: String, history: Int) -> (line: String, replies: Int) {
    let target = "-t \(pane)"
    let state = "display-message -p \(target) '\(TmuxPaneState.format)'"
    let screen = "capture-pane -p -e -S -\(history) \(target)"
    let normal = "capture-pane -p -e -a -q \(target)"
    return ("\(state) ; \(screen) ; \(normal)", 3)
  }

  /// The paint. `clearing` first homes and clears the emulator, for a repaint over a screen that
  /// already shows something. Returns `nil` for replies it cannot read.
  ///
  /// **A repaint leaves the alternate screen first.** An observer's paint of a full-screen
  /// program left the emulator there, and clearing there would put the history and the normal
  /// screen into the alternate buffer. `?1047l`, not `?1049l`: nothing saved a cursor to restore,
  /// and SwiftTerm's restore brings the saved autowrap with it (see `CorePaint`).
  static func bytes(from replies: [[Data]], clearing: Bool = false) -> Data? {
    guard replies.count == 3, let stateLine = replies[0].first,
      let state = TmuxPaneState(stateLine)
    else { return nil }
    let capture = replies[1]
    let visibleCount = min(state.height, capture.count)
    let history = Array(capture.dropLast(visibleCount))
    let visible = Array(capture.suffix(visibleCount))

    var out = Data()
    if clearing { out.append(Data("\u{1B}[?1047l\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)) }
    if state.alternateScreen {
      out.append(rows(history + replies[2].suffix(state.height)))
      out.append(Data("\u{1B}[0m\u{1B}[?1049h\u{1B}[H\u{1B}[2J".utf8))
      out.append(rows(visible))
    } else {
      out.append(rows(history + visible))
    }
    out.append(Data(modes(of: state).utf8))
    return out
  }

  private static func rows(_ lines: [Data]) -> Data {
    var out = Data()
    for (index, line) in lines.enumerated() {
      if index > 0 { out.append(contentsOf: [0x0D, 0x0A]) }
      out.append(line)
    }
    return out
  }

  /// The modes, then the cursor. The scroll region comes before the cursor, because setting one
  /// homes the cursor.
  static func modes(of state: TmuxPaneState) -> String {
    var out = "\u{1B}[0m"
    if state.scrollTop != 0 || state.scrollBottom != state.height - 1 {
      out += "\u{1B}[\(state.scrollTop + 1);\(state.scrollBottom + 1)r"
    }
    if state.originMode { out += "\u{1B}[?6h" }
    if !state.autowrap { out += "\u{1B}[?7l" }
    if state.insert { out += "\u{1B}[4h" }
    if state.applicationCursorKeys { out += "\u{1B}[?1h" }
    if state.applicationKeypad { out += "\u{1B}=" }
    if state.mouseStandard { out += "\u{1B}[?1000h" }
    if state.mouseButton { out += "\u{1B}[?1002h" }
    if state.mouseAny { out += "\u{1B}[?1003h" }
    if state.mouseSGR { out += "\u{1B}[?1006h" }
    if state.bracketedPaste { out += "\u{1B}[?2004h" }
    // With origin mode on, a cursor row counts from the top of the scroll region.
    let row = state.originMode ? state.cursorRow - state.scrollTop : state.cursorRow
    out += "\u{1B}[\(row + 1);\(state.cursorColumn + 1)H"
    if !state.cursorVisible { out += "\u{1B}[?25l" }
    return out
  }
}

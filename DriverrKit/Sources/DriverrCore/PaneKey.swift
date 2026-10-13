/// A key press Driverr can send to a pane, named the way herdr names it.
///
/// A closed set, because steering a blocked agent from a phone is a handful of answers, and
/// each has to be one tap. The raw value is herdr's key syntax (`enter`, `esc`, `ctrl+c`),
/// so nothing downstream invents its own spelling.
public enum PaneKey: String, Hashable, Sendable, CaseIterable {
  case enter
  case esc
  case up
  case down
  /// The terminal's accessory row (`DriverrKeyboardAccessory`) draws all four arrows.
  case left
  case right
  case tab
  case yes = "y"
  case no = "n"
  case interrupt = "ctrl+c"
  /// An `AskUserQuestion` option's number. Claude Code's picker answers by number: a digit
  /// selects a single-select option and moves on, and toggles a multi-select one. Only reply
  /// chips send these.
  case digit1 = "1"
  case digit2 = "2"
  case digit3 = "3"
  case digit4 = "4"
  case digit5 = "5"
  case digit6 = "6"
  case digit7 = "7"
  case digit8 = "8"
  case digit9 = "9"

  /// The key for option number `number`, counted from 1, or `nil` outside 1...9.
  public static func digit(_ number: Int) -> PaneKey? {
    (1...9).contains(number) ? PaneKey(rawValue: String(number)) : nil
  }

  /// The number this key types, or `nil` for every key that is not a digit.
  public var digitValue: Int? {
    switch self {
    case .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
      Int(rawValue)
    default:
      nil
    }
  }

  /// What the button says. Not the raw value: `ctrl+c` is a key name, and `y` alone does not
  /// say what it will do.
  public var label: String {
    switch self {
    case .enter: "Enter"
    case .esc: "Esc"
    case .up: "Up"
    case .down: "Down"
    case .left: "Left"
    case .right: "Right"
    case .tab: "Tab"
    case .yes: "y"
    case .no: "n"
    case .interrupt: "Ctrl-C"
    case .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
      rawValue
    }
  }

  /// What the terminal's keyboard accessory row draws. Only the arrows differ from `label`.
  public var accessoryGlyph: String {
    switch self {
    case .left: "←"
    case .down: "↓"
    case .up: "↑"
    case .right: "→"
    default: label
    }
  }

  /// Said the way a person would, for VoiceOver.
  public var accessibleName: String {
    switch self {
    case .enter: "Enter"
    case .esc: "Escape"
    case .up: "Up arrow"
    case .down: "Down arrow"
    case .left: "Left arrow"
    case .right: "Right arrow"
    case .tab: "Tab"
    case .yes: "Yes"
    case .no: "No"
    case .interrupt: "Interrupt, control C"
    case .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
      rawValue
    }
  }

  /// The measurements of the terminal's accessory row, `DriverrKeyboardAccessory`, kept here
  /// so `swift test` can check the arithmetic.
  ///
  /// `keyHeight` is 44 because these are the most-hit keys in the app. `rowHeight` adds a
  /// 2 pt inset top and bottom. `keySpacing` of 3 gives eight 44 pt keys from 385 pt of
  /// screen up.
  public enum AccessoryRowMetrics {
    public static let rowHeight: Double = 48
    public static let keyHeight: Double = 44
    public static let verticalInset: Double = 2
    public static let horizontalMargin: Double = 6
    public static let keySpacing: Double = 3
    public static let cornerRadius: Double = 6
    public static let fontSize: Double = 15

    /// How wide each of `keyCount` equal keys is in a row `rowWidth` points wide: the row
    /// less its two side margins and the gaps between keys, shared equally. It is the
    /// arithmetic `DriverrKeyboardAccessory`'s `.fillEqually` stack performs.
    public static func keyWidth(rowWidth: Double, keyCount: Int) -> Double {
      let gaps = Double(keyCount - 1) * keySpacing
      return (rowWidth - 2 * horizontalMargin - gaps) / Double(keyCount)
    }
  }
}

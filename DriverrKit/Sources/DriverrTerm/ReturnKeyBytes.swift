import Foundation

/// What Return puts on the wire: a line feed with Shift or an armed Ctrl, a carriage
/// return otherwise.
///
/// Claude Code reads LF (0x0a) as a new line and CR (0x0d) as submit. Codex binds Ctrl+J,
/// which is LF, to its newline, and herdr passes a lone LF through. The software keyboard
/// reports no Shift on Return, so armed Ctrl is its way to send LF.
public enum ReturnKeyBytes {
  /// SwiftTerm's own `returnByteSequence` default.
  public static let carriageReturn: [UInt8] = [0x0d]
  public static let lineFeed: [UInt8] = [0x0a]

  /// - Parameters:
  ///   - shift: a hardware Shift was held with this Return.
  ///   - control: Ctrl was held, or armed on the accessory row, for this Return.
  public static func bytes(shift: Bool, control: Bool) -> [UInt8] {
    shift || control ? lineFeed : carriageReturn
  }
}

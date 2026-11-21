/// What the chat believes Claude Code's mode is, from the screens it reads and the Shift-Tabs
/// it sends.
///
/// - **A read replaces the mode**, unless a Shift-Tab is waiting for its answer.
/// - **A Shift-Tab marks the mode stale.** The mode on show stays until a read answers it.
/// - **A read can arrive before Claude has redrawn.** On tmux and the herdr TUI the first read
///   after the key showed the old mode on most tries; the new one was there about 70 ms
///   later. So a read that still shows the old mode asks for another, at most
///   `maximumRereads` times, and then the screen is believed.
/// - **A read that started before the latest Shift-Tab answers nothing about it.** It asks for
///   another read and spends nothing. `ticket` tells the two apart.
/// - **A failed read keeps the last known mode.**
/// - **The next mode is never predicted.** The cycle depends on which modes the user turned on.
public struct PaneModeReading: Equatable, Sendable {
  /// The mode on show. `nil` is unknown, which draws the plain glyph and says no mode.
  public private(set) var mode: ClaudeMode?
  /// Whether a Shift-Tab has gone since the last read that answered it.
  public private(set) var isStale = false
  /// Counts Shift-Tabs. A read records it when it starts and hands it back when it lands.
  public private(set) var ticket = 0

  /// The mode last seen on screen while stale: the one a read must differ from.
  /// `nil` while the mode before the Shift-Tab is unknown.
  private var baseline: ClaudeMode?
  /// Shift-Tabs not yet seen to land.
  private var pending = 0
  private var rereadsLeft = 0

  /// How many extra reads one Shift-Tab may cost.
  public static let maximumRereads = 2

  public init(mode: ClaudeMode? = nil) {
    self.mode = mode
  }

  /// A Shift-Tab went to the pane.
  public mutating func toggled() {
    if !isStale { baseline = mode }
    isStale = true
    pending += 1
    rereadsLeft = Self.maximumRereads
    ticket += 1
  }

  /// A read landed. Returns whether to read again.
  ///
  /// - Parameter readTicket: `ticket` as it was when the read started.
  public mutating func read(_ screen: PaneScreen, ticket readTicket: Int) -> Bool {
    let seen = ClaudeMode(screen: screen)
    guard isStale else {
      mode = seen
      return false
    }
    guard readTicket == ticket else { return true }
    guard let baseline else {
      // Nothing to compare with, so this could be the old mode or the new one. One more read
      // after the delay, and then whatever it shows.
      self.baseline = seen
      guard rereadsLeft > 0 else { return believe(seen) }
      rereadsLeft = 0
      return true
    }
    // A read with no answer is not a change: the screen may be mid-redraw.
    if let seen, seen != baseline {
      pending -= 1
      self.baseline = seen
      guard pending > 0, rereadsLeft > 0 else { return believe(seen) }
      rereadsLeft -= 1
      return true
    }
    guard rereadsLeft > 0 else { return believe(seen) }
    rereadsLeft -= 1
    return true
  }

  /// A read failed. The mode on show stays. Returns whether to read again: only when the read
  /// started before the latest Shift-Tab, which has then had no read of its own.
  public mutating func failed(ticket readTicket: Int) -> Bool {
    isStale && readTicket != ticket
  }

  private mutating func believe(_ seen: ClaudeMode?) -> Bool {
    mode = seen
    isStale = false
    pending = 0
    rereadsLeft = 0
    baseline = nil
    return false
  }
}

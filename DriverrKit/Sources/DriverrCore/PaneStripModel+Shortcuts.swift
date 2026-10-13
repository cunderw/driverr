/// Where a hardware key sends a pane scene. A value so `swift test` covers the rules.
///
/// Every rule reads `targets`, the switcher's places, never `chips`. `chips` also holds the
/// Needs-you shortcut and the grid entry, so ⌘2 read off `chips` would land on the second
/// thing drawn rather than the second pane.
extension PaneStripModel {
  /// The place ⌘1 … ⌘9 goes, one-based, or `nil` when there is no such place. Out of range
  /// is `nil`, not clamped, because going somewhere the reader did not ask for is worse than
  /// nothing. On a shell scene the shell is ⌘1, matching the order `targets` publishes.
  public func target(atShortcutIndex index: Int) -> TerminalTarget? {
    let places = targets
    guard index >= 1, index <= places.count else { return nil }
    return places[index - 1]
  }

  /// Where ⌘⇧] goes from `current`: the next place, wrapping to the first, as tmux, iTerm and
  /// Terminal.app do.
  public func target(after current: TerminalTarget) -> TerminalTarget? {
    neighbour(of: current, step: 1)
  }

  /// Where ⌘⇧[ goes from `current`: the previous place, wrapping past the start to the last.
  public func target(before current: TerminalTarget) -> TerminalTarget? {
    neighbour(of: current, step: -1)
  }

  /// The shared half of the two neighbour keys. `nil` in two cases:
  ///
  /// - One place or none. Wrapping would land where the reader already is.
  /// - A `current` not in the list, as when a poll drops the pane the scene is on. Jumping
  ///   to the first place would move the reader while the screen is already changing.
  private func neighbour(of current: TerminalTarget, step: Int) -> TerminalTarget? {
    let places = targets
    guard places.count > 1, let index = places.firstIndex(of: current) else { return nil }
    let count = places.count
    return places[((index + step) % count + count) % count]
  }
}

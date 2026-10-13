import DriverrTerm
import SwiftUI

/// "Copied to clipboard", drawn over the top of the terminal for a moment after a Copy.
///
/// SwiftTerm clears the selection as it copies, so without this a Copy that worked and a
/// menu that was dismissed look the same. `PanePromptBar`'s shape: footnote text, 12 pt of
/// padding, thin material. It takes no touches, so a tap meant for the top rows still lands
/// on the terminal while it is up. Whether it is drawn at all is `copyNoticeOverlay`'s call.
struct TerminalCopyNoticeBar: View {
  @Environment(\.themeAccent) private var themeAccent

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "checkmark")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(themeAccent)
        .accessibilityHidden(true)
      Text(TerminalCopyNotice.text)
        .font(.footnote)
        .accessibilityIdentifier("terminal.copyNotice")
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial)
    .allowsHitTesting(false)
    // Capped because at AX5 in a landscape phone with the keyboard up the bar covered all
    // but the caret row. It is up for two seconds and VoiceOver announces the same words.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }
}

/// Draws `bar` while `notice` is showing. A view of its own so that only this reads
/// `isShowing`, and a Copy re-evaluates this slot rather than `TerminalScreen`'s whole body.
///
/// Fades in and out. The model sets `isShowing` without `withAnimation`, so the transition
/// needs the `.animation` here to run at all. Opacity only, so Reduce Motion needs nothing.
private struct CopyNoticeSlot<Bar: View>: View {
  let notice: TerminalCopyNotice
  let bar: Bar

  var body: some View {
    ZStack {
      if notice.isShowing { bar.transition(.opacity) }
    }
    .animation(.easeInOut(duration: 0.2), value: notice.isShowing)
  }
}

extension View {
  /// Lays the copy notice over the top of this view, the terminal region.
  ///
  /// **An overlay, not a band in the screen's `VStack`.** A band shrinks the terminal, and
  /// the remote program gets two SIGWINCH redraws per Copy. `bar` is a parameter only so
  /// `TerminalCopyTests` can measure it in the real placement.
  func copyNoticeOverlay(
    _ notice: TerminalCopyNotice,
    bar: some View = TerminalCopyNoticeBar()
  ) -> some View {
    overlay(alignment: .top) { CopyNoticeSlot(notice: notice, bar: bar) }
  }
}

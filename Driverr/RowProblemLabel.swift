import SwiftUI

/// A problem said in a row, in words the host, the core or a failed operation chose: on the
/// host screen, the host list and the key sheet.
///
/// Only the glyph is orange. As footnote text on a light row, orange reads at about 2.3:1, and
/// these are sentences someone has to act on.
///
/// Footnote by default. The host list's error row sits among body-size rows and passes
/// `.body`. It sets no foreground of its own, so the text takes the style around
/// it: primary in a row, secondary in a section footer.
///
/// The caller puts the identifier on this view, which is the leaf.
struct RowProblemLabel: View {
  private let message: String
  private let systemImage: String
  private let font: Font

  init(_ message: String, systemImage: String, font: Font = .footnote) {
    self.message = message
    self.systemImage = systemImage
    self.font = font
  }

  var body: some View {
    Label {
      Text(verbatim: message)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.orange)
    }
    .font(font)
  }
}

/// The glyph in front of a chat line that says the agent is waiting on the reader's answer.
///
/// Only the glyph is orange, for the reason `RowProblemLabel` gives; the line's text is
/// primary. Hidden from accessibility, because the line's words already say it.
struct PendingQuestionGlyph: View {
  var body: some View {
    Image(systemName: "exclamationmark.circle.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.orange)
      .accessibilityHidden(true)
  }
}

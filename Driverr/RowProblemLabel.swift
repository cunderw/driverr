import SwiftUI

/// A problem said in a row, in words the host, the core or a failed operation chose: on the
/// host screen, the host list and the key sheet.
///
/// Only the glyph is orange. As footnote text on a light row, orange reads at about 2.3:1, and
/// these are sentences someone has to act on.
///
/// The caller puts the identifier on this view, which is the leaf.
struct RowProblemLabel: View {
  private let message: String
  private let systemImage: String

  init(_ message: String, systemImage: String) {
    self.message = message
    self.systemImage = systemImage
  }

  var body: some View {
    Label {
      Text(verbatim: message)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.orange)
    }
    .font(.footnote)
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

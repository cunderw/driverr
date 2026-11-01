import SwiftUI

/// A problem said in a row of the host screen, in words the host or the core chose.
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

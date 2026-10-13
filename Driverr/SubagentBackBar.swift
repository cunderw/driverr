import DriverrCore
import SwiftUI

/// The row over a sub-agent's chat that returns to the pane's own.
///
/// **In the provenance row's place, not the navigation bar.** Nothing is pushed for a
/// sub-agent, so the system back button still leaves the pane scene, and a second chevron
/// would look like the same control. This is a bordered button with a return glyph. The
/// leading nav slot stays empty; see CLAUDE.md.
///
/// The sub-agent's name sits at the trailing edge, where the provenance row's age sits, so
/// the reader can tell which sub-agent they are reading.
struct SubagentBackBar: View {
  let title: String
  var horizontalInset: CGFloat = ChatColumn.inset
  let onBack: () -> Void

  /// Where a hosted layout test reads the button's and the title's frames. The contract is
  /// `ProvenanceRow.onCaptionFrame`'s: nothing is installed when nobody is measuring.
  var onButtonFrame: (@MainActor (CGRect) -> Void)?
  var onTitleFrame: (@MainActor (CGRect) -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onBack) {
        BorderedButtonLabel {
          Label(TranscriptChatCopy.subagentBack, systemImage: "arrow.uturn.backward")
            .lineLimit(1)
        }
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .font(.footnote.weight(.medium))
      .fixedSize()
      .accessibilityIdentifier("pane.chat.subagent.back")
      .background(measurement(onButtonFrame))
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("pane.chat.subagent.title")
        .background(measurement(onTitleFrame))
    }
    // The provenance row's cap, for its reason: the button's label is fixed size, and above
    // AX1 it would push the title off the row entirely.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .padding(.horizontal, horizontalInset)
    .padding(.top, 6)
    .padding(.bottom, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func measurement(_ report: (@MainActor (CGRect) -> Void)?) -> some View {
    if let report {
      GeometryReader { proxy in
        Color.clear.onAppear { report(proxy.frame(in: .global)) }
      }
    }
  }
}

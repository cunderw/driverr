import DriverrCore
import SwiftUI
import UIKit

/// The one caption line above the transcript, saying where the conversation came from. The
/// raw evidence is a long-press away.
///
/// **It never presents a guess as a fact.** The matched variant says it guessed from the
/// pane's directory, the exact variant drops the guess, and a picked file credits the pick.
///
/// A pure function of the header. `PaneChatView.provenanceHeader(source:)` rebuilds the
/// header on a timer so the age advances.
///
/// Its own type so `HostedProbe` can lay out the row's real modifiers.
struct ProvenanceRow: View {
  let header: TranscriptHeader

  /// Where a hosted layout test reads the caption's resolved frame.
  ///
  /// The in-app form of `HostedProbe`'s `measuredFrame(into:)`, which lives in the test
  /// target. It reports through a `background(GeometryReader)` that takes no part in layout,
  /// and installs nothing when `nil`.
  var onCaptionFrame: (@MainActor (CGRect) -> Void)?

  /// The gutter between this row's ink and the edge of the chat's column.
  ///
  /// Passed in because `ChatColumn.gutter(forColumnWidth:)` varies with the column width.
  /// This row sits beside the collection view, so the section insets that give the turns
  /// their gutter do not reach it. The default is the phone's answer.
  var horizontalInset: CGFloat = ProvenanceRow.horizontalPadding

  var body: some View {
    HStack(spacing: Self.glyphGap) {
      // Hidden, because `checkmark.circle` adds an implicit "Selected" label and trait, and
      // the row says its own sentence.
      Image(systemName: header.isExact ? "checkmark.circle.fill" : "doc.text")
        .font(.caption)
        .foregroundStyle(header.isExact ? Color.green : Color.secondary)
        .accessibilityHidden(true)
      Text(header.caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // `.middle`, not `.tail`: the age is the last segment, and tail truncation would drop
        // it. Middle truncation keeps the agent's name and the age, and the icon still tells
        // exact from guessed.
        .truncationMode(.middle)
        .background(captionMeasurement)
        // Takes the free width itself, not via a `Spacer`, so the count sits one `glyphGap`
        // from the caption.
        .frame(maxWidth: .infinity, alignment: .leading)
      // The context count, on the same line to save height. `fixedSize`, so the caption
      // truncates first.
      if let usage = header.contextUsage {
        Text(usage.compact)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
          .background(countMeasurement)
      }
    }
    // Capped at AX1. Above it the fixed-size count takes the row and the caption loses both
    // the agent's name and the age.
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .padding(.horizontal, horizontalInset)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    // No material band and no divider: one caption line needs no chrome.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(header.accessibilityLabel)
    // The count is this element's value; see `TranscriptHeader.accessibilityValue`.
    .accessibilityValue(header.accessibilityValue ?? "")
    .accessibilityRemoveTraits(.isSelected)
    .accessibilityIdentifier("pane.chat.header")
    // The session id, directory and filename the caption leaves out, with Copy.
    .contextMenu {
      Text(header.detail)
      // The count's full breakdown. Not copied: Copy is for the evidence naming the file.
      if let usage = header.contextUsage {
        Text(usage.breakdown)
      }
      Button {
        UIPasteboard.general.string = header.detail
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .accessibilityIdentifier("pane.chat.header.copy")
    }
  }

  @ViewBuilder private var captionMeasurement: some View {
    if let onCaptionFrame {
      GeometryReader { proxy in
        Color.clear.onAppear { onCaptionFrame(proxy.frame(in: .global)) }
      }
    }
  }

  /// Where a hosted layout test reads the context count's frame. Same contract as
  /// `onCaptionFrame`.
  var onCountFrame: (@MainActor (CGRect) -> Void)?

  @ViewBuilder private var countMeasurement: some View {
    if let onCountFrame {
      GeometryReader { proxy in
        Color.clear.onAppear { onCountFrame(proxy.frame(in: .global)) }
      }
    }
  }

  /// The inset the row shares with the rest of the chat's column wherever the column's cap does
  /// not bind. See `horizontalInset`.
  static let horizontalPadding: CGFloat = 16
  /// Between the glyph and the caption.
  static let glyphGap: CGFloat = 8
}

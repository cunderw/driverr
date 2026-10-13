import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// A bottom `safeAreaInset` alone rests the newest row on the composer's top edge, so nothing
/// has to subtract the composer's height a second time.
///
/// `TerminalScreen` now uses a `safeAreaBar`, and `ChatGlassLayoutTests` asserts the same
/// resting position for that shape at the same two sizes. The newest row ends at 759 on the
/// phone and 1261 on the pad, exactly where the composer starts.
///
/// `.serialized`: see `ChatGlassLayoutTests`.
@MainActor
@Suite("Chat conversation inset", .serialized)
struct ChatConversationInsetLayoutTests {
  /// A scroll view of fixed rows and the composer as a bottom `safeAreaInset`. Stated heights,
  /// so the fixture cannot stop reproducing when either real view changes.
  private struct Conversation: View {
    var composer: CGFloat
    var rows: Int
    var rowHeight: CGFloat
    var onFirstRow: @MainActor (CGRect) -> Void
    var onLastRow: @MainActor (CGRect) -> Void
    var onComposer: @MainActor (CGRect) -> Void

    var body: some View {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(0..<rows, id: \.self) { index in
            let row = Color.blue.frame(height: rowHeight)
            if index == 0 {
              row.measuredFrame(into: onFirstRow)
            } else if index == rows - 1 {
              row.measuredFrame(into: onLastRow)
            } else {
              row
            }
          }
        }
      }
      // A plain `VStack` and the anchor rather than a `ScrollPosition`, so the resting
      // position is a fact of layout rather than of a scroll that has to be waited for.
      .defaultScrollAnchor(.bottom)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Color.green
          .frame(height: composer)
          .measuredFrame(into: onComposer)
      }
    }
  }

  private typealias Measured = (first: CGRect, last: CGRect, composer: CGRect)

  private func measure(size: CGSize) -> Measured {
    var first = CGRect.zero
    var last = CGRect.zero
    var composer = CGRect.zero
    let window = HostedProbe.window(
      Conversation(
        composer: Self.composer,
        rows: Self.rows,
        rowHeight: Self.rowHeight,
        onFirstRow: { first = $0 },
        onLastRow: { last = $0 },
        onComposer: { composer = $0 }
      ),
      size: size
    )
    withExtendedLifetime(window) {}
    return (first, last, composer)
  }

  /// `PaneComposerBar`'s measured height with an empty field, shared with
  /// `PaneSurfaceLayoutTests.Stack.composer`.
  private static let composer: CGFloat = 115
  private static let rowHeight: CGFloat = 120
  /// 2400 pt of content, taller than either window.
  private static let rows = 20

  @Test("the newest row rests on the composer's top edge, on the phone")
  func theInsetAloneHoldsTheNewestRowOnThePhone() {
    let measured = measure(size: HostedProbe.phone)
    expectTheEndOfTheConversationIsAboveTheComposer(measured, on: "phone")
  }

  @Test("the newest row rests on the composer's top edge, on the pad")
  func theInsetAloneHoldsTheNewestRowOnThePad() {
    let measured = measure(size: HostedProbe.pad)
    expectTheEndOfTheConversationIsAboveTheComposer(measured, on: "pad")
  }

  /// The first assertion keeps the second honest. `measuredFrame` reports once, from
  /// `onAppear`. A frame captured before the bottom anchor applied would put the last row under
  /// the composer, which looks like the defect this suite rules out.
  private func expectTheEndOfTheConversationIsAboveTheComposer(
    _ measured: Measured,
    on device: String
  ) {
    // Built as `String`s first: `#expect` takes a `Comment`, which a string literal converts
    // to and a `+` concatenation does not.
    let notScrolled = """
      The conversation is not resting at its end on the \(device): the first of \(Self.rows) \
      rows is still at y \(measured.first.minY). The measurement was taken before \
      `defaultScrollAnchor(.bottom)` applied, so nothing below can be read as a layout result.
      """
    #expect(measured.first.minY < 0, "\(notScrolled)")

    let hidden = """
      The newest row runs to y \(measured.last.maxY) on the \(device) while the composer starts \
      at \(measured.composer.minY), so \(measured.last.maxY - measured.composer.minY) pt of it \
      rests under the bar. The bottom `safeAreaInset` is not enough on its own, so the \
      conversation would need an explicit composer-height padding again.
      """
    #expect(measured.last.maxY <= measured.composer.minY + 0.5, "\(hidden)")
  }
}

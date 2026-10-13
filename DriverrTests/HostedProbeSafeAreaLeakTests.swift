import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// A hosted probe window must contribute no safe area of its own.
///
/// A probe window inherits the real scene's insets, and `.ignoresSafeArea()` does not cover
/// `containerRelativeFrame`. With the scene left in landscape, the inherited 62 pt side insets
/// narrow a hosted chat column and move its rows in, so a suite that measures the column fails
/// intermittently.
///
/// This asserts the invariant in whatever orientation the simulator is in, and rotates
/// nothing: the suites run in parallel, and rotating the live scene would affect all of them.
@MainActor
@Suite("Hosted probe safe-area leak")
struct HostedProbeSafeAreaLeakTests {
  /// The conversation's viewport on the iPad in portrait. The width is the readable column's,
  /// because `TerminalSceneRoute.readableWidth` caps the chat.
  private static let viewport = CGSize(width: 680, height: 1186)

  private struct Geometry: Equatable {
    var containerWidth: Double = 0
    var contentWidth: Double = 0
  }

  /// A chat column in a SwiftUI `ScrollView`: rows capped at `ChatColumn.width`, padded by
  /// `ChatColumn.inset`, inside a `containerRelativeFrame(.horizontal)`, which is the frame the
  /// inherited insets narrow.
  private struct Replica: View {
    var onRow: @MainActor (CGRect) -> Void
    var onGeometry: @MainActor (Geometry) -> Void

    var body: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          Color.green.frame(height: 2400)
          Color.blue
            .frame(width: 400, height: 240)
            .background(
              GeometryReader { proxy in
                Color.clear
                  .onAppear { onRow(proxy.frame(in: .global)) }
                  .onChange(of: proxy.frame(in: .global)) { _, frame in onRow(frame) }
              })
          Color.clear.frame(height: 1).id("pane.chat.tail")
        }
        .frame(maxWidth: ChatColumn.width, alignment: .leading)
        .scrollTargetLayout()
        .padding(.horizontal, ChatColumn.inset)
        .containerRelativeFrame(.horizontal, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
      .defaultScrollAnchor(UnitPoint(x: 0, y: 1))
      .onScrollGeometryChange(for: Geometry.self) { geometry in
        Geometry(
          containerWidth: Double(geometry.containerSize.width),
          contentWidth: Double(geometry.contentSize.width))
      } action: { _, geometry in
        onGeometry(geometry)
      }
    }
  }

  private static func insets(at size: CGSize) -> UIEdgeInsets {
    let window = HostedProbe.window(Color.clear, size: size)
    let insets = window.safeAreaInsets
    withExtendedLifetime(window) {}
    return insets
  }

  /// The regression. A probe window carries none of the host scene's safe area, whatever its
  /// orientation.
  @Test("A hosted probe window contributes no safe area of its own")
  func aProbeWindowContributesNoSafeArea() {
    let viewportInsets = Self.insets(at: Self.viewport)
    let phoneInsets = Self.insets(at: HostedProbe.phone)

    let inherited = """
      A `HostedProbe` window reported a safe area of its own — \(Self.viewport) got \
      \(viewportInsets) and \(HostedProbe.phone) got \(phoneInsets). The window is \
      attached to the app's real scene, `containerRelativeFrame` resolves inside the container's \
      safe area and reads straight through the hosted view's `.ignoresSafeArea()`, so the \
      hosted tier starts measuring the host's chrome and the orientation it is in.
      """
    #expect(viewportInsets == .zero, "\(inherited)")
    #expect(phoneInsets == .zero, "\(inherited)")
  }

  /// The reading the invariant protects: the chat replica rests on `ChatColumn.inset` inside
  /// the viewport it asked for. It passes with an upright host even without the fix, because
  /// the inherited insets are then vertical; the case above is the one that fails.
  @Test("The hosted chat column fills the viewport it asked for")
  func theHostedChatColumnFillsItsViewport() {
    var row = CGRect.zero
    var geometry = Geometry()
    let window = HostedProbe.window(
      Replica(onRow: { row = $0 }, onGeometry: { geometry = $0 }),
      size: Self.viewport)
    let scrollBounds = ScrollViewProbe.first(in: window)?.bounds.size ?? .zero
    withExtendedLifetime(window) {}

    let table = """
      row.minX=\(row.minX) row.width=\(row.width) container=\(geometry.containerWidth) \
      content=\(geometry.contentWidth) scrollBounds=\(scrollBounds.width) \
      windowSafeArea=\(window.safeAreaInsets)
      """
    #expect(row.minX == ChatColumn.inset, "\(table)")
    #expect(abs(geometry.containerWidth - Double(Self.viewport.width)) < 0.5, "\(table)")
  }
}

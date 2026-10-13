import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The coordinator's two diagnostic probes must not reach SwiftUI inside a UIKit callback.
///
/// `report()` runs from `scrollViewDidScroll` and `layoutSubviews`, and both can land inside a
/// SwiftUI update: `updateUIView` calls `applyBottomInset()`, and a changed `contentInset`
/// scrolls the view before the update returns. `TerminalScreen` stores both probes in `@State`,
/// so a synchronous call is a state write during a view update, which logs `Modifying state
/// during view update`. `onReaderState` is deferred for the same reason.
///
/// That warning cannot be read in-process (`OSLogStore` reads nothing outside the full pane
/// scene), so this pins the mechanism: no probe call before the callback returns.
@MainActor
@Suite("Chat collection probe deferral")
struct ChatCollectionProbeDeferralTests {
  @Test("a scroll callback hands neither probe to SwiftUI before it returns")
  func aScrollCallbackDefersBothProbes() async {
    let coordinator = ChatCollectionView<EmptyView>.Coordinator(
      row: { _ in EmptyView() },
      accent: .blue,
      accentForeground: .white
    )
    let collection = ChatCollectionView<EmptyView>.makeCollection(wiredTo: coordinator)
    collection.frame = CGRect(x: 0, y: 0, width: 390, height: 600)

    var scrollCalls = 0
    var placeCalls = 0
    coordinator.onScrollGeometry = { _ in scrollCalls += 1 }
    coordinator.onPlaceChange = { _ in placeCalls += 1 }

    coordinator.scrollViewDidScroll(collection)

    #expect(
      scrollCalls == 0,
      """
      onScrollGeometry ran \(scrollCalls) time(s) inside scrollViewDidScroll. That callback \
      can run inside SwiftUI's update, and TerminalScreen writes this probe to @State, so a \
      synchronous call is a state write during a view update.
      """)
    #expect(
      placeCalls == 0,
      """
      onPlaceChange ran \(placeCalls) time(s) inside scrollViewDidScroll. That is a state \
      write during a view update, for the same reason.
      """)

    // Deferred, not dropped: the readout still has to arrive.
    for _ in 0..<50 where scrollCalls == 0 || placeCalls == 0 { await Task.yield() }
    #expect(scrollCalls >= 1, "onScrollGeometry never arrived after the callback returned.")
    #expect(placeCalls >= 1, "onPlaceChange never arrived after the callback returned.")
    withExtendedLifetime(collection) {}
  }
}

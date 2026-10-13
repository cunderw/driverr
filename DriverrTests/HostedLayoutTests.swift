import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// Worked examples for `HostedProbe`: lay a SwiftUI view out at a chosen size and assert its
/// geometry, with no simulator launch and no XCUITest.
///
/// Each pins something that was wrong on a first attempt: a window is mandatory, a child's
/// frame resolves, and a `safeAreaInset` does not move a bar by exactly its own height.
@MainActor
@Suite("Hosted layout")
struct HostedLayoutTests {
  /// Lays a view out at a fixed size through `HostedProbe.window(_:size:)`.
  private func laidOut(
    _ view: some View,
    size: CGSize = CGSize(width: 402, height: 874)
  ) -> UIWindow {
    HostedProbe.window(view, size: size)
  }

  @Test("a view lays out at the size it is given")
  func laysOutAtTheGivenSize() {
    let window = laidOut(Color.red.frame(width: 100, height: 44))

    #expect(window.frame.width == 402)
    #expect(window.frame.height == 874)
  }

  /// The scene-attached window takes its explicit `frame`, whatever size the scene reports.
  @Test("the iPad size lays out at the size it is given too")
  func laysOutAtThePadSizeGiven() {
    let window = HostedProbe.window(Color.red.frame(width: 100, height: 44), size: HostedProbe.pad)
    defer { withExtendedLifetime(window) {} }

    #expect(window.frame.width == 1032)
    #expect(window.frame.height == 1376)
  }

  /// A geometry assertion is worthless if only the container reports a size.
  @Test("a child's resolved frame is readable, not just the root's")
  func childFrameResolves() {
    var measured: CGRect = .zero
    let probe = VStack {
      Spacer()
      Color.blue
        .frame(height: 60)
        .background(
          GeometryReader { proxy in
            Color.clear.onAppear { measured = proxy.frame(in: .global) }
          }
        )
    }

    let window = laidOut(probe)
    withExtendedLifetime(window) {}

    #expect(measured.height == 60)
    // Pinned to the bottom of an 874 pt host, the top of a 60 pt bar sits at 814. No host
    // safe area is subtracted, on any simulator; see `HostedProbe`.
    #expect(measured.minY == 814)
  }

  /// The shape a layout regression test takes: a safe-area inset changes where a
  /// bottom-pinned bar lands.
  @Test("a bottom safe-area inset moves a pinned bar up by the inset")
  func safeAreaMovesAPinnedBar() {
    var withoutInset: CGRect = .zero
    var withInset: CGRect = .zero

    func probe(_ sink: @escaping (CGRect) -> Void) -> some View {
      VStack {
        Spacer()
        Color.blue.frame(height: 60).background(
          GeometryReader { proxy in
            Color.clear.onAppear { sink(proxy.frame(in: .global)) }
          }
        )
      }
    }

    let plain = laidOut(probe { withoutInset = $0 })
    let inset = laidOut(probe { withInset = $0 }.safeAreaInset(edge: .bottom) {
      Color.green.frame(height: 34)
    })
    withExtendedLifetime((plain, inset)) {}

    #expect(withoutInset.minY == 814)
    // Measured: a 34 pt `safeAreaInset` moves the bar up by 42, not 34. The extra 8 is not
    // explained.
    #expect(withInset.minY == 772)
    // What is known: the inset costs at least its own height.
    #expect(withoutInset.minY - withInset.minY >= 34)
  }

  /// A hosted measurement depends on the size asked for and nothing about the host
  /// simulator's chrome. `HostedProbeSafeAreaLeakTests` asserts the window half.
  @Test("a probe window contributes no inset and the view measures the size asked for")
  func viewMeasurementsIgnoreWindowSafeAreaInsets() {
    var phoneMeasured: CGRect = .zero
    var padMeasured: CGRect = .zero

    func probe(_ sink: @escaping (CGRect) -> Void) -> some View {
      VStack {
        Spacer()
        Color.blue.frame(height: 60).background(
          GeometryReader { proxy in
            Color.clear.onAppear { sink(proxy.frame(in: .global)) }
          }
        )
      }
    }

    let phoneWindow = laidOut(probe { phoneMeasured = $0 }, size: HostedProbe.phone)
    let padWindow = HostedProbe.window(probe { padMeasured = $0 }, size: HostedProbe.pad)
    withExtendedLifetime((phoneWindow, padWindow)) {}

    // The bar's bottom is exactly `size.height` on both sizes, whatever the host.
    #expect(phoneWindow.frame.height == HostedProbe.phone.height)
    #expect(padWindow.frame.height == HostedProbe.pad.height)
    #expect(phoneMeasured.minY == HostedProbe.phone.height - 60)
    #expect(padMeasured.minY == HostedProbe.pad.height - 60)
  }
}

/// SwiftUI publishes its accessibility tree only when the accessibility server drives it, so
/// `app["composer.send"].frame` has no in-process equivalent. Forcing the tree with
/// `accessibilityElementCount()` and `accessibilityElement(at:)` also comes back empty.
///
/// A hosted test measures through `measuredFrame(into:)` instead. This fails the day that
/// stops being true, and hosted tests could then query by identifier.
@MainActor
@Suite("Hosted accessibility limits")
struct HostedAccessibilityLimitTests {
  @Test("a hosted SwiftUI view publishes no accessibility identifiers in-process")
  func noIdentifiersInProcess() {
    let probe = Button("Send") {}.accessibilityIdentifier("probe.send")
    let window = HostedProbe.window(probe)
    defer { withExtendedLifetime(window) {} }

    var found: [String] = []
    func walk(_ node: NSObject) {
      if let id = (node as? any UIAccessibilityIdentification)?.accessibilityIdentifier,
        !id.isEmpty
      {
        found.append(id)
      }
      let count = node.accessibilityElementCount()
      if count != NSNotFound && count > 0 {
        for index in 0..<count {
          if let child = node.accessibilityElement(at: index) as? NSObject { walk(child) }
        }
      }
      if let view = node as? UIView { view.subviews.forEach(walk) }
    }
    walk(window)

    #expect(found.isEmpty, "Identifiers are readable now: \(found) — hosted tests could query by id")
  }
}

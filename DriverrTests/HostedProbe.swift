import SwiftUI
import UIKit

/// Lays a SwiftUI view out at a chosen size, in-process, so its geometry can be measured
/// without launching the app.
///
/// It can read back the resolved frame of anything the view reports through a
/// `GeometryReader`. It cannot find a view by accessibility identifier, because SwiftUI
/// builds its accessibility tree only when the accessibility server drives it, and XCUITest
/// arranges that while a hosted test does not. It cannot produce a real keyboard, a presented
/// cover, or a device safe area.
///
/// A scene-attached window inherits whatever part of the host simulator's safe area its frame
/// overlaps, so `.pad` on the iPhone simulator would report the phone's 34 pt home indicator.
/// `additionalSafeAreaInsets` can only add to that, never subtract. `window(_:size:)` therefore
/// wraps the view in `.ignoresSafeArea()` and hosts it in `SafeAreaFreeWindow`. Both are
/// needed: `.ignoresSafeArea()` does not reach `containerRelativeFrame`, which resolves inside
/// the container's safe area.
@MainActor
enum HostedProbe {
  /// The iPhone 17 portrait size the UI suite runs at, so numbers are comparable with a
  /// screenshot or an XCUITest frame.
  static let phone = CGSize(width: 402, height: 874)
  /// `Driverr iPad` portrait.
  static let pad = CGSize(width: 1032, height: 1376)

  /// Lays `view` out at `size` in a key window, with no safe area, and returns the window.
  ///
  /// A window is mandatory. On a detached `UIHostingController.view`, `onAppear` never fires
  /// and every `GeometryReader` reports `.zero`, which reads like a layout bug in the view
  /// under test. Keep the returned window alive while reading measurements, for example with
  /// `withExtendedLifetime`.
  ///
  /// `init(windowScene:)` is used because `init(frame:)` is deprecated. `DriverrTests` is
  /// app-hosted, so a connected scene always exists.
  static func window(_ view: some View, size: CGSize = HostedProbe.phone) -> UIWindow {
    let window = SafeAreaFreeWindow(windowScene: scene())
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
    return show(window)
  }

  /// Lays `view` out at `size` in a key window whose only safe area is `safeAreaBottom` at the
  /// bottom edge: a declared home indicator.
  ///
  /// Some layouts need a known inset. A `safeAreaBar` draws into the bottom inset, so a probe
  /// with no safe area never sees that term. The view is hosted without `.ignoresSafeArea()`.
  ///
  /// Only the bottom is declared. The hosted view's top inset is still the scene's (62 pt on
  /// the iPhone simulator), so read the geometry rather than computing from the window height.
  ///
  /// The inset is fixed for the life of the window. An overridden property cannot raise
  /// `safeAreaInsetsDidChange`, so changing it mid-test gives a stale layout. Resize the window
  /// instead.
  static func window(
    _ view: some View,
    size: CGSize = HostedProbe.phone,
    safeAreaBottom: CGFloat
  ) -> UIWindow {
    let window = FixedSafeAreaWindow(windowScene: scene())
    window.bottom = safeAreaBottom
    window.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = UIHostingController(rootView: view)
    return show(window)
  }

  private static func scene() -> UIWindowScene {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
      as? UIWindowScene
    else {
      preconditionFailure(
        "HostedProbe needs a connected UIWindowScene — DriverrTests is app-hosted (TEST_HOST) "
          + "precisely so one is always available."
      )
    }
    return scene
  }

  private static func show(_ window: UIWindow) -> UIWindow {
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    // `onAppear` is delivered asynchronously. One run-loop turn is not reliably enough.
    for _ in 0..<5 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return window
  }
}

/// A scene-attached window that reports no safe area, so a hosted measurement depends only on
/// the size asked for. The override is what reaches `containerRelativeFrame`; see `HostedProbe`.
final class SafeAreaFreeWindow: UIWindow {
  override var safeAreaInsets: UIEdgeInsets { .zero }
}

/// A scene-attached window that reports one declared bottom inset and nothing else. Set
/// `bottom` before the window is shown; see `HostedProbe.window(_:size:safeAreaBottom:)`.
final class FixedSafeAreaWindow: UIWindow {
  var bottom: CGFloat = 0

  override var safeAreaInsets: UIEdgeInsets {
    UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
  }
}

extension View {
  /// Reports this view's frame in global coordinates, for a hosted layout test. The in-process
  /// replacement for `app["some.identifier"].frame`; see `HostedProbe`.
  func measuredFrame(into sink: @escaping @MainActor (CGRect) -> Void) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.onAppear { sink(proxy.frame(in: .global)) }
      }
    )
  }
}

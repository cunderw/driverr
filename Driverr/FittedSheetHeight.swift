import DriverrCore
import SwiftUI
import UIKit

/// Sizes a form sheet to its own content on regular width.
///
/// Uses `preferredContentSize`, not a `PresentationSizing`. `FormPresentationSizing`
/// proposes no height, and a sizing is read once at presentation, before anything is
/// measured. `preferredContentSize` is re-read, so a measurement a frame late still lands.
/// Do not replace this with `.presentationSizing` or `.fitted`; both were tried on this sheet.
/// Detents turn the card into a bottom sheet and make `app.swipeUp()` inert, which tests
/// that scroll these sheets rely on. See `SheetContentHeight`.
///
/// Compact keeps the page sheet. The caller passes `isEnabled` because an iPad form sheet's
/// own `horizontalSizeClass` reads compact, as with `PaneSheetView.isRegularWidth`.
struct FittedSheetHeight: ViewModifier {
  var isEnabled: Bool

  /// The sheet's height before this modifier touched it, captured once. See
  /// `SheetContentHeight.fitted(content:natural:)` for why re-reading it oscillates.
  @State private var natural: Double?
  /// The content's height, remeasured whenever it changes by more than the tolerance.
  @State private var content: Double?

  func body(content view: Content) -> some View {
    view
      // Content height plus the top inset, which is the navigation bar. Not the bottom inset:
      // keyboard avoidance lands there, and the sheet would grow while someone types.
      .onScrollGeometryChange(for: SheetContentMeasurement.self) { geometry in
        SheetContentMeasurement(
          content: geometry.contentSize.height + geometry.contentInsets.top,
          container: geometry.containerSize.height
        )
      } action: { _, measured in
        // Only the first reading is taken before a height is applied, so only it is natural.
        if natural == nil, measured.container > SheetContentHeight.minimum {
          natural = measured.container
        }
        // Small deltas are dropped. Applying a height reports new geometry, which would apply
        // a height again.
        guard let previous = self.content else {
          self.content = measured.content
          return
        }
        guard abs(measured.content - previous) >= SheetContentHeight.slack else { return }
        self.content = measured.content
      }
      .background(
        SheetHeightApplier(
          height: isEnabled
            ? SheetContentHeight.fitted(content: content, natural: natural)
            : nil
        )
      )
  }
}

extension View {
  /// Sizes the sheet this scroll view is in to its content, on regular width only. Attach
  /// it to the `Form` or `List`, where the scroll geometry is.
  func fittedSheetHeight(isEnabled: Bool) -> some View {
    modifier(FittedSheetHeight(isEnabled: isEnabled))
  }
}

/// Applies a height to the view controller presenting the view this sits behind. A zero
/// `preferredContentSize` means no preference, which restores the natural height.
private struct SheetHeightApplier: UIViewControllerRepresentable {
  var height: Double?

  func makeUIViewController(context: Context) -> Controller { Controller() }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.apply(height)
  }

  final class Controller: UIViewController {
    func apply(_ height: Double?) {
      // `parent` walks containment, never presentations, so this stops at the presented
      // controller.
      var top: UIViewController = self
      while let parent = top.parent { top = parent }

      guard let height else {
        if top.preferredContentSize != .zero { top.preferredContentSize = .zero }
        return
      }
      let width = top.view.bounds.width
      guard width > 0 else { return }
      // A requested height draws about 20 pt taller, unexplained (420 pt gives a 440 pt card).
      // Not corrected: the rule is shrink-only, so the extra cannot clip. Subtracting it could.
      let wanted = CGSize(width: width, height: height)
      guard top.preferredContentSize != wanted else { return }
      top.preferredContentSize = wanted
    }
  }
}

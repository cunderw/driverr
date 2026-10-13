import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The host screen's reading measure.
///
/// This drives `readableDetailColumn(isRegularWidth:)`, the modifier `HostDetailView.body`
/// applies to its `Form`, over a stand-in `Form`. `HostDetailView` publishes no frame to
/// measure, and adding one to production for this is the worse trade. So the claim is that the
/// cap and centring are right, not that `HostDetailView` applies them.
@MainActor
@Suite("Host detail column layout")
struct HostDetailColumnLayoutTests {
  /// A `Form` of roughly the host screen's shape. Its content does not matter to the
  /// measurement; that it is a `Form`, and so fills whatever width it is given, does.
  private func probeForm(measuring sink: @escaping @MainActor (CGRect) -> Void) -> some View {
    Form {
      Section("Connection") {
        Text("carson@10.1.0.9")
        Text("Port 22")
      }
      Section {
        Text("Driverr talks to this machine over SSH and nothing else.")
      }
    }
    .measuredFrame(into: sink)
  }

  /// An uncapped form on the iPad sets prose at nearly twice the phone's width.
  /// `TerminalSceneRoute.readableWidth` is the app's one reading measure.
  @Test("on a regular-width column the form is capped at the reading measure")
  func capsAtTheReadingMeasure() {
    var measured: CGRect = .zero
    let window = HostedProbe.window(
      probeForm(measuring: { measured = $0 }).readableDetailColumn(isRegularWidth: true),
      size: HostedProbe.pad
    )
    defer { withExtendedLifetime(window) {} }

    #expect(
      measured.width == CGFloat(TerminalSceneRoute.readableWidth),
      "The form resolved to \(measured.width) pt in a 1032 pt window."
    )
  }

  /// A bare `maxWidth` leaves the content pinned to the leading edge, which reads as a
  /// layout fault rather than a measure. The second `frame(maxWidth: .infinity)` is what
  /// centres it, and it is the modifier easiest to leave out.
  @Test("the capped form is centred in the column, not pinned to its leading edge")
  func centresTheCappedForm() {
    var measured: CGRect = .zero
    let window = HostedProbe.window(
      probeForm(measuring: { measured = $0 }).readableDetailColumn(isRegularWidth: true),
      size: HostedProbe.pad
    )
    defer { withExtendedLifetime(window) {} }

    let expectedLeading = (HostedProbe.pad.width - CGFloat(TerminalSceneRoute.readableWidth)) / 2
    #expect(
      abs(measured.minX - expectedLeading) < 1,
      "The form starts at \(measured.minX) pt; centred it would start at \(expectedLeading)."
    )
  }

  /// Compact width applies nothing: a phone is already narrower than the measure.
  @Test("on a compact column nothing is applied and the form fills the width")
  func compactWidthIsUntouched() {
    var measured: CGRect = .zero
    let window = HostedProbe.window(
      probeForm(measuring: { measured = $0 }).readableDetailColumn(isRegularWidth: false),
      size: HostedProbe.phone
    )
    defer { withExtendedLifetime(window) {} }

    #expect(measured.width == HostedProbe.phone.width)
    #expect(measured.minX == 0)
  }
}

// DEBUG INSTRUMENT FOR #40. Not for merge.
//
// Records what happens to a tap on the `Chat | Terminal` segment, so a failing UI run says
// where the tap died: below the app (no touch), on another view (touch, wrong hit view), in
// the setter (setter never called), in `show` (an early exit), or after it (memory wiped,
// or a demote re-ran the open).

#if DEBUG
import Observation
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
@Observable
final class SurfaceTapProbe {
  static let shared = SurfaceTapProbe()

  static let isEnabled = ProcessInfo.processInfo.arguments.contains("-uiTesting")

  var setterCalls = 0
  var lastSet = "-"
  var showCalls = 0
  var showExit = "-"
  var wipes = "-"
  var demoteFires = 0
  var touches: [String] = []
  var segmentFrame = CGRect.zero
  var surfacesFrame = CGRect.zero
  var state = "-"

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  static func stamp() -> String { clock.string(from: Date()) }

  func noteSet(_ value: PaneSurface) {
    setterCalls += 1
    lastSet = "\(value)@\(Self.stamp())"
  }

  func noteShow(_ value: PaneSurface, _ exit: String) {
    showCalls += 1
    showExit = "\(value):\(exit)@\(Self.stamp())"
  }

  func noteTouch(_ text: String) {
    touches.append("\(text)@\(Self.stamp())")
    if touches.count > 10 { touches.removeFirst(touches.count - 10) }
  }

  var summary: String {
    func rect(_ r: CGRect) -> String {
      "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))"
    }
    return "setter=\(setterCalls) lastSet=\(lastSet) show=\(showCalls) showExit=\(showExit)"
      + " wipes=\(wipes) demotes=\(demoteFires) state=\(state)"
      + " seg=\(rect(segmentFrame)) surf=\(rect(surfacesFrame))"
      + " touches=[\(touches.joined(separator: " ; "))]"
  }
}

/// The readout: a 1x1 element outside every identified container.
struct SurfaceTapReadout: View {
  var probe = SurfaceTapProbe.shared

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .background(TouchTap())
      .accessibilityElement()
      .accessibilityIdentifier("debug.surfaceTap")
      .accessibilityLabel(probe.summary)
      .allowsHitTesting(false)
  }
}

/// Installs a recognizer on the window that records every touch's hit view and fails at
/// once, so it neither cancels nor delays anything.
private struct TouchTap: UIViewRepresentable {
  func makeUIView(context: Context) -> InstallerView { InstallerView() }
  func updateUIView(_ uiView: InstallerView, context: Context) {}

  final class InstallerView: UIView {
    private var installed: UIWindow?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let window, installed !== window else { return }
      installed = window
      let recognizer = Recorder(target: nil, action: nil)
      recognizer.cancelsTouchesInView = false
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      window.addGestureRecognizer(recognizer)
    }
  }

  final class Recorder: UIGestureRecognizer {
    /// Records each touch's hit view as it begins, and how a touch on the segment ends, then
    /// fails. It never recognizes, so it cancels and delays nothing.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      for touch in touches {
        let point = touch.location(in: nil)
        var names: [String] = []
        var view = touch.view
        while let current = view, names.count < 3 {
          names.append(String(describing: type(of: current)))
          view = current.superview
        }
        let control = Self.segmentedControl(above: touch.view)
        if let control { ValueChangeLog.shared.watch(control) }
        let text = "began \(Int(point.x)),\(Int(point.y)) seg=\(control != nil) \(names.joined(separator: "<"))"
        SurfaceTapProbe.shared.noteTouch(text)
      }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      finish(touches, "ended")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      finish(touches, "CANCELLED")
    }

    private func finish(_ touches: Set<UITouch>, _ phase: String) {
      for touch in touches where Self.segmentedControl(above: touch.view) != nil {
        SurfaceTapProbe.shared.noteTouch("\(phase) seg")
      }
      state = .failed
    }

    static func segmentedControl(above view: UIView?) -> UISegmentedControl? {
      var view = view
      while let current = view {
        if let control = current as? UISegmentedControl { return control }
        view = current.superview
      }
      return nil
    }
  }
}

/// Logs every `.valueChanged` a watched segmented control sends, before SwiftUI's binding.
@MainActor
private final class ValueChangeLog: NSObject {
  static let shared = ValueChangeLog()
  private var watched: Set<ObjectIdentifier> = []

  func watch(_ control: UISegmentedControl) {
    guard watched.insert(ObjectIdentifier(control)).inserted else { return }
    control.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
  }

  @objc private func changed(_ control: UISegmentedControl) {
    SurfaceTapProbe.shared.noteTouch("valueChanged=\(control.selectedSegmentIndex)")
  }
}
#endif

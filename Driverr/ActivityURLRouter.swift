import DriverrCore
import Foundation

/// Routes a tap on the Live Activity to `TerminalPresenter`.
///
/// The URL parse is `DriverrCore.BlockedPaneActivityRoute`, so `swift test` covers it. This is a
/// `@MainActor static` so `DriverrTests` can drive it without a scene. `requestOpen` only records
/// the request, because SwiftUI expects a URL handler to return, and `ContentView` drains it.
/// That is also why a cold launch from a card works.
enum ActivityURLRouter {
  /// Routes one URL and returns whether it was one of ours.
  ///
  /// An unrecognised URL is ignored and is not an error, because a card can outlive the build
  /// that posted it. Only the tests read the return value.
  @discardableResult
  @MainActor
  static func route(url: URL, to presenter: TerminalPresenter) -> Bool {
    guard let target = BlockedPaneActivityRoute.target(of: url) else { return false }
    switch target {
    case .pane(let hostID, let paneID):
      presenter.requestOpen(hostID: hostID, paneID: paneID)
    case .host(let hostID):
      // The remembered-pane resume needs the host's session tree, so
      // `TerminalPresenter.resumeRememberedPane` resolves it when the request is drained.
      presenter.requestOpen(hostID: hostID, intent: .host)
    }
    return true
  }
}

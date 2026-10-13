import Foundation

/// The phone's navigation path, derived rather than stored.
///
/// On compact width `ContentView` is a `NavigationStack` with two levels: the host screen,
/// derived from `selectedHostID`, and the pane scene, derived from
/// `TerminalPresenter.request`. Neither level has state of its own. A wrong answer here
/// strands the reader or ends a shell on Back, so `PhoneStackPathTests` asserts it.
public enum PhoneStackPath {
  /// One level of the phone's stack.
  ///
  /// Both levels are one typed path. Do not hang the pane level off a
  /// `navigationDestination(isPresented:)` in the host screen: a cross-host pick replaces the
  /// host screen, the destination is recreated with `isPresented` already `true`, and
  /// SwiftUI pushes nothing. `PaneSwitchUITests.testTheSwitcherListsAnotherConnectedHostAndGoesThere`
  /// catches it. With one path, a cross-host pick just rewrites element 0.
  public enum Route: Hashable, Sendable {
    /// The host screen, for the chosen host.
    case host(UUID)
    /// The pane scene. It carries no host id, because `TerminalPresenter.request` owns that
    /// and a copy could disagree.
    case pane
  }

  /// The stack's path for a selection and presentation.
  ///
  /// At most one host screen and one pane scene, in that order, however many writes arrive.
  /// That keeps the derivation stable when SwiftUI treats a row tap as a push, a selection
  /// write, or both. A request with no host cannot happen in the app, and yields an empty
  /// path rather than a trap.
  public static func path(selectedHostID: UUID?, hasRequest: Bool) -> [Route] {
    guard let selectedHostID else { return [] }
    return hasRequest ? [.host(selectedHostID), .pane] : [.host(selectedHostID)]
  }

  /// What a write through the path binding has to do besides moving the selection.
  public enum WriteEffect: Equatable, Sendable {
    /// Nothing to unwind: a push, or a pop that leaves the levels it found.
    case none
    /// The pane scene was popped (Back or the edge swipe). The scene ends and the host stays
    /// chosen, because the reader is on its screen.
    case endScene
    /// The stack popped to the host list with no scene up: forget the chosen host.
    case deselect
    /// The stack popped past an open pane to the host list (long press on Back, "Hosts").
    /// The scene ends and the host is forgotten.
    case endSceneAndDeselect
  }

  /// The rule for a write through the path binding.
  ///
  /// - Parameters:
  ///   - newPath: the path SwiftUI is writing.
  ///   - hadRequest: whether `TerminalPresenter.request` is set at the moment of the write.
  public static func effect(ofWrite newPath: [Route], hadRequest: Bool) -> WriteEffect {
    let losesScene = hadRequest && !newPath.contains(.pane)
    let keepsHost = newPath.contains { if case .host = $0 { return true } else { return false } }
    switch (losesScene, keepsHost) {
    case (true, true): return .endScene
    case (true, false): return .endSceneAndDeselect
    case (false, true): return .none
    case (false, false): return newPath.isEmpty ? .deselect : .none
    }
  }

  /// The chosen host a written path implies, or `nil` when it popped to the list.
  public static func selection(inWrite newPath: [Route]) -> UUID? {
    for route in newPath {
      if case .host(let id) = route { return id }
    }
    return nil
  }
}

import Foundation

/// The phone's navigation path, derived rather than stored.
///
/// On compact width `ContentView` is a `NavigationStack` with three levels: the host screen,
/// derived from `selectedHostID`, the pane scene, derived from `TerminalPresenter.request`,
/// and a sub-agent's chat, derived from whether the scene's pane has one open. No level has
/// state of its own. A wrong answer here
/// strands the reader or ends a shell on Back, so `PhoneStackPathTests` asserts it.
public enum PhoneStackPath {
  /// One level of the phone's stack.
  ///
  /// Every level is one typed path. Do not hang the pane level off a
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
    /// A sub-agent's conversation, opened from the pane's chat. It carries no link, because
    /// the pane's transcript model owns which sub-agent is open, and holds at most one.
    case subagent
  }

  /// The stack's path for a selection and presentation.
  ///
  /// At most one host screen, one pane scene and one sub-agent, in that order, however many
  /// writes arrive. That keeps the derivation stable when SwiftUI treats a row tap as a push,
  /// a selection write, or both. A request with no host cannot happen in the app, and yields
  /// an empty path rather than a trap. A sub-agent with no scene has nothing to stand on, so it
  /// is left out.
  public static func path(
    selectedHostID: UUID?, hasRequest: Bool, showsSubagent: Bool = false
  ) -> [Route] {
    guard let selectedHostID else { return [] }
    guard hasRequest else { return [.host(selectedHostID)] }
    return showsSubagent
      ? [.host(selectedHostID), .pane, .subagent] : [.host(selectedHostID), .pane]
  }

  /// What a write through the path binding has to do besides moving the selection.
  public enum WriteEffect: Equatable, Sendable {
    /// Nothing to unwind: a push, or a pop that leaves the levels it found.
    case none
    /// The pane scene was popped (Back or the edge swipe). The scene ends and the host stays
    /// chosen, because the reader is on its screen.
    case endScene
    /// The sub-agent was popped (Back or the edge swipe) and the pane scene stays: close the
    /// sub-agent, so the pane's own chat is what the scene shows.
    case closeSubagent
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
  ///   - hadSubagent: whether the scene's pane had a sub-agent open at the moment of the write.
  ///
  /// A pop past the pane (the long press on Back) ends the scene, which closes the sub-agent
  /// with it, so it is never reported as `closeSubagent`.
  public static func effect(
    ofWrite newPath: [Route], hadRequest: Bool, hadSubagent: Bool = false
  ) -> WriteEffect {
    let losesScene = hadRequest && !newPath.contains(.pane)
    let keepsHost = newPath.contains { if case .host = $0 { return true } else { return false } }
    switch (losesScene, keepsHost) {
    case (true, true): return .endScene
    case (true, false): return .endSceneAndDeselect
    case (false, true):
      return hadRequest && hadSubagent && !newPath.contains(.subagent) ? .closeSubagent : .none
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

import Foundation

extension Pane {
  /// The second line of a pane row, in the host screen's tree and the iPad sidebar's: what
  /// the pane is doing, or where it is.
  ///
  /// An agent's is `{agent} · {status}` in herdr's format, so the state is in words and not
  /// only colour. A stopped agent says `Stopped`, not herdr's `Blocked`. When the title
  /// already names the agent, the directory takes the agent's place. A shell shows its
  /// directory, which the view truncates from the head.
  public func rowSubtitle(stop: PaneStopBadge?) -> String? {
    if let agent {
      let status = stop?.label ?? agent.status.displayName
      if title.caseInsensitiveCompare(agent.name) == .orderedSame {
        return [status, directory].compactMap { $0 }.joined(separator: " · ")
      }
      return "\(agent.name) · \(status)"
    }
    return directory
  }
}

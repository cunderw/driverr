import DriverrCore

extension SessionTree {
  /// The folders the New Agent sheet offers first: each pane's working directory, once, in the
  /// tree's order, at most `limit` of them.
  ///
  /// A pane on a machine a herdr-core added is left out. Its folder is on that machine's own
  /// file system, and an agent starts on the connected computer. A pane with no directory is
  /// left out too.
  public func agentFolders(limit: Int = 6) -> [String] {
    var seen = Set<String>()
    var folders: [String] = []
    for pane in allPanes where folders.count < limit {
      guard let folder = pane.directory, !folder.isEmpty,
        CorePaneID.machine(of: pane.id) == nil, pane.agent?.machine == nil,
        seen.insert(folder).inserted
      else { continue }
      folders.append(folder)
    }
    return folders
  }
}

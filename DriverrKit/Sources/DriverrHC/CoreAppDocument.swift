import Foundation

/// The part of the Herdr desktop app's `herdr-app` document that names and orders things.
///
/// The format is private to the app and can change under any release, so nothing here is
/// required and a document this cannot read costs only the order. Labels build the groups;
/// this never adds or removes one. Driverr never writes it.
struct CoreAppDocument: Decodable, Equatable, Sendable {
  struct Space: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let tabs: [Tab]?
  }

  struct Tab: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let root: Node?
  }

  /// One split or one leaf of a tab's layout. Only a leaf has `content`.
  struct Node: Decodable, Equatable, Sendable {
    struct Content: Decodable, Equatable, Sendable {
      let terminal: String?
    }

    let children: [Node]?
    let content: Content?

    /// The terminals under this node, depth first.
    var terminals: [String] {
      [content?.terminal].compactMap { $0 } + (children ?? []).flatMap(\.terminals)
    }
  }

  static let name = "herdr-app"

  let spaces: [Space]?

  /// Where each space, tab and terminal stands, and what the app calls it.
  struct Index {
    private(set) var spaceRanks: [String: Int] = [:]
    private(set) var tabRanks: [String: Int] = [:]
    private(set) var terminalRanks: [String: Int] = [:]
    private(set) var names: [String: String] = [:]

    init(_ document: CoreAppDocument?) {
      for space in document?.spaces ?? [] {
        Self.note(space.id, name: space.name, in: &spaceRanks, names: &names)
        for tab in space.tabs ?? [] {
          Self.note(tab.id, name: tab.name, in: &tabRanks, names: &names)
          for terminal in tab.root?.terminals ?? [] where terminalRanks[terminal] == nil {
            terminalRanks[terminal] = terminalRanks.count
          }
        }
      }
    }

    private static func note(
      _ id: String?,
      name: String?,
      in ranks: inout [String: Int],
      names: inout [String: String]
    ) {
      guard let id, ranks[id] == nil else { return }
      ranks[id] = ranks.count
      if let name, !name.isEmpty { names[id] = name }
    }
  }
}

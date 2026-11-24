import Foundation

/// The saved host list, read one element at a time.
///
/// A whole-array decode fails on one element this build cannot read, for example a host whose
/// `authMethod` is a case a newer build added. A store that then saves writes that failure
/// over every host. This type decodes each element on its own and keeps every element's JSON.
/// `encoded()` writes that JSON back for each element `save(_:)` did not replace, so a save or
/// a delete by an older build keeps a newer build's hosts and the fields it does not know.
///
/// Kept JSON is JSON-equal to what was stored, not byte-equal: keys are sorted, `/` is
/// escaped, and a number can print differently (`-0` becomes `0`).
public struct StoredHostList: Sendable, Equatable {
  /// One element of the stored array.
  enum Entry: Sendable, Equatable {
    /// A host this build reads. `raw` is its stored JSON, or nil once `save(_:)` replaced it.
    case host(Host, raw: Data?)
    /// An element that does not decode as a `Host`.
    case unreadable(Data)
  }

  private(set) var entries: [Entry]

  /// True when there was stored data and none of it can be kept: it is not a JSON array, or
  /// an element holds a value JSON cannot write back (such as `-1e400`, which parses as
  /// infinity). The list then reads as empty and the next write replaces the data.
  public let storedDataIsUnreadable: Bool

  /// Reads `data` as a JSON array of hosts. No data, or data `storedDataIsUnreadable`
  /// describes, reads as an empty list.
  public init(data: Data?) {
    guard let data else {
      entries = []
      storedDataIsUnreadable = false
      return
    }
    guard
      let elements = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        as? [Any],
      // `data(withJSONObject:)` raises an exception, which `try?` cannot catch, on a value
      // it cannot write, such as infinity. Checking first keeps a bad list from crashing launch.
      elements.allSatisfy({ JSONSerialization.isValidJSONObject([$0]) })
    else {
      entries = []
      storedDataIsUnreadable = true
      return
    }
    let decoder = JSONDecoder()
    entries = elements.compactMap { element in
      // `.fragmentsAllowed`: without it a bare string, number or null raises an exception.
      guard
        let raw = try? JSONSerialization.data(
          withJSONObject: element, options: [.sortedKeys, .fragmentsAllowed])
      else { return nil }
      if let host = try? decoder.decode(Host.self, from: raw) {
        return .host(host, raw: raw)
      }
      return .unreadable(raw)
    }
    storedDataIsUnreadable = false
  }

  /// The hosts this build can read, in stored order.
  public var hosts: [Host] {
    entries.compactMap { entry in
      if case .host(let host, _) = entry { return host }
      return nil
    }
  }

  /// Replaces the host with the same id in place, or appends it.
  public mutating func save(_ host: Host) {
    if let index = entries.firstIndex(where: { $0.hostID == host.id }) {
      entries[index] = .host(host, raw: nil)
    } else {
      entries.append(.host(host, raw: nil))
    }
  }

  /// Removes every host with this id. Unreadable elements stay.
  public mutating func delete(_ id: UUID) {
    entries.removeAll { $0.hostID == id }
  }

  /// The list as a JSON array: each element's kept JSON, or the encoded host where `save(_:)`
  /// replaced or added it.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    var data = Data("[".utf8)
    for (index, entry) in entries.enumerated() {
      if index > 0 { data.append(Data(",".utf8)) }
      switch entry {
      case .host(_, let raw?), .unreadable(let raw): data.append(raw)
      case .host(let host, nil): data.append(try encoder.encode(host))
      }
    }
    data.append(Data("]".utf8))
    return data
  }
}

extension StoredHostList.Entry {
  fileprivate var hostID: UUID? {
    if case .host(let host, _) = self { return host.id }
    return nil
  }
}

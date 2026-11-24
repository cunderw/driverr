import Foundation

/// The saved host list, read one element at a time.
///
/// A whole-array decode fails on one element this build cannot read, for example a host whose
/// `authMethod` is a case a newer build added. A store that then saves writes that failure
/// over every host. This type decodes each element on its own. An element it cannot read
/// stays as raw JSON in its original position, and `encoded()` writes it back, so a save or
/// a delete by an older build keeps it.
public struct StoredHostList: Sendable, Equatable {
  /// One element of the stored array.
  public enum Entry: Sendable, Equatable {
    case host(Host)
    /// An element that does not decode as a `Host`. The JSON is re-serialized once with
    /// sorted keys, so the same element always gives the same bytes.
    case unreadable(Data)
  }

  public private(set) var entries: [Entry]

  /// True when there was stored data and it was not a JSON array. Nothing of it is kept, so
  /// the next write replaces it.
  public let storedDataIsUnreadable: Bool

  /// Reads `data` as a JSON array of hosts. No data, or data that is not a JSON array, reads
  /// as an empty list.
  public init(data: Data?) {
    guard let data else {
      entries = []
      storedDataIsUnreadable = false
      return
    }
    guard
      let elements = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        as? [Any]
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
        return .host(host)
      }
      return .unreadable(raw)
    }
    storedDataIsUnreadable = false
  }

  /// The hosts this build can read, in stored order.
  public var hosts: [Host] {
    entries.compactMap { entry in
      if case .host(let host) = entry { return host }
      return nil
    }
  }

  /// Replaces the host with the same id in place, or appends it.
  public mutating func save(_ host: Host) {
    if let index = entries.firstIndex(where: { $0.hostID == host.id }) {
      entries[index] = .host(host)
    } else {
      entries.append(.host(host))
    }
  }

  /// Removes every host with this id. Unreadable elements stay.
  public mutating func delete(_ id: UUID) {
    entries.removeAll { $0.hostID == id }
  }

  /// The list as a JSON array. With no unreadable elements this is exactly
  /// `JSONEncoder().encode(hosts)`.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    guard entries.contains(where: { $0.hostID == nil }) else {
      return try encoder.encode(hosts)
    }
    var data = Data("[".utf8)
    for (index, entry) in entries.enumerated() {
      if index > 0 { data.append(Data(",".utf8)) }
      switch entry {
      case .host(let host): data.append(try encoder.encode(host))
      case .unreadable(let raw): data.append(raw)
      }
    }
    data.append(Data("]".utf8))
    return data
  }
}

extension StoredHostList.Entry {
  fileprivate var hostID: UUID? {
    if case .host(let host) = self { return host.id }
    return nil
  }
}

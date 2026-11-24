import Foundation
import Testing

@testable import DriverrCore

@Suite("StoredHostList")
struct StoredHostListTests {
  private func host(_ name: String) -> Host {
    Host(name: name, hostname: "10.1.0.9", username: "carson")
  }

  /// One stored element as JSON text, with `authMethod` as raw JSON.
  private func element(_ name: String, authMethod: String, id: Bool = true) -> String {
    let idField = id ? #""id":"\#(UUID().uuidString)","# : ""
    return #"{\#(idField)"name":"\#(name)","hostname":"10.1.0.9","port":22,"#
      + #""username":"carson","authMethod":\#(authMethod)}"#
  }

  private let unknown = #"{"quantum":{}}"#
  private let password = #"{"password":{}}"#

  /// Parses a JSON array into Foundation objects, for comparing by value.
  private func array(_ data: Data) throws -> NSArray {
    try #require(
      try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? NSArray)
  }

  private func threeWithUnknownMiddle() -> (data: Data, middle: String) {
    let middle = element("future", authMethod: unknown)
    let text = "[\(element("first", authMethod: password)),\(middle),"
      + "\(element("last", authMethod: password))]"
    return (Data(text.utf8), middle)
  }

  private func unreadable(_ list: StoredHostList) -> [Data] {
    list.entries.compactMap { entry in
      if case .unreadable(let raw) = entry { return raw }
      return nil
    }
  }

  /// Which entries are unreadable, in order.
  private func shape(_ list: StoredHostList) -> [Bool] {
    list.entries.map { entry in
      if case .unreadable = entry { return true }
      return false
    }
  }

  @Test("an element with an unknown auth method drops only that host")
  func unknownCaseDropsOneHost() {
    let list = StoredHostList(data: threeWithUnknownMiddle().data)

    #expect(list.hosts.map(\.name) == ["first", "last"])
    #expect(list.entries.count == 3)
    #expect(!list.storedDataIsUnreadable)
  }

  @Test("a save keeps the unreadable element, in its position and with the same bytes")
  func saveKeepsUnreadable() throws {
    let (data, middle) = threeWithUnknownMiddle()
    var list = StoredHostList(data: data)
    let raw = unreadable(list)

    list.save(host("added"))
    let saved = try list.encoded()
    var reread = StoredHostList(data: saved)
    reread.save(host("again"))
    let resaved = StoredHostList(data: try reread.encoded())

    let elements = try array(saved)
    #expect(elements.count == 4)
    let original = try array(Data("[\(middle)]".utf8))[0] as? NSDictionary
    #expect(elements[1] as? NSDictionary == original)
    #expect(reread.hosts.map(\.name) == ["first", "last", "added", "again"])
    #expect(raw.count == 1)
    #expect(unreadable(reread) == raw)
    #expect(unreadable(resaved) == raw)
    #expect(shape(resaved) == [false, true, false, false, false])
  }

  @Test("editing a host replaces it in place")
  func saveReplacesInPlace() {
    var list = StoredHostList(data: threeWithUnknownMiddle().data)
    var first = list.hosts[0]
    first.name = "renamed"

    list.save(first)

    #expect(list.hosts.map(\.name) == ["renamed", "last"])
    #expect(list.entries.count == 3)
  }

  @Test("a delete keeps the unreadable element")
  func deleteKeepsUnreadable() throws {
    var list = StoredHostList(data: threeWithUnknownMiddle().data)
    let raw = unreadable(list)

    list.delete(list.hosts[0].id)
    let reread = StoredHostList(data: try list.encoded())

    #expect(reread.hosts.map(\.name) == ["last"])
    #expect(reread.entries.count == 2)
    #expect(unreadable(reread) == raw)
    #expect(shape(reread) == [true, false])
  }

  @Test("an element with no id is unreadable")
  func missingIDIsUnreadable() {
    let text = "[\(element("noid", authMethod: password, id: false)),"
      + "\(element("ok", authMethod: password))]"

    let list = StoredHostList(data: Data(text.utf8))

    #expect(list.hosts.map(\.name) == ["ok"])
    #expect(unreadable(list).count == 1)
  }

  @Test("elements that are not objects survive a save and do not crash")
  func nonObjectElementsSurvive() throws {
    let text = #"[1,"x",null,\#(element("ok", authMethod: password))]"#
    var list = StoredHostList(data: Data(text.utf8))

    #expect(list.hosts.map(\.name) == ["ok"])
    list.save(host("added"))
    let saved = try list.encoded()

    let elements = try array(saved)
    #expect(elements.count == 5)
    #expect(elements[0] as? Int == 1)
    #expect(elements[1] as? String == "x")
    #expect(elements[2] is NSNull)
    #expect(StoredHostList(data: saved).hosts.map(\.name) == ["ok", "added"])
  }

  @Test("with nothing unreadable the bytes are JSONEncoder's for [Host]")
  func roundTripMatchesEncoder() throws {
    let hosts = [host("one"), Host(name: "two", hostname: "h", username: "u", authMethod: .none)]
    let data = try JSONEncoder().encode(hosts)

    let list = StoredHostList(data: data)

    #expect(list.hosts == hosts)
    #expect(try list.encoded() == JSONEncoder().encode(hosts))
  }

  @Test("data that is not an array reads as empty and is marked unreadable")
  func nonArrayIsEmpty() {
    for text in ["nope", #"{"id":"x"}"#, #""string""#] {
      let list = StoredHostList(data: Data(text.utf8))
      #expect(list.hosts.isEmpty)
      #expect(list.entries.isEmpty)
      #expect(list.storedDataIsUnreadable)
    }
  }

  @Test("no data reads as empty and is not marked unreadable")
  func noDataIsEmpty() throws {
    let list = StoredHostList(data: nil)

    #expect(list.hosts.isEmpty)
    #expect(!list.storedDataIsUnreadable)
    #expect(try list.encoded() == Data("[]".utf8))
  }
}

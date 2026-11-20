import Foundation
import Testing

@testable import DriverrHC

/// The fake's own ordering, because a test that holds answers is only as sound as the fake.
@Suite("Fake core stream", .timeLimit(.minutes(1)))
struct FakeCoreStreamTests {
  private func call(_ id: Int) -> Data {
    let json = #"{"id":\#(id),"jsonrpc":"2.0","method":"doc.get","params":{}}"#
    return CoreFrame(channel: 0, kind: .data, payload: Data(json.utf8)).encoded
  }

  /// Every id answered on `stream`, in the order the answers were written.
  private func answered(_ stream: FakeCoreStream) async throws -> [Int] {
    stream.finish()
    var bytes = Data()
    for try await chunk in stream.output { bytes.append(chunk) }
    var decoder = CoreFrameDecoder()
    return try decoder.append(bytes).compactMap { frame in
      let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
      return object?["id"] as? Int
    }
  }

  /// A reply made while `flushHeld()` is writing lands after the held ones.
  ///
  /// One byte per chunk and thirty held answers make the write long, so a reply that gets in
  /// ahead of it does so on nearly every pass. The loop covers the rest.
  @Test("a reply made during a flush lands after the answers that were held")
  func flushKeepsOrder() async throws {
    let held = Array(1...30)
    for _ in 0..<200 {
      let stream = FakeCoreStream()
      stream.helloReply = nil
      stream.chunkSize = 1
      try await stream.send(Data("hello\n".utf8))
      stream.holdsReplies = true
      for id in held { try await stream.send(call(id)) }

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { stream.flushHeld() }
        group.addTask { try await stream.send(call(31)) }
        try await group.waitForAll()
      }

      #expect(try await answered(stream) == held + [31])
    }
  }
}

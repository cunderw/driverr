import DriverrCore
import DriverrHerdr
import Foundation

@testable import DriverrHC

/// A scripted `hc connect`: it answers `hello`, then answers JSON-RPC calls in frames, and it
/// controls exactly where the chunks of its output fall.
///
/// `chunkSize` splits every write, so a test that passes with `1` has seen every byte arrive
/// on its own.
final class FakeCoreStream: HerdrStream, @unchecked Sendable {
  /// What the fake does with a call, by method.
  enum Reply {
    case result(String)
    case error(String)
    /// Never answers, for the deadline tests.
    case silent
    /// Answers after `delay`, by which time the caller may have gone.
    case late(String, delay: Duration)
  }

  /// What comes before `hello`'s reply: a login file's output.
  var banner = Data()
  /// The reply line, without its newline. `nil` means the stream says nothing to `hello`.
  var helloReply: String? = FakeCoreStream.helloReply()
  /// Written straight after the reply's newline, in the same write.
  var afterHello = Data()
  /// How many bytes each chunk holds. `nil` delivers each write whole.
  var chunkSize: Int?
  /// When true, the program exits straight after whatever it said to `hello`.
  var exitsAfterHello = false
  /// When true, a call's answer waits for `flushHeld()`, so two answers can land in one chunk.
  var holdsReplies = false
  var replies: [String: Reply] = [
    "terminal.list": .result(#"{"terminals":[]}"#),
    "doc.get": .result(FakeCoreStream.noDocument),
  ]

  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  private let lock = NSLock()
  private var sawHello = false
  private var decoder = CoreFrameDecoder()
  private var calledMethods: [String] = []
  private var closeCount = 0
  private var held = Data()
  private var lateReplies = 0

  init() {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    output = stream
    self.continuation = continuation
  }

  var end: ProcessEnd? { get async { nil } }

  var methods: [String] { lock.withLock { calledMethods } }
  var closes: Int { lock.withLock { closeCount } }
  /// How many `.late` replies have been written.
  var lateRepliesWritten: Int { lock.withLock { lateReplies } }

  func send(_ data: Data) async throws {
    let isHello = lock.withLock {
      defer { sawHello = true }
      return !sawHello
    }
    if isHello {
      answerHello()
      return
    }

    let frames = try lock.withLock { try decoder.append(data) }
    for frame in frames where frame.channel == 0 && frame.kind == .data {
      let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
      let id = try required(object?["id"] as? Int)
      let method = try required(object?["method"] as? String)
      lock.withLock { calledMethods.append(method) }
      answer(id: id, reply: replies[method] ?? .error("no such method"))
    }
  }

  func close() async {
    lock.withLock { closeCount += 1 }
    continuation.finish()
  }

  /// Writes bytes as the core would.
  func write(_ bytes: Data) {
    guard let chunkSize else {
      continuation.yield(bytes)
      return
    }
    var offset = bytes.startIndex
    while offset < bytes.endIndex {
      let end = min(offset + chunkSize, bytes.endIndex)
      continuation.yield(Data(bytes[offset..<end]))
      offset = end
    }
  }

  func writeMessage(_ json: String, onChannel channel: UInt32 = 0) {
    write(CoreFrame(channel: channel, kind: .data, payload: Data(json.utf8)).encoded)
  }

  /// The program exits.
  func finish() { continuation.finish() }

  func flushHeld() {
    let bytes = lock.withLock {
      defer { held = Data() }
      return held
    }
    write(bytes)
  }

  private func answerHello() {
    var opening = banner
    if let helloReply { opening.append(Data((helloReply + "\n").utf8)) }
    opening.append(afterHello)
    if !opening.isEmpty { write(opening) }
    if exitsAfterHello { finish() }
  }

  private func answer(id: Int, reply: Reply) {
    switch reply {
    case .result(let json):
      respond(#"{"id":\#(id),"jsonrpc":"2.0","result":\#(json)}"#)
    case .error(let message):
      respond(#"{"id":\#(id),"jsonrpc":"2.0","error":{"code":-32000,"message":"\#(message)"}}"#)
    case .silent:
      break
    case .late(let json, let delay):
      Task {
        try? await Task.sleep(for: delay)
        self.writeMessage(#"{"id":\#(id),"jsonrpc":"2.0","result":\#(json)}"#)
        self.lock.withLock { self.lateReplies += 1 }
      }
    }
  }

  private func respond(_ json: String) {
    guard holdsReplies else {
      writeMessage(json)
      return
    }
    let frame = CoreFrame(channel: 0, kind: .data, payload: Data(json.utf8)).encoded
    lock.withLock { held.append(frame) }
  }

  /// What `doc.get` answers for a document nobody has written.
  static let noDocument = #"{"value":null,"version":0}"#

  /// `hello`'s reply as a real core 0.1.14 wrote it, `id` first, and with its options.
  static func helloReply(
    generation: Int = 1,
    methods: [String] = ["hello", "terminal.list", "terminal.get"],
    framed: Bool = true,
    version: String = "0.1.14"
  ) -> String {
    let list = methods.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":1,"jsonrpc":"2.0","result":{"core":{"id":"f47b","name":"mac"},"#
      + #""features":["framed"],"framed":\#(framed),"generation":\#(generation),"#
      + #""methods":[\#(list)],"version":"\#(version)"}}"#
  }
}

struct FakeCoreStreamFailure: Error {}

struct WaitTimedOut: Error, CustomStringConvertible {
  let what: String
  var description: String { "Never saw: \(what)" }
}

/// Waits for `condition`, which must stay true once it holds, and fails if it never does.
///
/// **Throws at its deadline rather than returning**, so the test stops there and does not go
/// on to assert against whatever state it reached. `Task.sleep` throws on cancellation, so
/// `.timeLimit` can stop it too.
func waitUntil(
  _ what: String,
  within limit: Duration = .seconds(10),
  _ condition: () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + limit
  while !(await condition()) {
    guard clock.now < deadline else { throw WaitTimedOut(what: what) }
    try await Task.sleep(for: .milliseconds(1))
  }
}

/// `#require`, for a place the macro cannot reach: this runs off the test's own task.
private func required<Value>(_ value: Value?) throws -> Value {
  guard let value else { throw FakeCoreStreamFailure() }
  return value
}

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
    /// Writes these first, then answers, as a core can when its writer runs in between.
    case after(Data, then: String)
    /// Answers with these straight behind it, in the same write.
    case followedBy(String, Data)
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
    "events.subscribe": .result(FakeCoreStream.subscribed()),
    "doc.get": .result(FakeCoreStream.noDocument),
    "machine.list": .result(FakeCoreStream.noMachines),
  ]

  /// What `file.read` answers, by path. A path with no entry is a file that is not there.
  var files: [String: Reply] = [:]
  /// What `terminal.read` answers, by terminal, in place of `replies` once it has an entry. A
  /// terminal with no entry is one the core does not have.
  var screens: [String: Reply] = [:]

  let output: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  private let lock = NSLock()
  private var sawHello = false
  private var decoder = CoreFrameDecoder()
  private var calledMethods: [String] = []
  private var askedPaths: [String] = []
  private var closeCount = 0
  private var held = Data()
  private var lateReplies = 0
  private var received: [CoreFrame] = []
  private var requests: [Data] = []
  private var burst: Burst?
  private var lastSeq = 0

  /// One stream's output, held to its credit the way the core's outbox holds it.
  private struct Burst {
    let channel: UInt32
    var remaining: Int
    var credit: Int
    var written = 0
  }

  init() {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    output = stream
    self.continuation = continuation
  }

  var end: ProcessEnd? { get async { nil } }

  var methods: [String] { lock.withLock { calledMethods } }
  /// Every path `file.read` was asked for, in the order the calls landed.
  var readPaths: [String] { lock.withLock { askedPaths } }
  var closes: Int { lock.withLock { closeCount } }
  /// Every frame received on a stream channel, in order of arrival.
  var streamFrames: [CoreFrame] { lock.withLock { received } }
  /// How many bytes of the burst have been written.
  var burstWritten: Int { lock.withLock { burst?.written ?? 0 } }
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
    for frame in frames {
      guard frame.channel == 0, frame.kind == .data else {
        record(frame)
        continue
      }
      let object = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
      let id = try required(object?["id"] as? Int)
      let method = try required(object?["method"] as? String)
      lock.withLock {
        calledMethods.append(method)
        requests.append(frame.payload)
      }
      if method == "file.read" {
        let params = object?["params"] as? [String: Any]
        let path = try required(params?["path"] as? String)
        lock.withLock { askedPaths.append(path) }
        answer(id: id, reply: files[path] ?? .error("no file \(path)"))
      } else if method == "terminal.read", !screens.isEmpty {
        let params = object?["params"] as? [String: Any]
        let terminal = try required(params?["terminal"] as? String)
        answer(id: id, reply: screens[terminal] ?? .error("no terminal \(terminal)"))
      } else {
        answer(id: id, reply: replies[method] ?? .error("no such method"))
      }
    }
  }

  /// The `params` of each call to `method`, in order.
  func params(of method: String) throws -> [[String: Any]] {
    try lock.withLock { requests }.compactMap { request in
      let object = try JSONSerialization.jsonObject(with: request) as? [String: Any]
      guard object?["method"] as? String == method else { return nil }
      return object?["params"] as? [String: Any]
    }
  }

  /// Starts a stream's output: `total` bytes in 16 KiB chunks, with the core's 256 KiB of
  /// starting credit, going on only as CREDIT arrives.
  func startBurst(_ total: Int, onChannel channel: UInt32) {
    lock.withLock { burst = Burst(channel: channel, remaining: total, credit: 256 * 1024) }
    pumpBurst()
  }

  private func record(_ frame: CoreFrame) {
    lock.withLock {
      received.append(frame)
      if frame.kind == .credit, frame.channel == burst?.channel {
        let bytes = frame.payload.reversed().reduce(0) { $0 << 8 | Int($1) }
        burst?.credit += bytes
      }
    }
    if frame.kind == .credit { pumpBurst() }
  }

  private func pumpBurst() {
    while let (channel, size) = nextBurstChunk() {
      write(CoreFrame(channel: channel, kind: .data, payload: Data(count: size)).encoded)
    }
  }

  private func nextBurstChunk() -> (UInt32, Int)? {
    lock.withLock {
      guard var active = burst else { return nil }
      let size = min(16 * 1024, active.remaining, active.credit)
      guard size > 0 else { return nil }
      active.remaining -= size
      active.credit -= size
      active.written += size
      burst = active
      return (active.channel, size)
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

  /// One line on a subscription, as one DATA frame.
  func emit(_ line: String, onChannel channel: UInt32 = FakeCoreStream.eventChannel) {
    writeMessage(line + "\n", onChannel: channel)
  }

  /// One event, numbered after the last. `seq` puts it elsewhere.
  func event(
    _ type: String,
    on terminal: String? = nil,
    _ data: String = "{}",
    machine: String? = nil,
    seq: Int? = nil
  ) {
    let seq = lock.withLock {
      lastSeq = seq ?? lastSeq + 1
      return lastSeq
    }
    let address = terminal.map { #""terminal":"\#($0)","# } ?? ""
    let machine = machine.map { #""machine":"\#($0)","# } ?? ""
    emit(
      #"{"jsonrpc":"2.0","method":"event","params":{\#(address)\#(machine)"#
        + #""data":\#(data),"seq":\#(seq),"type":"\#(type)"}}"#)
  }

  /// How many bytes of credit have come back on `channel`.
  func creditReturned(onChannel channel: UInt32 = FakeCoreStream.eventChannel) -> Int {
    streamFrames.filter { $0.channel == channel && $0.kind == .credit }
      .reduce(0) { $0 + $1.payload.reversed().reduce(0) { $0 << 8 | Int($1) } }
  }

  /// How many times `method` was called.
  func calls(of method: String) -> Int {
    methods.filter { $0 == method }.count
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
    case .after(let frames, let json):
      write(frames)
      respond(#"{"id":\#(id),"jsonrpc":"2.0","result":\#(json)}"#)
    case .followedBy(let json, let frames):
      let reply = #"{"id":\#(id),"jsonrpc":"2.0","result":\#(json)}"#
      write(CoreFrame(channel: 0, kind: .data, payload: Data(reply.utf8)).encoded + frames)
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

  /// What `terminal.attach` answers: a channel and the terminal's record, cut down.
  static func attached(
    channel: UInt32 = 1,
    submit: String? = nil,
    pasteGap: Int? = nil
  ) -> String {
    let key = submit.map { "\"\($0)\"" } ?? "null"
    let gap = pasteGap.map(String.init) ?? "null"
    return #"{"channel":\#(channel),"terminal":{"address":"t7","submit":\#(key),"#
      + #""paste_gap_ms":\#(gap)}}"#
  }

  /// What `terminal.read` answers, as a real core 0.1.15 wrote it. `text` is JSON already, so a
  /// test can spell an escape.
  static func screenRead(_ text: String) -> String {
    #"{"complete":true,"how":"screen","text":"\#(text)"}"#
  }

  /// Where `subscribed` says events arrive.
  static let eventChannel: UInt32 = 9

  /// What `events.subscribe` answers.
  static func subscribed(_ terminals: [String] = [], seq: Int = 0) -> String {
    let list = terminals.joined(separator: ",")
    return #"{"channel":\#(eventChannel),"seq":\#(seq),"terminals":[\#(list)]}"#
  }

  /// What `doc.get` answers for a document nobody has written.
  static let noDocument = #"{"value":null,"version":0}"#

  /// What `machine.list` answers on a core that has added nothing.
  static let noMachines = #"{"machines":[]}"#

  /// `machine.list` as a real core 0.1.15 wrote it, cut down to one machine.
  static func machines(_ name: String, id: String) -> String {
    #"{"machines":[{"host":"nas","id":"\#(id)","name":"\#(name)","session":null,"#
      + #""state":"connected","target":"root@box","temporary":false,"version":"0.1.15","#
      + #""via":false}]}"#
  }

  /// `hello`'s reply as a real core 0.1.14 wrote it, `id` first, and with its options.
  static func helloReply(
    generation: Int = 1,
    methods: [String] = ["hello", "events.subscribe", "terminal.list", "terminal.get"],
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

/// Reads `control` until its tree is the one wanted, and fails if it never is.
@discardableResult
func tree(
  of control: CoreControl,
  where wanted: (SessionTree) -> Bool
) async throws -> SessionTree {
  var latest = SessionTree.empty
  try await waitUntil("the tree") {
    guard let tree = try? await control.snapshot() else { return false }
    latest = tree
    return wanted(tree)
  }
  return latest
}

/// `#require`, for a place the macro cannot reach: this runs off the test's own task.
private func required<Value>(_ value: Value?) throws -> Value {
  guard let value else { throw FakeCoreStreamFailure() }
  return value
}

import DriverrHerdr
import Foundation

/// How the opening of an `hc connect` went.
enum CoreHandshake: Equatable, Sendable {
  /// A core this build can use, now in framed mode.
  case ready(version: String)
  /// A core, and one this build cannot use. See `HerdrAvailability.coreIncompatible`.
  case refused(version: String?, generation: Int?, missingMethods: [String])
  /// Nothing that answered like a core. Another program called `hc` exists, so the end of
  /// the stream is an answer and not a failure.
  case notCore
}

enum CoreHello {
  /// Always the first message, so always this id.
  static let requestID = 1

  /// What this build calls, as `hello.methods` must list it. Compatibility is the generation
  /// plus this list, not a protocol number.
  static let requiredMethods = ["events.subscribe"]

  /// The opening request. One line of plain JSON-RPC, because a connection starts in plain
  /// mode and the reply switches it.
  static var request: Data {
    let request = CoreRequest(
      id: requestID,
      method: "hello",
      params: CoreHelloParams(framed: true, generation: HerdrProtocol.coreGeneration)
    )
    // An encoder cannot fail on these fields.
    return ((try? JSONEncoder().encode(request)) ?? Data()) + Data("\n".utf8)
  }

  /// Judges a reply the core made in words.
  static func verdict(on reply: CoreResponse<CoreHelloResult>) -> CoreHandshake {
    guard let result = reply.result else {
      // `unsupported_generation`, or a core that refused the opening for another reason.
      return .refused(version: nil, generation: nil, missingMethods: [])
    }
    guard result.generation == HerdrProtocol.coreGeneration else {
      return .refused(
        version: result.version, generation: result.generation, missingMethods: [])
    }
    let methods = result.methods ?? []
    let missing = requiredMethods.filter { !methods.contains($0) }
    guard missing.isEmpty else {
      return .refused(
        version: result.version, generation: result.generation, missingMethods: missing)
    }
    // Asked for framed and told plain: the bytes that follow are not frames.
    guard result.framed == true, let version = result.version else {
      return .refused(version: result.version, generation: nil, missingMethods: [])
    }
    return .ready(version: version)
  }
}

/// Finds the reply to `hello` in what the exec channel delivers first.
///
/// **A shell's login files run before `hc`, and whatever they print comes first**, so the
/// reply is not necessarily at the start of the stream, or even at the start of its line.
struct CoreHelloScanner {
  enum Step: Equatable {
    case needsMore
    case reply(CoreHandshake, remainder: Data)
    /// More noise than any login file prints. Without a bound, a program that writes forever
    /// would hold this buffer open for as long as it ran.
    case notCore
  }

  static let limit = 64 * 1024

  private var buffer = Data()
  private var lineStart = 0

  /// Takes the next chunk. `remainder` is whatever followed the reply's newline, which is
  /// already framed and belongs to `CoreFrameDecoder`.
  mutating func append(_ chunk: Data) -> Step {
    buffer.append(chunk)

    while let newline = buffer[(buffer.startIndex + lineStart)...].firstIndex(of: 0x0A) {
      let line = buffer[(buffer.startIndex + lineStart)..<newline]
      if let reply = Self.reply(in: line) {
        return .reply(
          CoreHello.verdict(on: reply),
          remainder: Data(buffer[(newline + 1)...])
        )
      }
      lineStart = newline + 1 - buffer.startIndex
    }

    return buffer.count > Self.limit ? .notCore : .needsMore
  }

  /// Tries every `{` on the line, so `welcome {"id":1,…}` still answers and `{ motd }` is
  /// not a dead end. Parsed, never prefix-matched: the reply's id is not a fixed offset, and
  /// `{"id":1` is also the start of a `{"id":12,…`.
  private static func reply(in line: Data) -> CoreResponse<CoreHelloResult>? {
    let decoder = JSONDecoder()
    var index = line.startIndex
    while let brace = line[index...].firstIndex(of: 0x7B) {
      if let reply = try? decoder.decode(
        CoreResponse<CoreHelloResult>.self, from: Data(line[brace...])
      ), reply.id == CoreHello.requestID, reply.result != nil || reply.error != nil {
        return reply
      }
      index = brace + 1
    }
    return nil
  }
}

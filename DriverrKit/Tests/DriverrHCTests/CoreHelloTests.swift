import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

@Suite("Core hello")
struct CoreHelloTests {
  private let ready = CoreHandshake.ready(version: "0.1.14")

  private func scan(_ text: String) -> CoreHelloScanner.Step {
    var scanner = CoreHelloScanner()
    return scanner.append(Data(text.utf8))
  }

  @Test("the opening asks for framed mode at this build's generation, on one line")
  func request() throws {
    let line = CoreHello.request
    #expect(line.last == 0x0A)
    #expect(line.filter { $0 == 0x0A }.count == 1)
    let object = try #require(
      try JSONSerialization.jsonObject(with: line) as? [String: Any])
    #expect(object["jsonrpc"] as? String == "2.0")
    #expect(object["id"] as? Int == 1)
    #expect(object["method"] as? String == "hello")
    let params = try #require(object["params"] as? [String: Any])
    #expect(params["framed"] as? Bool == true)
    #expect(params["generation"] as? Int == 1)
  }

  @Test("a reply at the start of the stream")
  func plainReply() {
    #expect(scan(FakeCoreStream.helloReply() + "\n") == .reply(ready, remainder: Data()))
  }

  @Test("login noise on earlier lines is skipped")
  func bannerLines() {
    let text = "Welcome to box\n\nLast login: today\n" + FakeCoreStream.helloReply() + "\n"
    #expect(scan(text) == .reply(ready, remainder: Data()))
  }

  @Test("noise before the reply on its own line, including another brace")
  func noiseOnTheSameLine() {
    let text = "motd { today } " + FakeCoreStream.helloReply() + "\n"
    #expect(scan(text) == .reply(ready, remainder: Data()))
  }

  @Test("JSON that is not the reply is noise, whatever it starts with")
  func lookalikes() {
    let text =
      #"{"id":12,"result":{"generation":1}}"# + "\n"
      + #"{"id":1}"# + "\n"
      + #"{"id":1,"version":"not a reply"}"# + "\n"
      + FakeCoreStream.helloReply() + "\n"
    #expect(scan(text) == .reply(ready, remainder: Data()))
  }

  @Test("the reply split at every byte")
  func splitReply() {
    var scanner = CoreHelloScanner()
    let bytes = Data(("banner\n" + FakeCoreStream.helloReply() + "\n").utf8)
    var final: CoreHelloScanner.Step = .needsMore
    for (index, byte) in bytes.enumerated() {
      final = scanner.append(Data([byte]))
      if index < bytes.count - 1 { #expect(final == .needsMore) }
    }
    #expect(final == .reply(ready, remainder: Data()))
  }

  @Test("bytes after the reply's newline are handed on untouched")
  func remainder() {
    let frame = CoreFrame(channel: 0, kind: .data, payload: Data("{}".utf8)).encoded
    var scanner = CoreHelloScanner()
    let step = scanner.append(Data((FakeCoreStream.helloReply() + "\n").utf8) + frame)
    #expect(step == .reply(ready, remainder: frame))
  }

  @Test("noise up to the bound keeps waiting, and past it is not a core")
  func noiseBound() {
    var scanner = CoreHelloScanner()
    #expect(scanner.append(Data(repeating: 0x2E, count: CoreHelloScanner.limit)) == .needsMore)
    #expect(scanner.append(Data([0x2E])) == .notCore)
  }

  @Test("a later generation is refused by name")
  func laterGeneration() {
    let text = FakeCoreStream.helloReply(generation: 2) + "\n"
    #expect(
      scan(text)
        == .reply(
          .refused(version: "0.1.14", generation: 2, missingMethods: []), remainder: Data()
        )
    )
  }

  @Test("a later generation that dropped the other fields still decodes far enough")
  func laterGenerationShape() {
    let text = #"{"id":1,"result":{"generation":2}}"# + "\n"
    #expect(
      scan(text)
        == .reply(.refused(version: nil, generation: 2, missingMethods: []), remainder: Data())
    )
  }

  @Test("a method this build calls and the core does not list")
  func missingMethod() {
    let text = FakeCoreStream.helloReply(methods: ["hello"]) + "\n"
    #expect(
      scan(text)
        == .reply(
          .refused(version: "0.1.14", generation: 1, missingMethods: ["events.subscribe"]),
          remainder: Data()
        )
    )
  }

  @Test("a refusal in words is a refusal, not silence")
  func errorReply() {
    let text =
      #"{"id":1,"error":{"code":-32000,"message":"unsupported_generation","#
      + #""data":{"kind":"unsupported_generation"}}}"# + "\n"
    #expect(
      scan(text)
        == .reply(.refused(version: nil, generation: nil, missingMethods: []), remainder: Data())
    )
  }

  @Test("asked for framed and told plain is refused, because no frames will follow")
  func plainModeReply() {
    let text = FakeCoreStream.helloReply(framed: false) + "\n"
    #expect(
      scan(text)
        == .reply(
          .refused(version: "0.1.14", generation: nil, missingMethods: []), remainder: Data()
        )
    )
  }
}

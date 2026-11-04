import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrHC

/// A photo for a pane on a machine the core added goes beside that pane, over `terminal.put`,
/// and the path typed into the pane is the one the machine answers (#68).
@Suite("Core image put", .timeLimit(.minutes(1)))
struct CorePutTests {
  private let pane = "core:box/t7"
  private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x2A])
  /// Where a core 0.1.17 on `box` stages a put, as the machine sees it.
  private let landed = "/home/carson/.local/state/hc/files/t7/8f1c.png"

  private func control(_ stream: FakeCoreStream) -> CoreControl {
    CoreControl(binaryPath: "hc", callDeadline: .seconds(30), open: { _ in stream })
  }

  private func answering(_ reply: FakeCoreStream.Reply) -> FakeCoreStream {
    let stream = FakeCoreStream()
    stream.replies["terminal.put"] = reply
    return stream
  }

  private func upload(_ stream: FakeCoreStream, bytes: Data? = nil) throws -> any ImageUploading
  {
    try #require(
      control(stream).imageUploader(forPane: pane, bytes: bytes ?? png, fileName: "8f1c.png"))
  }

  private static func put(path: String, bytes: Int) -> String {
    #"{"bytes":\#(bytes),"path":"\#(path)"}"#
  }

  /// What an upload threw, as a value, so a test can compare it.
  private func failure(of upload: any ImageUploading) async -> (any Error)? {
    do {
      _ = try await upload.upload()
      return nil
    } catch {
      return error
    }
  }

  @Test("the bytes go to the pane's terminal on its machine, base64, under their own name")
  func requestShape() async throws {
    let stream = answering(.result(Self.put(path: landed, bytes: png.count)))
    _ = try await upload(stream).upload()

    let calls = try stream.params(of: "terminal.put")
    #expect(calls.count == 1)
    let params = try #require(calls.first)
    #expect(params["terminal"] as? String == "box/t7")
    #expect(params["name"] as? String == "8f1c.png")
    #expect(params["data"] as? String == png.base64EncodedString())
    #expect(params.count == 3)
    // Nothing is typed: `terminal.put` writes the file and the composer pastes the path.
    #expect(stream.calls(of: "terminal.attach") == 0)
  }

  @Test("the machine's answered path is the outcome, and the whole count is reported once")
  func pathIsTheOutcome() async throws {
    let stream = answering(.result(Self.put(path: landed, bytes: png.count)))
    let upload = try upload(stream)
    let outcome = try await upload.upload()
    #expect(outcome == ImageUploadOutcome(hostPath: landed, bytesSent: png.count))

    var reported: [ImageUploadProgress] = []
    for await progress in upload.progress { reported.append(progress) }
    #expect(reported == [ImageUploadProgress(bytesSent: png.count, totalBytes: png.count)])
  }

  @Test("an answer with no path is the no-path failure")
  func emptyPath() async throws {
    let stream = answering(.result(Self.put(path: "", bytes: png.count)))
    #expect(await failure(of: try upload(stream)) as? ImageUploadFailure == .noHostPath)
  }

  @Test(
    "a pane or machine the core no longer has is said in the core's words",
    arguments: [
      ("not_found", "no terminal box/t7"),
      ("finished", "t7 has finished"),
      ("machine_unknown", "no machine called box"),
    ])
  func refusedInTheCoresWords(kind: String, message: String) async throws {
    let stream = answering(.refused(kind: kind, message: message))
    let failure = await failure(of: try upload(stream))
    #expect(failure as? AppError == .herdrCommandFailed(reason: message))
  }

  @Test("a core that has no terminal.put refuses the image, by code or by kind")
  func methodNotFound() async throws {
    let byCode = answering(
      .refused(kind: "something", message: "unknown method", code: -32601))
    #expect(await failure(of: try upload(byCode)) as? MachineImageRefusal == .unsupported)

    let byKind = answering(.refused(kind: "unknown_method", message: "unknown method"))
    #expect(await failure(of: try upload(byKind)) as? MachineImageRefusal == .unsupported)
  }

  @Test("a file the machine could not write is the save failure")
  func internalWriteFailure() async throws {
    let stream = answering(
      .refused(kind: "internal", message: "cannot write the file: No space left on device"))
    let failure = await failure(of: try upload(stream)) as? ImageUploadFailure
    guard case .commandFailed? = failure else {
      Issue.record("expected commandFailed, got \(String(describing: failure))")
      return
    }
  }

  @Test("a link that ends before the answer is a stall, not a refusal")
  func noAnswerIsAStall() async throws {
    let stream = answering(.silent)
    let upload = try upload(stream)
    async let ended = failure(of: upload)
    try await waitUntil("the put is on the wire") { stream.calls(of: "terminal.put") == 1 }
    stream.finish()
    #expect(await ended as? ImageUploadFailure == .stalled)
  }

  @Test("more than the core takes is refused before anything is sent")
  func sizeCap() async throws {
    let stream = answering(.result(Self.put(path: landed, bytes: 0)))
    let limit = CoreControl.putByteLimit
    #expect(limit == 8 * 1024 * 1024)

    let over = Data(count: limit + 1)
    #expect(
      await failure(of: try upload(stream, bytes: over)) as? MachineImageRefusal
        == .tooLarge(limit: limit))
    #expect(stream.calls(of: "terminal.put") == 0)
  }

  @Test("exactly the limit is sent")
  func atTheCap() async throws {
    let limit = CoreControl.putByteLimit
    let stream = answering(.result(Self.put(path: landed, bytes: limit)))
    let outcome = try await upload(stream, bytes: Data(count: limit)).upload()
    #expect(outcome.bytesSent == limit)
  }

  @Test("the deadline grows with the payload, from the exec call's")
  func deadline() {
    #expect(CoreControl.putCallDeadline(forBytes: 0) == CoreControl.execCallDeadline)
    #expect(CoreControl.putCallDeadline(forBytes: 1) == CoreControl.execCallDeadline + .seconds(10))
    #expect(
      CoreControl.putCallDeadline(forBytes: CoreControl.putByteLimit)
        == CoreControl.execCallDeadline + .seconds(80))
  }

  @Test(
    "a pane on the core's own computer, or not the core's at all, has no uploader",
    arguments: ["core:t3", "w1:p2", "core:/t7", "box/t7"])
  func noUploader(id: String) {
    #expect(control(FakeCoreStream()).imageUploader(forPane: id, bytes: png, fileName: "a.png") == nil)
  }

  @Test("a combined host asks the core for a machine pane and the TUI for its own")
  func combinedRoutes() {
    let combined = CombinedControl(tui: FakeControl(), core: control(FakeCoreStream()))
    #expect(combined.imageUploader(forPane: pane, bytes: png, fileName: "a.png") != nil)
    #expect(combined.imageUploader(forPane: "w1:p2", bytes: png, fileName: "a.png") == nil)
    #expect(combined.imageUploader(forPane: "core:t3", bytes: png, fileName: "a.png") == nil)
  }
}

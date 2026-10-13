import DriverrCore
import Foundation
import SwiftTerm
import Testing

@testable import DriverrTerm

/// The far side, the session and a headless emulator, wired as `DriverrTerminalView` wires
/// them: `TerminalSession`'s sink is the only way bytes reach SwiftTerm.
@MainActor
private final class Rig {
  /// What the emulator answered. In the app `Coordinator.send` forwards this to the host.
  final class Replies: TerminalDelegate {
    private(set) var bytes: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
  }

  /// `Terminal` holds its delegate weakly, so the rig keeps it alive.
  let replies = Replies()
  let terminal: Terminal
  private let session: TerminalSession
  private let output: AsyncThrowingStream<Data, any Error>.Continuation
  private let fed: AsyncStream<Void>
  private var sunk: [UInt8] = []

  init() {
    let (stream, output) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    self.output = output
    let terminal = Terminal(delegate: replies, options: TerminalOptions(cols: 80, rows: 24))
    self.terminal = terminal
    session = TerminalSession(
      feed: TerminalFeed(output: stream, send: { _ in }, resize: { _ in }, close: {})
    )
    let (fed, wake) = AsyncStream<Void>.makeStream()
    self.fed = fed
    session.attach { [weak self] bytes in
      terminal.feed(buffer: bytes)
      self?.sunk.append(contentsOf: bytes)
      wake.yield()
    }
    session.start()
  }

  /// Sends `bytes` as the host would and returns what the emulator answered.
  ///
  /// A marker follows in its own chunk, so the wait ends even if the fix lets none of
  /// `bytes` through to the emulator.
  func host(sends bytes: [UInt8]) async -> String {
    let marker = Array("kitty-probe-done".utf8)
    output.yield(Data(bytes))
    output.yield(Data(marker))
    for await _ in fed where sunk.suffix(marker.count).elementsEqual(marker) { break }
    return replies.text
  }
}

/// A kitty graphics transmit of one RGBA pixel, `a=t,f=32,s=1,v=1,i=1`.
///
/// - Parameters:
///   - medium: the protocol's `t=` key. `d` carries the pixel, and `f`, `t` and `s`
///     carry a path or a name **on the terminal's machine**.
///   - terminator: `ESC \` unless given. SwiftTerm also ends an APC string at BEL.
private func transmit(
  medium: Character,
  payload: Data,
  terminator: [UInt8] = [0x1b, 0x5c]
) -> [UInt8] {
  let body = Array("Ga=t,t=\(medium),f=32,s=1,v=1,i=1;\(payload.base64EncodedString())".utf8)
  return [0x1b, 0x5f] + body + terminator
}

/// What the emulator answers to a medium it does not read, for image `i=1`.
///
/// The tests compare the whole reply. An emulator that answers nothing also "does not say
/// `OK`", so the absence of `OK` proves nothing.
private let refusal = "\u{1b}_Gi=1;EINVAL: unsupported medium\u{1b}\\"

/// A directory of this test's own, under the temporary directory `t=t` is allowed to delete
/// from.
private func scratchDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("driverr-kitty-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A host is not trusted with this device's files. The kitty graphics protocol lets a
/// program name a file, a temporary file or a shared memory object for the terminal to
/// read, which is meant for a terminal on the same machine as the program. Driverr's
/// program is on the far side of an SSH connection.
@MainActor
@Suite("Kitty graphics: a host cannot name local files", .timeLimit(.minutes(1)))
struct KittyGraphicsLocalMediaTests {
  @Test("t=f does not read a file on this device")
  func fileMediumIsRefused() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("four-bytes")
    try Data([1, 2, 3, 4]).write(to: file)

    let rig = Rig()
    let reply = await rig.host(sends: transmit(medium: "f", payload: Data(file.path.utf8)))

    // `OK` would mean the four bytes were read and stored as a pixel.
    #expect(reply == refusal, "for \(file.path) the emulator answered \(reply.debugDescription)")
  }

  @Test("t=f answers the same for a path that exists and one that does not")
  func fileMediumDoesNotRevealWhetherAPathExists() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Three bytes, so it is not a 1x1 RGBA pixel and the read cannot succeed.
    let present = directory.appendingPathComponent("present")
    try Data([1, 2, 3]).write(to: present)
    let absent = directory.appendingPathComponent("absent")

    let forPresent = await Rig().host(sends: transmit(medium: "f", payload: Data(present.path.utf8)))
    let forAbsent = await Rig().host(sends: transmit(medium: "f", payload: Data(absent.path.utf8)))

    #expect(forPresent == refusal, "present: \(forPresent.debugDescription)")
    #expect(forAbsent == refusal, "absent: \(forAbsent.debugDescription)")
  }

  @Test("t=t does not delete a file on this device")
  func temporaryFileMediumDoesNotDelete() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // SwiftTerm deletes only under a temporary directory and only a path that contains
    // this string.
    let file = directory.appendingPathComponent("tty-graphics-protocol-four-bytes")
    try Data([1, 2, 3, 4]).write(to: file)

    let rig = Rig()
    let reply = await rig.host(sends: transmit(medium: "t", payload: Data(file.path.utf8)))

    #expect(FileManager.default.fileExists(atPath: file.path), "deleted, and answered \(reply.debugDescription)")
    #expect(reply == refusal, "\(reply.debugDescription)")
  }

  @Test("a BEL-terminated sequence does not get t=f past the same rule")
  func belTerminatedSequenceIsRefusedToo() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("four-bytes")
    try Data([1, 2, 3, 4]).write(to: file)

    let rig = Rig()
    let reply = await rig.host(
      sends: transmit(medium: "f", payload: Data(file.path.utf8), terminator: [0x07])
    )

    #expect(reply == refusal, "\(reply.debugDescription)")
  }

  @Test("t=s does not look for a shared memory object on this device")
  func sharedMemoryMediumIsRefused() async {
    // No object has this name. An emulator that looks for it answers `bad payload`, so
    // the refusal shows it did not look.
    let name = "/driverr-kitty-\(UUID().uuidString)"

    let rig = Rig()
    let reply = await rig.host(sends: transmit(medium: "s", payload: Data(name.utf8)))

    #expect(reply == refusal, "\(reply.debugDescription)")
  }

  @Test("t=d, pixels sent in the sequence itself, still works")
  func directMediumIsUntouched() async {
    let rig = Rig()
    let reply = await rig.host(sends: transmit(medium: "d", payload: Data([1, 2, 3, 4])))

    #expect(reply == "\u{1b}_Gi=1;OK\u{1b}\\", "\(reply.debugDescription)")
  }
}

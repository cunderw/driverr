import Foundation
import Testing

@testable import DriverrCore

/// A picked file's remote name, and the read that brackets it with security-scoped access.
@Suite struct AttachmentFileNameTests {
  private let unique = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000000")!

  @Test func theNameIsTheTokenThenTheSanitisedOriginal() {
    #expect(AttachmentFileName.remote(original: "notes.txt", unique: unique) == "a1b2c3d4-notes.txt")
  }

  @Test func aPathCannotClimbOutOfTheInbox() {
    let name = AttachmentFileName.remote(original: "../x", unique: unique)
    #expect(name == "a1b2c3d4-x")
    #expect(!name.contains("/"))
    #expect(AttachmentFileName.sanitised("../../etc/passwd") == "passwd")
    #expect(AttachmentFileName.sanitised("a\\b.txt") == "b.txt")
  }

  @Test func aLeadingDotOrDashIsDropped() {
    #expect(AttachmentFileName.sanitised(".env") == "env")
    #expect(AttachmentFileName.sanitised("--rf.txt") == "rf.txt")
    #expect(AttachmentFileName.sanitised("..") == AttachmentFileName.fallback)
    #expect(AttachmentFileName.sanitised("-.txt") == "file.txt")
  }

  @Test func aRunOfSpacesIsOneDash() {
    #expect(AttachmentFileName.sanitised("build log.txt") == "build-log.txt")
    #expect(AttachmentFileName.sanitised("a   b\t(c).log") == "a-b-c-.log")
  }

  @Test func unicodeBecomesOneDashPerRun() {
    #expect(AttachmentFileName.sanitised("résumé.pdf") == "r-sum-.pdf")
    // A stem with nothing left keeps its extension.
    #expect(AttachmentFileName.sanitised("日本語.txt") == "file.txt")
    #expect(AttachmentFileName.sanitised("👍🏽 ok.md") == "ok.md")
  }

  @Test func nothingLeftIsTheFallback() {
    #expect(AttachmentFileName.sanitised("") == "file")
    #expect(AttachmentFileName.sanitised("///") == "file")
    #expect(AttachmentFileName.sanitised("日本") == "file")
    #expect(AttachmentFileName.remote(original: "", unique: unique) == "a1b2c3d4-file")
  }

  @Test func aLongNameIsCutAndKeepsItsExtension() {
    let long = String(repeating: "a", count: 300) + ".log"
    let name = AttachmentFileName.sanitised(long)
    #expect(name.utf8.count == AttachmentFileName.maximumBytes)
    #expect(name.hasSuffix(".log"))
    let remote = AttachmentFileName.remote(original: long, unique: unique)
    #expect(remote.hasPrefix("a1b2c3d4-"))
    #expect(remote.utf8.count == 9 + AttachmentFileName.maximumBytes)
  }

  @Test func aLongNameWithNoExtensionIsCut() {
    let name = AttachmentFileName.sanitised(String(repeating: "b", count: 300))
    #expect(name == String(repeating: "b", count: AttachmentFileName.maximumBytes))
  }

  @Test func theSanitisedNameUsesOnlyTheSafeSet() {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    let name = AttachmentFileName.remote(original: "$(rm -rf ~); `x` 'y' \"z\".sh", unique: unique)
    #expect(name.allSatisfy { allowed.contains($0) })
    #expect(name.hasSuffix(".sh"))
  }

  @Test func theMachineLimitIsTheCoresPutLimit() {
    #expect(AttachmentLimit.machine == 8 << 20)
    #expect(AttachmentLimit.limit(for: .machine("studio")) == AttachmentLimit.machine)
    #expect(AttachmentLimit.limit(for: .host) == AttachmentLimit.host)
  }
}

@Suite struct PickedFileReaderTests {
  /// Counts the calls the reader makes, so a test can say what happened and how often.
  private final class Calls {
    var starts = 0
    var stops = 0
    var reads = 0
  }

  private struct ReadFailed: Error {}

  private let url = URL(fileURLWithPath: "/picked/report.pdf")

  private func read(
    _ calls: Calls,
    started: Bool = true,
    limit: Int = 100,
    attributes: PickedFileReader.Attributes = .init(byteCount: 10, isDirectory: false),
    contents: Result<Data, any Error> = .success(Data(repeating: 7, count: 10))
  ) -> PickedFileOutcome {
    PickedFileReader.read(
      url: url,
      limit: limit,
      start: { _ in
        calls.starts += 1
        return started
      },
      stop: { _ in calls.stops += 1 },
      read: { _ in
        calls.reads += 1
        return try contents.get()
      },
      size: { _ in attributes }
    )
  }

  @Test func aReadableFileIsReadInsideOneAccessWindow() {
    let calls = Calls()
    #expect(read(calls) == .contents(Data(repeating: 7, count: 10)))
    #expect(calls.starts == 1)
    #expect(calls.reads == 1)
    #expect(calls.stops == 1)
  }

  @Test func aThrowingReadStillStopsAccessOnce() {
    let calls = Calls()
    #expect(read(calls, contents: .failure(ReadFailed())) == .unreadable)
    #expect(calls.reads == 1)
    #expect(calls.stops == 1)
  }

  @Test func aFileOverTheLimitIsNeverReadAndStillStopsAccess() {
    let calls = Calls()
    let outcome = read(calls, limit: 5)
    #expect(outcome == .tooLarge(limit: 5))
    #expect(calls.reads == 0)
    #expect(calls.stops == 1)
  }

  @Test func aFolderIsUnreadableAndStillStopsAccess() {
    let calls = Calls()
    let outcome = read(calls, attributes: .init(byteCount: nil, isDirectory: true))
    #expect(outcome == .unreadable)
    #expect(calls.reads == 0)
    #expect(calls.stops == 1)
  }

  @Test func accessThatWasNotStartedIsNeverStopped() {
    let calls = Calls()
    #expect(read(calls, started: false) == .contents(Data(repeating: 7, count: 10)))
    #expect(read(calls, started: false, contents: .failure(ReadFailed())) == .unreadable)
    #expect(read(calls, started: false, limit: 5) == .tooLarge(limit: 5))
    #expect(calls.starts == 3)
    #expect(calls.stops == 0)
  }

  /// A size the file system did not report is checked against what was read.
  @Test func aFileWithNoReportedSizeIsCheckedAfterTheRead() {
    let calls = Calls()
    let outcome = read(calls, limit: 5, attributes: .init(byteCount: nil, isDirectory: false))
    #expect(outcome == .tooLarge(limit: 5))
    #expect(calls.stops == 1)
  }

  @Test func aRealFileReadsBackByteExact() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PickedFileReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("build log.txt")
    let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    try bytes.write(to: file)

    #expect(PickedFileReader.read(url: file, limit: 1 << 20) == .contents(bytes))
    #expect(PickedFileReader.read(url: file, limit: 100) == .tooLarge(limit: 100))
    #expect(PickedFileReader.read(url: directory, limit: 1 << 20) == .unreadable)
  }
}

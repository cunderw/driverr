import Foundation
import Testing

@testable import DriverrCore

/// The refusal's list and the picker behind it. Nothing is drawn behind the refusal, and
/// the picker is keyed on what somebody typed rather than on a uuid.
struct TranscriptOrderingTests {
  private func file(_ name: String, age: TimeInterval?, size: Int = 100) -> TranscriptFile {
    TranscriptFile(path: "/p/\(name)", sizeInBytes: size, age: age)
  }

  @Test("candidates are newest first, and a file with no age sorts last")
  func newestFirst() {
    let ordered = TranscriptFile.newestFirst([
      file("old.jsonl", age: 900),
      file("unknown.jsonl", age: nil),
      file("new.jsonl", age: 4),
      file("recent.jsonl", age: 40),
    ])
    #expect(ordered.map(\.name) == ["new.jsonl", "recent.jsonl", "old.jsonl", "unknown.jsonl"])
  }

  /// `sorted(by:)` is not documented as stable, and the list is re-derived on every poll.
  @Test("files that cannot be told apart keep the order the host listed them in")
  func stableTies() {
    let tied = (0..<8).map { file("same\($0).jsonl", age: 12) }
    #expect(TranscriptFile.newestFirst(tied).map(\.name) == tied.map(\.name))
    let unknown = (0..<8).map { file("none\($0).jsonl", age: nil) }
    #expect(TranscriptFile.newestFirst(unknown).map(\.name) == unknown.map(\.name))
  }
}

struct TranscriptPickerTests {
  private func file(_ name: String, age: TimeInterval?) -> TranscriptFile {
    TranscriptFile(path: "/home/me/.claude/projects/-home-me-dev-driverr/\(name)", sizeInBytes: 9, age: age)
  }

  private let directory = "/home/me/dev/driverr"

  @Test("the picker is keyed on what somebody typed, with the filename and age beneath it")
  func rows() {
    let picker = TranscriptPicker(
      directory: directory,
      candidates: [file("a.jsonl", age: 4), file("b.jsonl", age: 21)],
      briefs: [
        "a.jsonl": "review the diff on the focus branch",
        "b.jsonl": "start on the pane-focus bug",
      ]
    )
    #expect(picker.candidates.map(\.title) == [
      "review the diff on the focus branch", "start on the pane-focus bug",
    ])
    #expect(picker.candidates.map(\.detail) == [
      "a.jsonl · written 4s ago", "b.jsonl · written 21s ago",
    ])
  }

  /// A brief Driverr could not read degrades the row rather than blocking it.
  @Test("a candidate with no readable opening line still gets a row")
  func degradedRow() {
    let picker = TranscriptPicker(
      directory: directory,
      candidates: [file("a.jsonl", age: 4), file("b.jsonl", age: 21)],
      briefs: ["b.jsonl": "start on the pane-focus bug"]
    )
    #expect(picker.candidates[0].title == TranscriptCandidate.noOpeningLine)
    #expect(picker.candidates[0].detail == "a.jsonl · written 4s ago")
    #expect(picker.candidates.count == 2)
  }

  @Test("a file whose age the host could not read keeps its row and says nothing it cannot")
  func noAge() {
    let picker = TranscriptPicker(directory: directory, candidates: [file("a.jsonl", age: nil)])
    #expect(picker.candidates[0].detail == "a.jsonl")
  }

  /// A project directory can hold dozens of files, and a silent cap reads as the whole list.
  @Test("a directory of many files lists the newest few and says how many it left out")
  func bounded() {
    let many = (0..<33).map { file("f\($0).jsonl", age: TimeInterval($0)) }
    let picker = TranscriptPicker(directory: directory, candidates: many)
    #expect(picker.candidates.count == TranscriptPicker.limit)
    #expect(picker.candidates.map(\.file.name) == ["f0.jsonl", "f1.jsonl", "f2.jsonl", "f3.jsonl", "f4.jsonl", "f5.jsonl"])
    #expect(picker.omitted == 27)
    #expect(picker.omittedNote == "27 older files in this directory aren't listed.")
  }

  @Test("a directory that fits says nothing about what it left out")
  func unbounded() {
    let picker = TranscriptPicker(directory: directory, candidates: [file("a.jsonl", age: 4)])
    #expect(picker.omitted == 0)
    #expect(picker.omittedNote == nil)
  }

  @Test("one omitted file is one file, not one files")
  func singularOmission() {
    let many = (0..<(TranscriptPicker.limit + 1)).map { file("f\($0).jsonl", age: TimeInterval($0)) }
    #expect(TranscriptPicker(directory: directory, candidates: many).omittedNote
      == "1 older file in this directory isn't listed.")
  }

  /// A pick is credited, not presented as a match, which is why `chosenByHand` exists.
  @Test("the picker says what a pick means")
  func copy() {
    let picker = TranscriptPicker(directory: directory, candidates: [file("a.jsonl", age: 4)])
    #expect(picker.title == "Which session is this pane's?")
    #expect(picker.message.contains("first thing somebody typed"))
    #expect(picker.message.contains("say you picked it"))
    #expect(TranscriptPicker.cancelTitle == "Back")
  }

  @Test("a row says the whole thing in one sentence for a reader who cannot see it")
  func accessibility() {
    let picker = TranscriptPicker(
      directory: directory,
      candidates: [file("a.jsonl", age: 4)],
      briefs: ["a.jsonl": "review the diff on the focus branch"]
    )
    #expect(picker.candidates[0].accessibilityLabel
      == "review the diff on the focus branch. a.jsonl · written 4s ago")
  }
}

/// How long a pick lasts: while its file is still in the pane's directory, unless herdr
/// answers. It is re-applied on every read and never written to disk, so it ends with the
/// connection.
struct TranscriptPickTests {
  private func file(_ name: String, age: TimeInterval?) -> TranscriptFile {
    TranscriptFile(path: "/proj/\(name)", sizeInBytes: 9, age: age)
  }

  @Test("a pick names the file again in a later listing of the same directory")
  func stillThere() {
    let pick = TranscriptPick(directory: "/dev/driverr", file: file("mine.jsonl", age: 4))
    let found = pick.file(in: "/dev/driverr", candidates: [file("theirs.jsonl", age: 2), file("mine.jsonl", age: 1)])
    #expect(found?.name == "mine.jsonl")
    // The fresh file, so the header's evidence is current.
    #expect(found?.age == 1)
  }

  @Test("a pick does not survive the file it named going away")
  func fileGone() {
    let pick = TranscriptPick(directory: "/dev/driverr", file: file("mine.jsonl", age: 4))
    #expect(pick.file(in: "/dev/driverr", candidates: [file("theirs.jsonl", age: 2)]) == nil)
  }

  @Test("a pick does not survive the pane's directory changing")
  func directoryChanged() {
    let pick = TranscriptPick(directory: "/dev/driverr", file: file("mine.jsonl", age: 4))
    #expect(pick.file(in: "/dev/tower", candidates: [file("mine.jsonl", age: 4)]) == nil)
  }
}

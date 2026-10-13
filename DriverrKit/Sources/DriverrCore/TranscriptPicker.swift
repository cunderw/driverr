import Foundation

/// The way out of the ambiguity refusal: which of these sessions is this pane's?
///
/// Filenames are uuids and timestamps can be seconds apart, so neither identifies a session
/// to a person. The opening message does, so each row leads with it. The wording is here so
/// `swift test` asserts it.

/// One row: a session file, and the opening line that identifies it.
public struct TranscriptCandidate: Hashable, Sendable, Identifiable {
  public let file: TranscriptFile
  /// The first thing a person typed into the session, or `nil` when Driverr could not read
  /// one. Many session files have no human turn at all.
  public let brief: String?

  public init(file: TranscriptFile, brief: String?) {
    self.file = file
    self.brief = brief
  }

  public var id: String { file.path }

  /// What a row with no brief says instead. Not the filename, which is already the second
  /// line.
  public static let noOpeningLine = "No opening message Driverr could read"

  /// The row's first line, which the pick is made on.
  public var title: String { brief ?? Self.noOpeningLine }

  /// The row's second line: the filename, and its age when known. The same shape as the
  /// refusal's evidence lines, so the lists match.
  public var detail: String {
    guard let age = file.age else { return file.name }
    return "\(file.name) · \(TranscriptAge.phrase(for: age))"
  }

  /// The whole row as one sentence, because a filename and a `·` are not words.
  public var accessibilityLabel: String { "\(title). \(detail)" }
}

/// The picker itself: an ordered, bounded list of candidates and the words around it.
public struct TranscriptPicker: Equatable, Sendable {
  /// How many candidates a picker lists.
  ///
  /// A project directory can hold dozens of session files. The ambiguity comes from
  /// sessions live at the same moment, and six covers the largest real fan-out with room to
  /// spare. What is dropped is stated in `omittedNote`, because a silent cap reads as "these
  /// are all of them".
  public static let limit = 6

  /// The way back. `Back`, not `Cancel`, because the refusal is still behind it and nothing
  /// was chosen.
  public static let cancelTitle = "Back"

  public let directory: String
  /// The rows, newest first, at most `limit` of them.
  public let candidates: [TranscriptCandidate]
  /// How many older files in the directory did not get a row.
  public let omitted: Int

  /// Builds the list from a resolution's candidates and whatever briefs have been read.
  ///
  /// Briefs are keyed by filename, unique within a directory, and arrive one round trip
  /// after the picker opens. A row is drawn from the filename and age at once and gains its
  /// opening line later. A file with no brief keeps the fallback.
  public init(directory: String, candidates: [TranscriptFile], briefs: [String: String] = [:]) {
    self.directory = directory
    let ordered = TranscriptFile.newestFirst(candidates)
    omitted = max(0, ordered.count - Self.limit)
    self.candidates = ordered.prefix(Self.limit).map {
      TranscriptCandidate(file: $0, brief: briefs[$0.name])
    }
  }

  /// The question. The refusal above it has already said why Driverr will not answer it.
  public var title: String { "Which session is this pane's?" }

  /// What a row is and what a pick means. A pick is credited as the user's choice
  /// (`chosenByHand`), never presented as a match.
  public var message: String {
    "Each row opens with the first thing somebody typed into that session. Driverr will read "
      + "the one you pick, and say you picked it."
  }

  /// What the cap left out, when it left anything out.
  public var omittedNote: String? {
    guard omitted > 0 else { return nil }
    return omitted == 1
      ? "1 older file in this directory isn't listed."
      : "\(omitted) older files in this directory aren't listed."
  }
}

/// A file somebody chose, and how long that choice lasts.
///
/// A pick applies while the file it names is still in the pane's own directory. Only
/// herdr's reported `agent_session` overrides it, because that is exact
/// (`TranscriptReader.resolve(for:pick:)`).
///
/// - It is re-applied against a fresh listing on every read, so it survives polls, surface
///   switches and navigation. It also beats a directory match: if the other agent keeps
///   writing and this one goes quiet, the directory becomes rankable and would resolve to
///   the other agent's file.
/// - It never reaches disk and lives on the pane's cached transcript model, so a disconnect
///   ends it. It lapses when the file leaves the directory or the pane's directory changes.
public struct TranscriptPick: Hashable, Sendable {
  /// The pane's working directory when the choice was made. What the resolver is handed,
  /// so a pane that moved on is detected.
  public let directory: String
  /// The chosen file's absolute path.
  public let path: String

  public init(directory: String, file: TranscriptFile) {
    self.directory = directory
    path = file.path
  }

  /// The file this pick names in a fresh listing of `directory`, or `nil`. Returns the
  /// listing's own file, so the header's age is current.
  public func file(in directory: String, candidates: [TranscriptFile]) -> TranscriptFile? {
    guard directory == self.directory else { return nil }
    return candidates.first { $0.path == path }
  }
}

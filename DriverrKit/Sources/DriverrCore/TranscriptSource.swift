import Foundation

/// Which agent's file format a transcript is in. Raw values are herdr's agent tokens, so
/// `TranscriptAgent(rawValue: token)` answers both "can this build read it" and "with which
/// reader".
///
/// It rides on `TranscriptFile` because everything after `resolve` takes only a file. A
/// separate argument could be forgotten, and parsing a Codex rollout with Claude's parser
/// yields a well-formed empty page rather than an error.
public enum TranscriptAgent: String, Hashable, Sendable, CaseIterable {
  case claude
  case codex

  /// The agent's name as a sentence prints it.
  ///
  /// No `default`, so a new case does not compile until it has a name.
  public var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }

  /// The names of every agent this build reads, phrased for a sentence.
  ///
  /// Derived, so a message cannot leave out an agent the reader supports.
  static var supportedNames: String {
    let names = allCases.map(\.displayName)
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }
}

/// One candidate session file on the host.
public struct TranscriptFile: Hashable, Sendable {
  /// Absolute, so host-side commands do not depend on the exec shell's starting directory.
  public let path: String
  public let sizeInBytes: Int
  /// Seconds since the file was last written, by the host's own clock. The host reports its
  /// `date` in the same round trip as the mtime, so a skewed phone clock cannot make a live
  /// session look old. `nil` when the host gave no mtime.
  public let age: TimeInterval?
  /// Whose format this file is in, which picks the read command and parser. Defaults to
  /// `.claude`.
  public let agent: TranscriptAgent
  /// Whether this is a sub-agent's own transcript rather than a pane's.
  ///
  /// `TranscriptReader.page(_:bytes:records:)` passes it to
  /// `TranscriptParser.page(from:forSubagentFile:)`, which then keeps `isSidechain` records
  /// and labels the record with no `origin` as the parent's prompt
  /// (`TranscriptTurn.isParentPrompt`). On the file for `TranscriptAgent`'s reason.
  public let isSubagentFile: Bool

  public init(
    path: String,
    sizeInBytes: Int,
    age: TimeInterval?,
    agent: TranscriptAgent = .claude,
    isSubagentFile: Bool = false
  ) {
    self.path = path
    self.sizeInBytes = sizeInBytes
    self.age = age
    self.agent = agent
    self.isSubagentFile = isSubagentFile
  }

  /// The filename alone, as the ambiguity screen and the picker list it.
  public var name: String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// How recently a file must have been written to count as a running session.
  ///
  /// Two files inside this window make a directory ambiguous. Deliberately generous: too
  /// short a window can draw the wrong conversation with confidence, while too long only
  /// costs an honest "Driverr can't tell".
  public static let liveWindow: TimeInterval = 60

  /// Whether this file is a session running right now. An unknown age is not live, which
  /// makes the directory unrankable and so reported as ambiguous rather than guessed.
  public var isLive: Bool {
    guard let age else { return false }
    return age <= Self.liveWindow
  }

  /// The candidate order every surface uses: newest first, and stable.
  ///
  /// One function, so the refusal, the picker and the ranking agree on the newest file. An
  /// unknown age sorts last, so it cannot win by accident. Stable because `sorted(by:)` is
  /// not, and files written in the same second would otherwise swap rows between polls.
  public static func newestFirst(_ files: [TranscriptFile]) -> [TranscriptFile] {
    files.enumerated()
      .sorted { left, right in
        let a = left.element.age ?? .greatestFiniteMagnitude
        let b = right.element.age ?? .greatestFiniteMagnitude
        return a == b ? left.offset < right.offset : a < b
      }
      .map(\.element)
  }
}

/// How Driverr came to believe this file is the pane's. A guess names its evidence, and a
/// file the user picked credits the choice.
public enum TranscriptProvenance: Hashable, Sendable {
  /// herdr's integration reported the session id, or a herdr-core terminal's process named
  /// it in Claude Code's own record. Nothing to caveat.
  case reportedByHerdr(sessionID: String)
  /// herdr reported a session that was continued, and this is the file it was carried into.
  ///
  /// Still exact: Claude Code names the successor in a record at the end of the reported
  /// file, and the resolver follows only that. It reads to the user as `reportedByHerdr`.
  /// `reportedID` is kept, not rendered, for when the two disagree.
  case continuedFromHerdrSession(reportedID: String, sessionID: String)
  /// Derived from the pane's working directory. The directory and the file's age are the
  /// evidence, both on `TranscriptSource`.
  case matchedByDirectory
  /// The user picked this file out of the candidates on the ambiguity screen.
  case chosenByHand
  /// A sub-agent's own file, opened from a spawn line. Linked by `tool_use` id or teammate
  /// name, never matched by directory.
  case subagent
}

public struct TranscriptSource: Hashable, Sendable {
  public let file: TranscriptFile
  public let provenance: TranscriptProvenance
  /// The project directory that holds the file.
  public let directory: String
  /// When this device asked, by its own clock.
  ///
  /// `file.age` is frozen at the listing, so pairing it with this lets the age advance (see
  /// `modifiedAt`). Not an mtime from the host: only elapsed time since the read is measured
  /// on the device, so clock skew cannot make a live session look stale.
  public let readAt: Date

  public init(
    file: TranscriptFile,
    provenance: TranscriptProvenance,
    directory: String,
    readAt: Date = Date()
  ) {
    self.file = file
    self.provenance = provenance
    self.directory = directory
    self.readAt = readAt
  }

  /// When the file was last written, on this device's clock: the host's age carried back
  /// from the read, so the two clocks are never compared. `nil` when the host gave no mtime.
  public var modifiedAt: Date? {
    file.age.map { readAt.addingTimeInterval(-$0) }
  }

  /// How old the file is at `now`. Clamped at zero, so a device clock that jumps backwards
  /// cannot show a file written in the future.
  public func age(asOf now: Date) -> TimeInterval? {
    modifiedAt.map { max(0, now.timeIntervalSince($0)) }
  }
}

/// Why a pane has no transcript. Each reason needs a different sentence.
public enum TranscriptAbsence: Hashable, Sendable {
  /// A plain shell. Not a failure, and the common case.
  case paneHasNoAgent
  /// An agent this build has no reader for, named so the screen can say which.
  case agentNotSupported(agent: String)
  /// herdr reported no working directory for the pane.
  case paneHasNoDirectory
  /// The project directory holds no session file, or does not exist.
  case noSessionFiles(directory: String)
  /// herdr's integration named a session, and no file by that name is in this pane's
  /// directory.
  ///
  /// Usually a new session: Claude Code names it at once and writes the file with the first
  /// prompt, and the watcher polls until it lands. Rarely, the pane has left the agent's
  /// directory and the file never appears. `TranscriptNotice(absence:agentStatus:)` uses the
  /// agent's status to tell the two apart.
  ///
  /// Never fall back to the newest file here. It is not this session's, so it is someone
  /// else's conversation or an older one.
  case reportedSessionMissing(sessionID: String, directory: String)
  /// The agent runs on a machine a herdr-core added, and session files are read only on the
  /// computer Driverr connected to. A lookup here would read that computer's files.
  case agentOnAddedMachine(agent: String, machine: String)
  /// A tapped spawn line whose link no sub-agent file carries. The meta file may not be
  /// written yet, or Claude Code left the link unresolved, which happens occasionally.
  case subagentFileNotFound
}

/// Which file is this pane's, or the fact that Driverr cannot tell.
///
/// `ambiguous` is common: two live sessions in one working directory is herdr's own use
/// case. Driverr reports it and draws nothing, because the newest file could be another
/// agent's.
public enum TranscriptResolution: Hashable, Sendable {
  case found(TranscriptSource)
  /// Every session file in the directory, newest first, not only the live ones. The screen
  /// counts the live ones with `TranscriptFile.isLive` and the picker offers all of them.
  case ambiguous(directory: String, candidates: [TranscriptFile])
  case absent(TranscriptAbsence)

  public var source: TranscriptSource? {
    guard case .found(let source) = self else { return nil }
    return source
  }
}

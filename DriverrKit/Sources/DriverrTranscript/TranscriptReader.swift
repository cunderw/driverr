import DriverrCore
import Foundation

/// Turns a pane into the agent session transcript behind it.
///
/// Two separate calls: which file is this pane's, and a bounded, parsed tail of it. The
/// first answer is shown on its own, so a pane whose session cannot be identified says so
/// instead of spinning.
///
/// Driven by a `CommandRunner` closure, as `CLIControl` is, so it needs no SSH import and
/// tests answer from a dictionary.
public struct TranscriptReader: Sendable {
  private let run: CommandRunner
  /// The device's clock, injected for tests. Read once per resolve and stamped onto the
  /// source as "when I asked". File ages are always the host's own subtraction; see
  /// `TranscriptSource.readAt`.
  private let now: @Sendable () -> Date

  public init(run: @escaping CommandRunner, now: @escaping @Sendable () -> Date = Date.init) {
    self.run = run
    self.now = now
  }

  /// The agents this build has a reader for, keyed by herdr's token. One lookup answers
  /// both "can I read this" and "which reader", so a Codex pane cannot get Claude's parser.
  static func supported(_ token: String) -> TranscriptAgent? {
    TranscriptAgent(rawValue: token.lowercased())
  }

  // MARK: - Which file

  /// Which session file is this pane's, or the reason there is no answer.
  ///
  /// Tiers, in order of how much is assumed:
  ///
  /// 1. **`agent_session` reported by herdr**, or read from Claude Code's record of a
  ///    herdr-core terminal's process. Exact. Needs an installed integration or a readable
  ///    record, so its absence is ordinary. Follows `continued-in` handovers; see
  ///    `continuation(from:reported:in:)`.
  /// 2. **The newest file in the directory derived from the pane's `cwd`.**
  /// 3. **Ambiguous**: two or more files written within the last minute. Reported, never
  ///    resolved, because the newest could be another agent's conversation. Sibling
  ///    worktrees have distinct `cwd`s, which keeps this case narrow.
  ///
  /// **A `pick` sits between tiers 1 and 2.** A person's answer to an earlier ambiguity
  /// beats the heuristic but not herdr's exact report. See `TranscriptPick`.
  public func resolve(for pane: Pane, pick: TranscriptPick? = nil) async throws
    -> TranscriptResolution
  {
    guard let agent = pane.agent else { return .absent(.paneHasNoAgent) }
    if let machine = agent.machine {
      return .absent(.agentOnAddedMachine(agent: agent.name, machine: machine))
    }
    guard let kind = self.agent(of: agent) else {
      return .absent(.agentNotSupported(agent: agent.name))
    }
    guard let workingDirectory = nonEmpty(pane.directory) else {
      // Tier 1 needs it too: finding the reported file without a directory would mean
      // walking all of `~/.claude/projects`.
      return .absent(.paneHasNoDirectory)
    }

    if kind == .codex {
      return try await resolveCodex(
        workingDirectory: workingDirectory, reported: agent.session?.identifier, pick: pick)
    }

    let listing = try await list(workingDirectory: workingDirectory)
    // Taken after the listing, so the elapsed time starts where the host's age left off.
    let readAt = now()
    let reported = agent.session?.identifier

    if let reported {
      let wanted = "\(reported).\(ClaudeProjects.fileExtension)"
      // herdr names a new session before its first record is written, so an empty
      // directory is the agent starting up, not a missing file.
      guard !listing.files.isEmpty else {
        return .absent(.noSessionFiles(directory: workingDirectory))
      }
      guard let match = listing.files.first(where: { $0.name == wanted }) else {
        // Does not fall through to tier 2; see `TranscriptAbsence.reportedSessionMissing`.
        return .absent(
          .reportedSessionMissing(sessionID: reported, directory: workingDirectory)
        )
      }
      let continued = try await continuation(from: match, reported: reported, in: listing)
      return .found(
        TranscriptSource(
          file: continued.file,
          provenance: continued.file.name == match.name
            ? .reportedByHerdr(sessionID: reported)
            : .continuedFromHerdrSession(reportedID: reported, sessionID: continued.sessionID),
          directory: workingDirectory,
          readAt: readAt
        )
      )
    }

    guard !listing.files.isEmpty else {
      return .absent(.noSessionFiles(directory: workingDirectory))
    }

    // Newest first, as a `DriverrCore` value the picker and the refusal re-derive. An
    // unknown age sorts last and makes the directory unrankable. The sort is stable
    // because ambiguous files often share a second.
    let candidates = TranscriptFile.newestFirst(listing.files)

    // Checked **before** the ranking, not only on ambiguity. When the pane's own agent
    // goes quiet and the other keeps writing, the directory becomes rankable again and
    // would otherwise resolve past the person's answer.
    if let pick, let chosen = pick.file(in: workingDirectory, candidates: candidates) {
      return .found(
        TranscriptSource(
          file: chosen,
          provenance: .chosenByHand,
          directory: workingDirectory,
          readAt: readAt
        )
      )
    }

    guard let newest = candidates.first else {
      return .absent(.noSessionFiles(directory: workingDirectory))
    }
    if candidates.count > 1 {
      // Two live sessions, or ages the host could not report. Both draw nothing.
      let live = candidates.filter(\.isLive).count
      let unrankable = candidates.contains { $0.age == nil }
      if live > 1 || unrankable {
        return .ambiguous(directory: workingDirectory, candidates: candidates)
      }
    }
    return .found(
      TranscriptSource(
        file: newest,
        provenance: .matchedByDirectory,
        directory: workingDirectory,
        readAt: readAt
      )
    )
  }

  // MARK: - Codex rollouts

  /// `resolve`'s Codex arm: the same tiers and picker, with two differences.
  ///
  /// - **The `cwd` is matched, not slugged**, because Codex records the literal path. See
  ///   `CodexRollouts.mainThreadCandidates`, which also drops sub-agent and reviewer threads.
  /// - **Tier 1 matches a header field, not a filename.** See
  ///   `CodexRollouts.candidate(withID:from:workingDirectory:)`.
  ///
  /// No continuation walk: Codex writes no `continued-in` record.
  ///
  /// Every source's `directory` is the pane's `cwd`, not the day directory. The header chip
  /// shows it and `TranscriptPick` is keyed on it, so a pick survives a new day's rollout.
  private func resolveCodex(
    workingDirectory: String, reported: String?, pick: TranscriptPick?
  ) async throws -> TranscriptResolution {
    let answer = try await execute(TranscriptCommands.codexListCommand())
    let output = answer.standardOutput
    // Taken after the listing, for `resolve`'s reason.
    let readAt = now()
    // Parsed once. Tier 1 needs the age too, for the staleness header and the watcher.
    let candidates = CodexRollouts.listing(from: output, workingDirectory: workingDirectory)

    if let reported {
      guard
        let match = CodexRollouts.candidate(
          withID: reported, from: output, workingDirectory: workingDirectory)
      else {
        // Does not fall through to the `cwd` match, for
        // `TranscriptAbsence.reportedSessionMissing`'s reason.
        return .absent(
          .reportedSessionMissing(sessionID: reported, directory: workingDirectory)
        )
      }
      return .found(
        TranscriptSource(
          file: TranscriptFile(
            path: match.path,
            sizeInBytes: match.sizeInBytes ?? 0,
            age: candidates.first { $0.path == match.path }?.age,
            agent: .codex
          ),
          provenance: .reportedByHerdr(sessionID: reported),
          directory: workingDirectory,
          readAt: readAt
        )
      )
    }

    guard !candidates.isEmpty else {
      return .absent(.noSessionFiles(directory: workingDirectory))
    }

    if let pick, let chosen = pick.file(in: workingDirectory, candidates: candidates) {
      return .found(
        TranscriptSource(
          file: chosen,
          provenance: .chosenByHand,
          directory: workingDirectory,
          readAt: readAt
        )
      )
    }

    guard let newest = candidates.first else {
      return .absent(.noSessionFiles(directory: workingDirectory))
    }
    if candidates.count > 1 {
      let live = candidates.filter(\.isLive).count
      let unrankable = candidates.contains { $0.age == nil }
      if live > 1 || unrankable {
        // The picker lists filenames and mtimes only; `briefs(in:for:)` has no Codex arm.
        return .ambiguous(directory: workingDirectory, candidates: candidates)
      }
    }
    return .found(
      TranscriptSource(
        file: newest,
        provenance: .matchedByDirectory,
        directory: workingDirectory,
        readAt: readAt
      )
    )
  }

  // MARK: - Where the conversation went

  /// The file this pane's conversation is in, following handovers from the one herdr named.
  ///
  /// Claude Code closes a continued session with a `continued-in` record and carries on in a
  /// new file, while herdr keeps reporting the old id. So tier 1 is the tier that goes stale.
  ///
  /// **The redirect happens before the read**, so the page, paging, header, provenance and
  /// picker all name the file on screen. `pageBack` never re-resolves, so a reader paging
  /// history is not moved to another file.
  ///
  /// Returns the reported file unchanged when there is nothing to follow, with no round trip
  /// for a one-file directory.
  private func continuation(
    from reportedFile: TranscriptFile,
    reported: String,
    in listing: Listing
  ) async throws -> (file: TranscriptFile, sessionID: String) {
    // A handover names another file in this directory, so one file has nowhere to point.
    guard listing.files.count > 1,
      let command = TranscriptCommands.continuationCommand(
        directory: listing.directory,
        names: listing.files.map(\.name)
      )
    else { return (reportedFile, reported) }

    // **Best-effort.** A channel failure here returns the reported file rather than failing
    // the chat over an improvement to an answer already in hand.
    guard let answer = try? await execute(command) else { return (reportedFile, reported) }

    let map = Self.continuations(from: answer.standardOutput)
    var file = reportedFile
    var sessionID = reported
    // Every hop must land on a file in this listing and no name is visited twice, so the
    // walk ends within the directory's file count. Do not add a hop limit: it would
    // truncate a legitimate chain and leave a stale file, and the next resolve would stop
    // in the same place. Seeded with the start, so a self-pointer is a cycle too.
    var visited: Set<String> = [reportedFile.name]
    while let next = map[file.name] {
      let name = "\(next).\(ClaudeProjects.fileExtension)"
      // A pointer at a missing file keeps the current one. Falling back to the newest file
      // would be the guess `reportedSessionMissing` refuses.
      guard !visited.contains(name), let found = listing.files.first(where: { $0.name == name })
      else { break }
      visited.insert(name)
      file = found
      sessionID = next
    }
    return (file, sessionID)
  }

  /// `!<file><TAB><session id>` lines in, one continuation per file out. A line without
  /// the mark is dropped, so the walk never goes somewhere nobody named.
  static func continuations(from output: String) -> [String: String] {
    var map: [String: String] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard line.hasPrefix(TranscriptCommands.resultMark) else { continue }
      let fields = line.dropFirst(TranscriptCommands.resultMark.count)
        .split(
          separator: TranscriptCommands.fieldSeparator,
          maxSplits: 1,
          omittingEmptySubsequences: false
        )
      guard fields.count == 2 else { continue }
      let name = trimmed(String(fields[0]))
      let sessionID = trimmed(String(fields[1]))
      guard !name.isEmpty, !sessionID.isEmpty else { continue }
      map[name] = sessionID
    }
    return map
  }

  // MARK: - Has it been written to

  /// mtime and size for one file, in one round trip. An open chat asks this repeatedly and
  /// calls `read` only when it changes; see `PaneTranscriptModel.watch(every:)`.
  ///
  /// **`nil` is an answer, not a failure**: the file is gone or unreadable, and a watcher
  /// leaves the page alone. A channel failure still throws.
  ///
  /// The mtime is the host's clock and is only compared with another reading of itself.
  public func probe(_ file: TranscriptFile) async throws -> TranscriptStamp? {
    let result = try await execute(TranscriptCommands.sizeCommand(path: file.path))
    return Self.stamp(from: result.standardOutput)
  }

  /// `probe` for the file herdr named when there is no `TranscriptFile` for it yet.
  ///
  /// A restarted Claude Code names its new session before writing the file, so `resolve`
  /// answers `reportedSessionMissing` or `noSessionFiles`. This asks about the file by its
  /// future name, which costs far less per tick than re-listing the directory.
  ///
  /// `nil` for anything but a Claude pane with a reported id and a directory, and for a file
  /// that is not there yet. A Codex rollout's name is not derived from its id.
  ///
  /// Also `nil`, with no round trip, for an id `resolve` could never match: one containing
  /// `/`, or with whitespace at either end. The probe would answer, the re-resolve would
  /// still say missing, and the caller would re-list the directory on every tick.
  public func probeReportedSession(for pane: Pane) async throws -> TranscriptStamp? {
    guard let agent = pane.agent, self.agent(of: agent) == .claude,
      let reported = agent.session?.identifier,
      !reported.contains("/"), reported == trimmed(reported),
      let workingDirectory = nonEmpty(pane.directory)
    else { return nil }
    let command = TranscriptCommands.reportedSizeCommand(
      projectSlug: ClaudeProjects.slug(forWorkingDirectory: workingDirectory),
      sessionID: reported)
    let result = try await execute(command)
    return Self.stamp(from: result.standardOutput)
  }

  /// `mtime<TAB>size` in, a stamp or nothing out. Both fields go through `epoch`, because
  /// `Int("-1")` succeeds and a negative size would read as a change and re-fetch the page
  /// every few seconds.
  static func stamp(from output: String) -> TranscriptStamp? {
    let fields = trimmed(output).split(
      separator: TranscriptCommands.fieldSeparator,
      omittingEmptySubsequences: false
    )
    guard fields.count == 2,
      let modified = epoch(trimmed(String(fields[0]))),
      let size = epoch(trimmed(String(fields[1])))
    else { return nil }
    return TranscriptStamp(modified: modified, sizeInBytes: Int(size))
  }

  // MARK: - What each candidate was asked to do

  /// Every candidate's opening line, keyed by filename, in one round trip. The picker is
  /// keyed on it; `TranscriptCommands.briefCommand` has the cost.
  ///
  /// A candidate missing from the answer is ordinary: a file with no human turn has no
  /// brief, and the picker draws that row from filename and mtime.
  public func briefs(in directory: String, for files: [TranscriptFile]) async throws
    -> [String: String]
  {
    // **Codex gets no briefs, and the round trip is refused.** `briefCommand` `cd`s into
    // one directory, but Codex candidates live in day directories while `directory` is the
    // pane's `cwd`. And `TranscriptParser.brief` decodes a `ClaudeRecord`, which a rollout
    // line is not. The answer could only be `[:]`.
    guard !files.contains(where: { $0.agent == .codex }) else { return [:] }
    guard
      let command = TranscriptCommands.briefCommand(
        directory: directory, names: files.map(\.name))
    else { return [:] }
    let result = try await execute(command)
    return Self.briefs(from: result.standardOutput)
  }

  /// `name<TAB>record` lines in, one brief per file out. A file's records arrive together
  /// and in order. A line with no tab is dropped, because a guessed filename would put a
  /// brief on the wrong row.
  static func briefs(from output: String) -> [String: String] {
    var records: [String: [String]] = [:]
    var order: [String] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = line.split(
        separator: TranscriptCommands.fieldSeparator,
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard fields.count == 2 else { continue }
      let name = trimmed(String(fields[0]))
      let record = String(fields[1])
      guard !name.isEmpty, !record.isEmpty else { continue }
      if records[name] == nil { order.append(name) }
      records[name, default: []].append(record)
    }
    var briefs: [String: String] = [:]
    for name in order {
      guard let brief = TranscriptParser.brief(from: records[name]?.joined(separator: "\n") ?? "")
      else { continue }
      briefs[name] = brief
    }
    return briefs
  }

  // MARK: - What is installed on this host

  /// Every slash command this session could run, read off the host in one round trip. The
  /// transcript-mined list is empty on a fresh session, so this fills that gap. See
  /// `TranscriptCommands.skillsCommand`.
  ///
  /// **It cannot fail.** Every failure comes back as `.builtInsOnly`, because a caller could
  /// do nothing more with an error.
  ///
  /// - A non-zero exit is not an error. `FakeTranscriptHost.run` answers 127 for a command
  ///   it does not know, so a throwing version would break every fixture that predates this.
  /// - `cwd` is optional, as `Pane.directory` is. Without it only the project scope is lost.
  public func skills(cwd: String?) async -> SlashCommandCatalog {
    let command = TranscriptCommands.skillsCommand(cwd: cwd)
    guard let result = try? await run(command), result.exitStatus == 0 else {
      return .builtInsOnly
    }
    return Self.catalog(from: result.standardOutput)
  }

  /// Entry lines and prefixed frontmatter lines in, a catalogue out.
  ///
  /// **A line's role is its first byte**: `!` opens an entry, `+` is frontmatter, anything
  /// else is dropped. That keeps shell diagnostics from becoming commands. An entry with an
  /// unknown scope letter is dropped whole, rather than filed under a default source.
  static func catalog(from output: String) -> SlashCommandCatalog {
    var found: [SlashCommand] = []
    var name: String?
    var source: SlashCommand.Source?
    var frontmatter: [String] = []

    var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    // **A payload at the bound loses its last line.** `head -c` cuts mid-line, and a cut
    // entry line such as `!u<TAB>che` parses as a well-formed `/che` that exists nowhere.
    // A cut entry cannot be told from a whole one, so the last line always goes.
    if output.utf8.count >= TranscriptCommands.skillPayloadBytes, !lines.isEmpty {
      lines.removeLast()
    }

    func flush() {
      defer {
        name = nil
        source = nil
        frontmatter = []
      }
      guard let name, let source, !name.isEmpty else { return }
      found.append(
        SlashCommand(
          name: "/" + name,
          description: SkillFrontmatter.description(inFrontmatter: frontmatter),
          source: source
        )
      )
    }

    for line in lines {
      if line.hasPrefix(TranscriptCommands.frontmatterMark) {
        frontmatter.append(String(line.dropFirst(TranscriptCommands.frontmatterMark.count)))
        continue
      }
      guard line.hasPrefix(TranscriptCommands.skillMark) else { continue }
      flush()
      let fields = line.dropFirst(TranscriptCommands.skillMark.count)
        .split(
          separator: TranscriptCommands.fieldSeparator,
          maxSplits: 1,
          omittingEmptySubsequences: false
        )
      guard fields.count == 2 else { continue }
      source = Self.source(ofScope: String(fields[0]))
      name = trimmed(String(fields[1]))
    }
    flush()
    return .installed(found)
  }

  private static func source(ofScope scope: String) -> SlashCommand.Source? {
    switch scope {
    case TranscriptCommands.userSkillScope: return .userSkill
    case TranscriptCommands.projectSkillScope: return .projectSkill
    case TranscriptCommands.projectCommandScope: return .projectCommand
    case TranscriptCommands.pluginSkillScope: return .pluginSkill
    default: return nil
    }
  }

  /// Which reader this pane's agent gets, or `nil`.
  ///
  /// The integration's token wins, then the pane's `kind`. Only with no token at all is the
  /// display name matched, by prefix against every supported token, so `"Claude Code"` and
  /// `"Codex CLI"` both reach their reader.
  private func agent(of agent: Agent) -> TranscriptAgent? {
    if let token = agent.session?.agent ?? agent.kind, !token.isEmpty {
      return Self.supported(token)
    }
    let name = agent.name.lowercased()
    return TranscriptAgent.allCases.first { name.hasPrefix($0.rawValue) }
  }

  /// What one `listCommand` came back with. Internal so `listing(from:)` can be tested.
  struct Listing {
    var directory: String
    var files: [TranscriptFile]
  }

  private func list(workingDirectory: String) async throws -> Listing {
    let slug = ClaudeProjects.slug(forWorkingDirectory: workingDirectory)
    let result = try await execute(TranscriptCommands.listCommand(projectSlug: slug))
    return Self.listing(from: result.standardOutput)
  }

  /// `date`, then the expanded project directory, then one line per session file. The mtime
  /// digit check matters most: a mount point read as an epoch would make a stale-looking
  /// file and resolve a directory that should be ambiguous.
  static func listing(from output: String) -> Listing {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let now = lines.first.flatMap { TimeInterval(trimmed($0)) }
    if !lines.isEmpty { lines.removeFirst() }
    let directory = lines.first.map(trimmed) ?? ""
    if !lines.isEmpty { lines.removeFirst() }

    let files: [TranscriptFile] = lines.compactMap { line in
      let fields = line.split(
        separator: TranscriptCommands.fieldSeparator,
        maxSplits: 2,
        omittingEmptySubsequences: false
      )
      guard fields.count == 3 else { return nil }
      let name = trimmed(String(fields[2]))
      guard !name.isEmpty else { return nil }
      let modified = epoch(trimmed(String(fields[0])))
      let size = Int(trimmed(String(fields[1]))) ?? 0
      let age: TimeInterval? = {
        guard let now, let modified, modified > 0 else { return nil }
        // Clamped at zero: an mtime a hair ahead of `date` would otherwise read as the future.
        return max(0, now - modified)
      }()
      let path = directory.isEmpty ? name : "\(directory)/\(name)"
      return TranscriptFile(path: path, sizeInBytes: size, age: age)
    }
    return Listing(directory: directory, files: files)
  }

  /// An epoch second, or nothing.
  ///
  /// **Every character must be an ASCII digit.** `TimeInterval(_:)` alone accepts `inf`,
  /// `nan`, `1e9` and a leading sign, and `inf` or `nan` would make an unrankable directory
  /// rankable. A "contains a digit" check would pass `/mnt/data2`.
  static func epoch(_ field: String) -> TimeInterval? {
    guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return TimeInterval(field)
  }

  // MARK: - A sub-agent's own file

  /// The sub-agent file a spawn or teammate is linked to, or `nil`.
  ///
  /// **`toolUseID` wins when both are given.** It is exact. A teammate's `name` is looser:
  /// a respawn under the same name leaves several files, and the newest wins.
  ///
  /// An empty argument counts as `nil`, because `ClaudeBlock.id` can be an empty string. An
  /// argument `isSafeLinkLiteral` refuses returns `nil` and does not fall through to the
  /// other one, which would answer a different question.
  ///
  /// **`directory` is the expanded, absolute project directory** (`TranscriptSource.directory`
  /// or `Listing.directory`), never a raw `cwd` or a `$HOME` fragment. It is `shellQuoted`
  /// whole, so a `$` in it stays literal.
  ///
  /// **A `toolUseID` is searched across the whole project directory; a `teammateName` only
  /// under `sessionID`.** A tool-use id is unique, and a spawn made before a `continued-in`
  /// handover can have its meta file under either session. A name is unique only within a
  /// session, so a teammate spawned before a handover is not found, and the chat says so.
  ///
  /// The returned file has `isSubagentFile` set, ready for `read(_:)`.
  public func subagentFile(
    toolUseID: String? = nil,
    teammateName: String? = nil,
    directory: String,
    sessionID: String
  ) async throws -> TranscriptFile? {
    let literal: String
    let scope: String?
    if let toolUseID = nonEmpty(toolUseID) {
      guard Self.isSafeLinkLiteral(toolUseID) else { return nil }
      literal = #""toolUseId":"\#(toolUseID)""#
      scope = nil
    } else if let teammateName = nonEmpty(teammateName) {
      guard Self.isSafeLinkLiteral(teammateName) else { return nil }
      literal = #""name":"\#(teammateName)""#
      scope = sessionID
    } else {
      return nil
    }
    let command = TranscriptCommands.subagentLinkCommand(
      directory: directory, sessionID: scope, literal: literal)
    let result = try await execute(command)
    let listing = Self.listing(from: result.standardOutput)
    let candidates = listing.files.map {
      TranscriptFile(path: $0.path, sizeInBytes: $0.sizeInBytes, age: $0.age, isSubagentFile: true)
    }
    return TranscriptFile.newestFirst(candidates).first
  }

  /// Whether a `toolUseID` or `teammateName` is safe to search a meta file for verbatim.
  ///
  /// **`grep -F -e <pattern>` treats each line of the pattern as a separate pattern**, so a
  /// value with a newline (or a lone `\r`) widens the search: `"nobody\n318"` would match
  /// any file containing `"name":"nobody` or `318"`. A `"` or `\` would arrive escaped in
  /// the JSON, so searching for it unescaped changes the literal's meaning. Real ids and
  /// names contain none of these.
  static func isSafeLinkLiteral(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\"" && scalar != "\\"
      }
  }

  /// The sub-agent file named by its `agentId`, under `sessionID`, or `nil`. The returned
  /// file has `isSubagentFile` set. See `SubagentLink.agent(id:)`.
  public func subagentFile(
    agentID: String, directory: String, sessionID: String
  ) async throws -> TranscriptFile? {
    guard Self.isSafeAgentID(agentID) else { return nil }
    let command = TranscriptCommands.subagentFileCommand(
      directory: directory, sessionID: sessionID, agentID: agentID)
    let result = try await execute(command)
    return Self.listing(from: result.standardOutput).files.first.map {
      TranscriptFile(path: $0.path, sizeInBytes: $0.sizeInBytes, age: $0.age, isSubagentFile: true)
    }
  }

  /// Whether an `agentId` is safe to put in a file name on the host: ASCII letters, digits,
  /// `-` and `_` only. Real ids are `a` and hex, or `a<name>-<hex>`. A `/` or `..` would
  /// leave the `subagents` directory.
  static func isSafeAgentID(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII
          && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
      }
  }

  // MARK: - Every sub-agent a session spawned

  /// The sub-agents one session's meta files list. `directory` is the expanded project
  /// directory, as for `subagentFile`; `sessionID` is the session file's name without
  /// `.jsonl`.
  ///
  /// Only the session's own `subagents` directory: a spawn made before a `continued-in`
  /// handover is listed under the session that made it.
  public func subagentList(directory: String, sessionID: String) async throws -> SubagentList {
    let command = TranscriptCommands.subagentListCommand(directory: directory, sessionID: sessionID)
    let result = try await execute(command)
    return Self.subagentList(from: result.standardOutput, readAt: now())
  }

  /// `date`, the directory, `#<count>`, then one line per sub-agent; see
  /// `TranscriptCommands.subagentListCommand`. Every time is placed on `readAt`'s clock by the
  /// host's own subtraction: the spawn time is a host timestamp and the write time a host
  /// mtime, so each is moved by `readAt` minus the host's clock. A line whose meta does not
  /// decode is dropped and still counted, because the count is the host's.
  static func subagentList(from output: String, readAt: Date) -> SubagentList {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let hostNow = lines.first.flatMap { epoch(trimmed($0)) }
    if !lines.isEmpty { lines.removeFirst() }
    // The directory line. Nothing here needs it: rows open by link, not by path.
    if !lines.isEmpty { lines.removeFirst() }
    var total = 0
    if let first = lines.first, first.hasPrefix(TranscriptCommands.subagentCountMark) {
      total = Int(trimmed(String(first.dropFirst(TranscriptCommands.subagentCountMark.count)))) ?? 0
      lines.removeFirst()
    }

    func date(_ field: Substring) -> Date? {
      guard let hostNow, let modified = epoch(trimmed(String(field))), modified > 0 else {
        return nil
      }
      return readAt.addingTimeInterval(-max(0, hostNow - modified))
    }

    /// An ISO 8601 spawn time from the host. Without the host's clock it stands as written.
    func spawned(_ field: Substring) -> Date? {
      guard let stamp = TranscriptParser.timestamp(trimmed(String(field))) else { return nil }
      guard let hostNow else { return stamp }
      return readAt.addingTimeInterval(-max(0, hostNow - stamp.timeIntervalSince1970))
    }

    let summaries: [SubagentSummary] = lines.compactMap { line in
      let fields = line.split(
        separator: TranscriptCommands.fieldSeparator, maxSplits: 4,
        omittingEmptySubsequences: false)
      guard fields.count == 5 else { return nil }
      let file = trimmed(String(fields[3]))
      guard file.hasPrefix("agent-"), file.hasSuffix(".jsonl"),
        let meta = try? JSONDecoder().decode(SubagentMeta.self, from: Data(fields[4].utf8))
      else { return nil }
      let id = String(file.dropFirst("agent-".count).dropLast(".jsonl".count))
      guard !id.isEmpty else { return nil }
      return meta.summary(id: id, spawnedAt: spawned(fields[0]), writtenAt: date(fields[1]))
    }
    return SubagentList(total: total, summaries: summaries)
  }

  // MARK: - Reading it

  /// How many turns a first page aims for.
  public static let defaultTurns = 6

  /// A page of the conversation, ending at the end of the file.
  ///
  /// **Only ever a tail.** Session files reach megabytes and only grow. The window starts
  /// sized to the turns asked for and grows when too few come back. A long autonomous run
  /// makes that common, because forty tool calls are one turn.
  ///
  /// Growth stops at the start of the file or at the top of the ladder. Every rung is a
  /// round trip, so the ladder is short and steep.
  ///
  /// The top two rungs are a reserve, climbed only while the previous rung gained turns.
  /// When a rung gains nothing, the page is bounded by something other than the window (a
  /// run of tool calls is one turn however much is read), and more round trips buy nothing.
  /// A page that still comes up short with file behind it is marked, so the pager can tell
  /// it from a short session.
  public func read(_ file: TranscriptFile, turns wanted: Int = defaultTurns) async throws
    -> Transcript
  {
    let wanted = max(1, wanted)
    var transcript = Transcript.empty
    var turnsOnThePreviousRung = -1
    for (rung, attempt) in Self.ladder(forTurns: wanted).enumerated() {
      transcript = try await page(file, bytes: attempt.bytes, records: attempt.records)
      if transcript.turns.count >= wanted { return transcript }
      if transcript.window.reachesStartOfFile { return transcript }
      // Only the reserve is conditional. The base rungs are climbed whatever they return.
      if rung + 1 >= Self.baseRungs, transcript.turns.count <= turnsOnThePreviousRung {
        break
      }
      turnsOnThePreviousRung = transcript.turns.count
    }
    // Every other exit returned, so turns are missing and file remains behind the page.
    // `stoppingShort` drops the flag when the window reached the front.
    return transcript.stoppingShort()
  }

  struct Attempt: Hashable {
    let bytes: Int
    let records: Int
  }

  /// Rungs climbed whatever they return. The rungs above are the reserve `read` spends only
  /// while a rung is still gaining turns.
  static let baseRungs = 4

  /// How many rungs exist, reserve included.
  static let allRungs = 6

  /// The growth ladder, in climbing order.
  ///
  /// Both bounds grow together because either can bind: `records` for a chatty file, `bytes`
  /// for a file with one huge tool result. Sized from the turns asked for, so asking for
  /// twenty does not spend round trips finding six too few.
  ///
  /// Six records a turn and 4 KB a record come from real files. They make the byte window
  /// generous, so the record bound usually does the work. That is the right way round:
  /// bytes are read on the host and records cross the wire.
  ///
  /// Each rung is four times the last. Four base rungs reach about 16 MB for a six-turn ask;
  /// the two reserve rungs reach about 250 MB, past any real session file.
  static func ladder(forTurns turns: Int) -> [Attempt] {
    let records = max(60, turns * 6)
    return (0..<allRungs).map { step in
      let factor = 1 << (2 * step)
      return Attempt(bytes: records * 4096 * factor, records: records * factor)
    }
  }

  /// One rung of the ladder, against whichever agent's file this is.
  ///
  /// **The command and the parser must switch together.** Codex records fed to Claude's
  /// parser would all be dropped, giving a well-formed empty page that renders as "nothing
  /// has been said yet" rather than as an error. Both read `file.agent`.
  private func page(_ file: TranscriptFile, bytes: Int, records: Int) async throws -> Transcript {
    let command =
      file.agent == .codex
      ? TranscriptCommands.codexReadCommand(path: file.path, bytes: bytes, records: records)
      : TranscriptCommands.readCommand(path: file.path, bytes: bytes, records: records)
    let result = try await execute(command)
    let (header, body) = Self.split(result.standardOutput)
    guard let header else {
      throw AppError.transcriptUnreadable(reason: "The host answered with nothing.")
    }
    guard let size = header.sizeInBytes else {
      throw AppError.transcriptUnreadable(
        reason: "\(file.name) is no longer on the host, or cannot be read."
      )
    }

    let parsed =
      file.agent == .codex
      ? TranscriptParser.codexPage(from: body)
      : TranscriptParser.page(from: body, forSubagentFile: file.isSubagentFile)
    return Transcript(
      turns: parsed.turns,
      endsMidRecord: header.endsMidRecord,
      window: TranscriptWindow(
        bytesFetched: body.utf8.count,
        bytesRead: min(bytes, size),
        fileSizeInBytes: size,
        records: parsed.records + parsed.unreadableRecords,
        unreadableRecords: parsed.unreadableRecords,
        // Both conditions are needed. The record bound can cut records off the top of a window
        // that did start at byte zero, and offering no further page would hide them.
        reachesStartOfFile: bytes >= size
          && parsed.records + parsed.unreadableRecords < records
      ),
      contextUsage: parsed.contextUsage,
      agentStop: parsed.agentStop
    )
  }

  struct Header {
    /// `nil` when the host could not size the file: it is gone or unreadable.
    let sizeInBytes: Int?
    let endsMidRecord: Bool
  }

  /// The header line off the front, and everything after it.
  static func split(_ output: String) -> (Header?, String) {
    guard let newline = output.firstIndex(of: "\n") else {
      // A header alone still ends in a newline, so no newline means the command did not run
      // as written.
      return (nil, "")
    }
    let fields = output[output.startIndex..<newline]
      .split(separator: TranscriptCommands.fieldSeparator, omittingEmptySubsequences: false)
    guard fields.count == 2 else { return (nil, "") }
    let size = Int(trimmed(String(fields[0])))
    let header = Header(
      sizeInBytes: size,
      // Anything but `partial` is read as complete, so an unrecognised token does not put a
      // warning on every page of a good file.
      endsMidRecord: trimmed(String(fields[1])) == "partial"
    )
    return (header, String(output[output.index(after: newline)...]))
  }

  // MARK: - Plumbing

  /// Runs a command and insists it worked. Every host-side command exits 0 for any answer
  /// that is a result (no directory, no files, an empty file), so a non-zero exit is the
  /// channel or the shell failing.
  private func execute(_ command: String) async throws -> CommandResult {
    let result: CommandResult
    do {
      result = try await run(command)
    } catch let error as AppError {
      throw error
    } catch {
      throw AppError.channelFailed(reason: "Could not read the session file on this host.")
    }
    guard result.exitStatus == 0 else {
      let detail = trimmed(result.standardError)
      throw AppError.transcriptUnreadable(
        reason: detail.isEmpty ? "The host exited with \(result.exitStatus)." : detail
      )
    }
    return result
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = trimmed(value)
    return text.isEmpty ? nil : text
  }
}

private func trimmed(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}

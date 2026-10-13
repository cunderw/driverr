import DriverrCore
import Foundation
import Testing

@testable import DriverrTranscript

/// The round trip that asks a host what it has installed, and the parse of the answer. The
/// command is asserted by shape: four locations, the plugin filter and the bounds. The parse
/// covers every shape a real `SKILL.md` takes, including the folded `description: >-` block
/// most user skills use.
@Suite("Installed skills and commands")
struct SkillCatalogTests {
  // MARK: - The command

  @Test("all four locations are asked about in one command")
  func asksAboutEveryLocation() {
    let command = TranscriptCommands.skillsCommand(cwd: "/home/carson/dev/driverr")
    #expect(command.contains(#""$h"/.claude/skills/*/"#))
    #expect(command.contains(#""$c"/.claude/skills/*/"#))
    #expect(command.contains(#""$c"/.claude/commands/*.md"#))
    #expect(command.contains("installed_plugins.json"))
  }

  /// `Pane.directory` is optional, and `/.claude/skills/*/` would walk the filesystem root.
  @Test("a pane with no directory asks only about the user and plugin scopes")
  func degradesWithoutADirectory() {
    let command = TranscriptCommands.skillsCommand(cwd: nil)
    #expect(command.contains(#""$h"/.claude/skills/*/"#))
    #expect(!command.contains(".claude/commands"))
    #expect(!command.contains("$c"))
    #expect(command.contains("installed_plugins.json"))
  }

  @Test("the home directory is the host's own answer, not one built on the phone")
  func homeIsTheHostsAnswer() {
    #expect(TranscriptCommands.skillsCommand(cwd: nil).contains(#"h="$HOME""#))
  }

  /// A working directory reaches `/bin/sh` as a string; `shellQuoted` keeps it an argument.
  @Test("a working directory with a space in it is quoted")
  func quotesTheWorkingDirectory() {
    let command = TranscriptCommands.skillsCommand(cwd: "/home/carson/my projects/driverr")
    #expect(command.contains(#"c='/home/carson/my projects/driverr'"#))
  }

  /// The plugin cache keeps old version directories, so globbing it would offer commands from
  /// versions not installed.
  @Test("plugin skills are filtered by the installed-plugins manifest, not globbed")
  func plugsAreFilteredByTheManifest() {
    let command = TranscriptCommands.skillsCommand(cwd: nil)
    #expect(command.contains(#"grep -Eo '"installPath"[ ]*:[ ]*"[^"]*"'"#))
    #expect(!command.contains("plugins/cache"))
    // Plugins use more than one directory name for their skills.
    #expect(command.contains(#""$p"/*/*/SKILL.md"#))
  }

  /// A Windows-written `SKILL.md` opens with `---\r`, which reads as no frontmatter. The strip
  /// comes first because every later pattern tests `$0`.
  @Test("a carriage return is stripped before any line is tested")
  func stripsCarriageReturnsFirst() {
    let selector = TranscriptCommands.frontmatterSelector
    #expect(selector.hasPrefix(#"{sub(/\r$/,"")}"#))
  }

  /// Unquoted command substitution splits on `$IFS`, so a plugin path with a space would lose
  /// every skill.
  @Test("an install path with a space in it is not split into words")
  func setsIFSForThePluginLoop() {
    let command = TranscriptCommands.skillsCommand(cwd: nil)
    // `$(printf '\n')` is empty, because substitution strips trailing newlines; the sentinel
    // survives.
    #expect(command.contains(#"IFS=$(printf '\n_'); IFS=${IFS%_}"#))
    #expect(command.contains("o=$IFS"))
    #expect(command.contains("IFS=$o"), "the original IFS is put back")
  }

  @Test("nothing here needs more than POSIX")
  func staysPOSIX() {
    let command = TranscriptCommands.skillsCommand(cwd: "/home/carson/dev/driverr")
    for tool in ["jq", "python3", "find ", "xargs"] {
      #expect(!command.contains(tool), "\(tool) is not installed everywhere")
    }
  }

  /// Every answer is a result, including no `.claude` directory, so a non-zero exit means the
  /// channel or shell failed.
  @Test("the answer is bounded and the command always exits zero")
  func boundedAndAlwaysSucceeds() {
    let command = TranscriptCommands.skillsCommand(cwd: nil)
    #expect(command.contains("head -c \(TranscriptCommands.frontmatterBytes)"))
    #expect(command.hasSuffix("head -c \(TranscriptCommands.skillPayloadBytes)"))
    #expect(command.contains("\(TranscriptCommands.skillEntries)"))
  }

  // MARK: - The parse

  private func catalogue(_ lines: [String]) -> [SlashCommand] {
    let installed = Set(SlashCommandCatalog.builtIns.map(\.name))
    return TranscriptReader.catalog(from: lines.joined(separator: "\n") + "\n")
      .commands
      .filter { !installed.contains($0.name) }
  }

  @Test("a one-line description is read whole")
  func readsASingleLineDescription() {
    let found = catalogue([
      "!u\trun-tests",
      "+name: run-tests",
      "+description: Run the test suite and say what failed.",
    ])
    #expect(found.count == 1)
    #expect(found.first?.name == "/run-tests")
    #expect(found.first?.description == "Run the test suite and say what failed.")
    #expect(found.first?.source == .userSkill)
  }

  /// Most user skills fold their description over several lines, and the marker line carries
  /// none of the text.
  @Test("a folded description is joined across its indented lines")
  func readsAFoldedDescription() {
    let found = catalogue([
      "!u\tlint",
      "+name: lint",
      "+description: >-",
      "+  Run the formatter and the linter on the files this branch changed and print one line",
      "+  for each rule that failed. Stop at the first file that does not parse, and name it.",
      "+  Change nothing unless the caller passes the fix flag.",
      "+metadata:",
      "+  kind: build",
    ])
    #expect(
      found.first?.description == "Run the formatter and the linter on the files this branch "
        + "changed and print one line for each rule that failed. Stop at the first file that "
        + "does not parse, and name it. Change nothing unless the caller passes the fix flag."
    )
  }

  /// Without this, every later key, `metadata:` usually, reads as more description.
  @Test("a following key ends the folded block")
  func aFollowingKeyEndsTheBlock() {
    let found = catalogue([
      "!u\tmemo",
      "+description: >-",
      "+  Append one quick entry to the jot file.",
      "+allowed-tools: Read, Write",
    ])
    #expect(found.first?.description == "Append one quick entry to the jot file.")
  }

  /// Folded descriptions can contain colons.
  @Test("a colon inside a folded description does not end it")
  func aColonInProseIsNotAKey() {
    let found = catalogue([
      "!u\tmemo",
      "+description: >-",
      "+  Use for `/memo help`, and for this:",
      "+  jotting something down for later.",
    ])
    #expect(found.first?.description == "Use for `/memo help`, and for this: jotting something down for later.")
  }

  /// A `.claude/commands/*.md` is usually a markdown heading with no frontmatter.
  @Test("a command file with no frontmatter is offered with no description")
  func offersACommandWithNoDescription() {
    let found = catalogue([
      "!c\tanalyze",
      "!c\tpr-review",
    ])
    #expect(found.map(\.name) == ["/analyze", "/pr-review"])
    #expect(found.allSatisfy { $0.description == nil })
    #expect(found.allSatisfy { $0.source == .projectCommand })
  }

  /// Claude Code addresses a plugin's skill as `plugin:skill`.
  @Test("a plugin's skill keeps its namespace")
  func keepsThePluginNamespace() {
    let found = catalogue([
      "!g\tacme:sync-files",
      "+name: sync-files",
      "+description: Copy the build output to the shared folder.",
    ])
    #expect(found.first?.name == "/acme:sync-files")
    #expect(found.first?.source == .pluginSkill)
  }

  /// The payload is bounded on the host, so the last entry can be cut short.
  @Test("a truncated answer keeps the entries that did arrive")
  func survivesATruncatedAnswer() {
    let found = catalogue([
      "!u\tformat",
      "+description: Format the changed files.",
      "!u\tsummarize",
      "+description: >-",
      "+  Summarise the session for the next person and write it into",
    ])
    #expect(found.map(\.name) == ["/format", "/summarize"])
    #expect(found.last?.description == "Summarise the session for the next person and write it into")
  }

  /// `head -c` cuts on a byte. Half an entry line parses as a command that exists nowhere:
  /// `!u<TAB>lint` cut to `!u<TAB>lin` becomes `/lin`.
  @Test("a payload at the byte bound loses its last line, whatever it is")
  func dropsTheLastLineOfAFullPayload() {
    var lines = ["!u\tformat", "+description: Format the files."]
    // Pad to the bound, then cut on a byte as `head -c` does.
    while lines.joined(separator: "\n").utf8.count < TranscriptCommands.skillPayloadBytes {
      lines.append("!u\tskill-\(lines.count)")
      lines.append("+description: One of many.")
    }
    let whole = lines.joined(separator: "\n")
    let cut = String(decoding: whole.utf8.prefix(TranscriptCommands.skillPayloadBytes), as: UTF8.self)
    let lastWholeLine = cut.split(separator: "\n", omittingEmptySubsequences: false).dropLast().last

    let names = Set(TranscriptReader.catalog(from: cut).commands.map(\.name))

    #expect(names.contains("/format"), "everything before the cut still arrives")
    if let lastWholeLine, lastWholeLine.hasPrefix(TranscriptCommands.skillMark) {
      let survivor = "/" + lastWholeLine.split(separator: "\t").last!
      #expect(names.contains(String(survivor)), "the last whole entry line is kept")
    }
    // Nothing is offered under a name the answer never finished.
    #expect(!names.contains { $0.hasSuffix("-") || $0.count < 3 })
  }

  /// The rule above must not cost an entry on the ordinary path.
  @Test("a short answer keeps its last entry")
  func keepsTheLastLineOfAShortAnswer() {
    let found = catalogue(["!u\tformat", "+description: Format.", "!c\tanalyze"])
    #expect(found.map(\.name) == ["/analyze", "/format"])
  }

  /// Stray shell diagnostics must not become commands.
  @Test("an unrecognised line and an unknown scope are both dropped")
  func dropsWhatItCannotRead() {
    let found = catalogue([
      "sh: line 3: warning: something",
      "!z\tfrom-the-future",
      "+description: A scope this build has never heard of.",
      "!u\treal",
      "+description: This one is fine.",
    ])
    #expect(found.map(\.name) == ["/real"])
  }

  /// A host that answered nothing still runs `/clear` and `/compact`.
  @Test("the built-ins are there even when the host reported nothing")
  func alwaysCarriesTheBuiltIns() {
    let catalog = TranscriptReader.catalog(from: "")
    #expect(catalog.commands.contains { $0.name == "/clear" })
    #expect(catalog.commands.contains { $0.name == "/compact" })
    #expect(catalog.commands.allSatisfy { $0.source == .builtIn })
  }

  // MARK: - End to end, through the fake host

  @Test("the fake host's skills reach the reader as a catalogue")
  func readsTheFakeHost() async {
    let host = FakeTranscriptHost(
      sessionID: "s1",
      turns: [.init(speaker: .human, text: "hi", secondsAgo: 30)]
    ).offering([
      .init(
        name: "push",
        description: "Open a pull request for the finished branch and report its "
          + "address. Use whenever the work on a branch is complete.",
        isFolded: true
      ),
      .init(name: "analyze", scope: .command),
    ])
    let reader = TranscriptReader(run: host.run)

    let catalog = await reader.skills(cwd: "/home/carson/dev/driverr")

    let found = catalog.commands.filter { $0.source != .builtIn }
    #expect(found.map(\.name) == ["/analyze", "/push"])
    #expect(
      found.last?.description == "Open a pull request for the finished branch and report "
        + "its address. Use whenever the work on a branch is complete."
    )
  }

  /// `FakeTranscriptHost.run` answers 127 for commands it was not built for, so a throwing
  /// `skills(cwd:)` would fail every older fixture the first time a composer asked.
  @Test("a host that cannot answer gives the built-ins, not an error")
  func aRefusalIsNotAnError() async {
    let reader = TranscriptReader(run: { _ in
      CommandResult(standardOutput: "", standardError: "sh: not found\n", exitStatus: 127)
    })
    #expect(await reader.skills(cwd: nil) == .builtInsOnly)
  }

  @Test("a channel that threw gives the built-ins too")
  func aThrownErrorIsNotAnError() async {
    let reader = TranscriptReader(run: { _ in
      throw AppError.channelFailed(reason: "gone")
    })
    #expect(await reader.skills(cwd: nil) == .builtInsOnly)
  }
}

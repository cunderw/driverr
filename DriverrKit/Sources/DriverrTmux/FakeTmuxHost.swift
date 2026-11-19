#if DEBUG
import DriverrCore
import Foundation

/// A host with a tmux server in it and no machine behind it.
///
/// It is a `CommandRunner`, not a `HerdrControl`: it answers the shell commands `TmuxControl`
/// sends, so every command string and every parse runs. It reads each command the way the
/// remote side would, which is two readings. A small shell splits the line into words and runs
/// `tmux`, `ps`, `printf`, `cat` and `sh -c`, honouring quotes, `&&`, `;` and `\;`. Then `tmux`
/// splits its own argument list at `;`, with its rule for an argument that ends in one.
///
/// So a command that only looks right fails here: an unquoted `$1`, or typed text that ends in
/// `;`, comes out as something other than what was typed. Real tmux 3.7c is what the rule was
/// measured against, and `LiveTmuxProbeTests` is the opt-in run against it.
///
/// **Everything it was asked is recorded, refusals included**: `commands` for every line, and
/// `input` for what reached each pane. Deterministic: no clock, random number or environment.
public actor FakeTmuxHost {
  public struct Pane: Sendable, Equatable {
    public var id: Int
    public var title: String
    public var command: String
    public var path: String
    public var width: Int
    public var height: Int
    /// What `capture-pane` prints, one string per row.
    public var screen: [String]
    public var isActive: Bool

    public init(
      id: Int,
      title: String = "",
      command: String = "zsh",
      path: String = "/home/dev",
      width: Int = 80,
      height: Int = 24,
      screen: [String] = [],
      isActive: Bool = false
    ) {
      self.id = id
      self.title = title
      self.command = command
      self.path = path
      self.width = width
      self.height = height
      self.screen = screen
      self.isActive = isActive
    }

    /// tmux's pane tty, which `ps` prints without `/dev/`.
    public var tty: String { "/dev/ttys\(100 + id)" }
  }

  public struct Window: Sendable, Equatable {
    public var id: Int
    public var index: Int
    public var name: String
    public var isAutoNamed: Bool
    public var isActive: Bool
    public var panes: [Pane]

    public init(
      id: Int, index: Int, name: String, isAutoNamed: Bool = true, isActive: Bool = false,
      panes: [Pane]
    ) {
      self.id = id
      self.index = index
      self.name = name
      self.isAutoNamed = isAutoNamed
      self.isActive = isActive
      self.panes = panes
    }
  }

  public struct Session: Sendable, Equatable {
    public var id: Int
    public var name: String
    public var attached: Int
    public var activity: Int
    public var windows: [Window]

    public init(id: Int, name: String, attached: Int = 0, activity: Int = 0, windows: [Window]) {
      self.id = id
      self.name = name
      self.attached = attached
      self.activity = activity
      self.windows = windows
    }
  }

  /// One row of the host's process table, as `ps -A -o pid=,pgid=,tpgid=,tty=,comm=` prints it.
  public struct Process: Sendable, Equatable {
    public var pid: Int
    public var groupID: Int
    public var foregroundGroupID: Int
    /// As `ps` prints it, with no `/dev/`.
    public var tty: String
    public var command: String

    public init(pid: Int, groupID: Int? = nil, foregroundGroupID: Int? = nil, tty: String, command: String) {
      self.pid = pid
      self.groupID = groupID ?? pid
      self.foregroundGroupID = foregroundGroupID ?? pid
      self.tty = tty
      self.command = command
    }
  }

  /// What reached a pane.
  public enum Input: Sendable, Equatable {
    /// Literal text, from `send-keys -l`.
    case text(String)
    /// A key by tmux's name, from `send-keys`.
    case key(String)
  }

  public static let hostName = "fake-host.local"

  /// Claude Code's configuration directory, as a POSIX shell spells it.
  static let recordDirectory = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

  public private(set) var sessions: [Session]
  public private(set) var processes: [Process]
  /// `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json`, by pid. A pid with no entry has
  /// no file.
  public private(set) var records: [Int: String]
  /// What `tmux -V` prints. `nil` is a host with no tmux, and every command says so.
  public var version: String?
  /// Every command line this host was given, in order.
  public private(set) var commands: [String] = []
  /// What typed into each pane, by tmux's id (`%3`).
  public private(set) var input: [String: [Input]] = [:]
  private var nextPane: Int
  private var nextWindow: Int
  private var nextSession: Int

  public init(
    sessions: [Session] = [],
    processes: [Process] = [],
    records: [Int: String] = [:],
    version: String? = "tmux 3.7c"
  ) {
    self.sessions = sessions
    self.processes = processes
    self.records = records
    self.version = version
    nextPane = (sessions.flatMap(\.windows).flatMap(\.panes).map(\.id).max() ?? -1) + 1
    nextWindow = (sessions.flatMap(\.windows).map(\.id).max() ?? -1) + 1
    nextSession = (sessions.map(\.id).max() ?? -1) + 1
  }

  public nonisolated var runner: CommandRunner {
    { [self] command in await self.handle(command) }
  }

  public func setSessions(_ sessions: [Session]) { self.sessions = sessions }
  public func setProcesses(_ processes: [Process]) { self.processes = processes }
  /// Writes, or with `nil` deletes, Claude Code's record for a pid.
  public func setRecord(pid: Int, _ text: String?) { records[pid] = text }

  /// What `capture-pane` prints for a pane, by its number.
  public func setScreen(of paneID: Int, _ rows: [String]) {
    for s in sessions.indices {
      for w in sessions[s].windows.indices {
        for p in sessions[s].windows[w].panes.indices where sessions[s].windows[w].panes[p].id == paneID {
          sessions[s].windows[w].panes[p].screen = rows
        }
      }
    }
  }

  /// What `#{pane_title}` prints for a pane, by its number, as a program's OSC title sets it.
  public func setTitle(of paneID: Int, _ title: String) {
    for s in sessions.indices {
      for w in sessions[s].windows.indices {
        for p in sessions[s].windows[w].panes.indices where sessions[s].windows[w].panes[p].id == paneID {
          sessions[s].windows[w].panes[p].title = title
        }
      }
    }
  }

  /// Claude Code's record, as the file holds it.
  public static func claudeRecord(
    pid: Int, sessionID: String, status: String, waitingFor: String? = nil,
    directory: String = "/home/dev"
  ) -> String {
    var fields = [
      #""pid":\#(pid)"#, #""sessionId":"\#(sessionID)""#, #""cwd":"\#(directory)""#,
      #""status":"\#(status)""#,
    ]
    if let waitingFor { fields.append(#""waitingFor":"\#(waitingFor)""#) }
    return "{" + fields.joined(separator: ",") + "}"
  }

  /// Two sessions, one with a Claude waiting on a permission prompt, as the seed for tests.
  public static func seeded() -> FakeTmuxHost {
    let work = Session(
      id: 0, name: "work", attached: 1, activity: 200,
      windows: [
        Window(
          id: 0, index: 0, name: "editor", isActive: true,
          panes: [
            Pane(id: 0, command: "zsh", path: "/home/dev/driverr", isActive: true),
            Pane(
              id: 1, title: "✳ Claude Code", command: "2.1.325", path: "/home/dev/driverr",
              screen: ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]),
          ]),
        Window(id: 1, index: 1, name: "logs", panes: [Pane(id: 2, command: "tail", isActive: true)]),
      ])
    let scratch = Session(
      id: 1, name: "scratch", activity: 100,
      windows: [
        Window(id: 2, index: 0, name: "zsh", isActive: true, panes: [Pane(id: 3, isActive: true)])
      ])
    return FakeTmuxHost(
      sessions: [work, scratch],
      processes: [
        Process(pid: 5001, tty: "ttys100", command: "zsh"),
        Process(pid: 5002, tty: "ttys101", command: "claude"),
        Process(pid: 5003, groupID: 5002, foregroundGroupID: 5002, tty: "ttys101", command: "node"),
        Process(pid: 5004, tty: "ttys102", command: "tail"),
        Process(pid: 5005, tty: "ttys103", command: "zsh"),
      ],
      records: [
        5002: claudeRecord(
          pid: 5002, sessionID: "11111111-2222-3333-4444-555555555555", status: "waiting",
          waitingFor: "permission prompt")
      ]
    )
  }

  // MARK: The remote shell

  private enum Token: Equatable {
    /// A word, after the shell removed its quotes.
    case word(String)
    /// An unquoted `;` or `&&`.
    case op(String)
  }

  private func handle(_ line: String) -> CommandResult {
    commands.append(line)
    return execute(line, insideShell: false)
  }

  /// One line, run. `insideShell` is a script `sh -c` was given, where POSIX syntax is safe. The
  /// line itself goes to the login shell, which may be fish.
  private func execute(_ line: String, insideShell: Bool) -> CommandResult {
    var stdout = ""
    var stderr = ""
    var status = 0
    var skipping = false
    var pending: [String] = []
    var operatorBefore: String?

    func flush() {
      defer { pending = [] }
      guard !pending.isEmpty else { return }
      if skipping, operatorBefore == "&&" { return }
      let result = simpleCommand(pending, insideShell: insideShell)
      stdout += result.standardOutput
      stderr += result.standardError
      status = result.exitStatus
      skipping = result.exitStatus != 0
    }

    for token in Self.tokens(of: line) {
      switch token {
      case .word(let word): pending.append(word)
      case .op(let op):
        flush()
        operatorBefore = op
      }
    }
    flush()
    return CommandResult(standardOutput: stdout, standardError: stderr, exitStatus: status)
  }

  /// A line as a POSIX shell reads it, as far as these commands go: single and double quotes,
  /// a backslash, `;` and `&&`. A backslash outside quotes makes the next character a plain
  /// one, so `\;` is a word.
  private static func tokens(of line: String) -> [Token] {
    var tokens: [Token] = []
    var word = ""
    var inWord = false
    var chars = Array(line)[...]

    func end() {
      if inWord { tokens.append(.word(word)) }
      word = ""
      inWord = false
    }

    while let char = chars.popFirst() {
      switch char {
      case "'":
        inWord = true
        while let next = chars.popFirst(), next != "'" { word.append(next) }
      case "\"":
        inWord = true
        while let next = chars.popFirst(), next != "\"" {
          if next == "\\", let escaped = chars.first, "\"\\$`".contains(escaped) {
            word.append(chars.removeFirst())
          } else {
            word.append(next)
          }
        }
      case "\\":
        inWord = true
        if let next = chars.popFirst() { word.append(next) }
      case " ", "\t":
        end()
      case ";", "\n":
        end()
        tokens.append(.op(";"))
      case "&" where chars.first == "&":
        chars.removeFirst()
        end()
        tokens.append(.op("&&"))
      default:
        inWord = true
        word.append(char)
      }
    }
    end()
    return tokens
  }

  private func simpleCommand(_ words: [String], insideShell: Bool) -> CommandResult {
    let name = words[0].split(separator: "/").last.map(String.init) ?? words[0]
    switch name {
    case "tmux":
      guard let version else { return Self.failure("sh: tmux: command not found", status: 127) }
      return tmux(Array(words.dropFirst()), version: version)
    case "ps":
      let table = processes.map {
        "\($0.pid) \($0.groupID) \($0.foregroundGroupID) \($0.tty) \($0.command)\n"
      }
      return Self.success(table.joined())
    case "printf":
      guard words.count == 3 else { return Self.failure("printf: usage", status: 1) }
      let text = words[1].replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "%s", with: words[2])
      return Self.success(text)
    case "cat":
      return cat(words, insideShell: insideShell)
    case "sh":
      guard words.count == 3, words[1] == "-c" else { return Self.failure("sh: usage", status: 2) }
      return execute(words[2], insideShell: true)
    default:
      return Self.failure("sh: \(name): command not found", status: 127)
    }
  }

  /// Only `cat` of a record in Claude Code's configuration directory,
  /// `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json`, as `sh -c` reads it. The
  /// expression reaches here unexpanded, which is fine: the fake knows whose directory it is.
  ///
  /// A path under `$HOME/.claude` alone reads nothing, because it ignores `CLAUDE_CONFIG_DIR`.
  /// The expression outside `sh -c` fails, because a login shell that is fish cannot read it.
  private func cat(_ words: [String], insideShell: Bool) -> CommandResult {
    guard let path = words.dropFirst().first(where: { $0.hasSuffix(".json") }),
      let file = path.split(separator: "/").last,
      let pid = Int(file.dropLast(".json".count)),
      path == Self.recordDirectory + "/sessions/\(pid).json"
    else { return Self.failure("cat: not a file this host has", status: 1) }
    guard insideShell else {
      return Self.failure("fish: ${ is not a valid variable in fish", status: 127)
    }
    guard let text = records[pid] else {
      return Self.failure("cat: \(path): No such file or directory", status: 1)
    }
    return Self.success(text + "\n")
  }

  // MARK: tmux

  /// **Without `-u` it behaves as tmux does under no locale**: every control character and every
  /// non-ASCII character in a *formatted* answer (`-F`) comes back as `_`. Measured on tmux 3.7c
  /// with an empty environment, which is what an SSH exec channel may give it. A command that
  /// forgets `-u` then reads nothing, as it did on the real server. Pane text from
  /// `capture-pane` is raw either way, as it was there.
  private func tmux(_ argv: [String], version: String) -> CommandResult {
    var argv = argv[...]
    utf8 = false
    if argv.first == "-u" {
      utf8 = true
      argv.removeFirst()
    }
    if Array(argv) == ["-V"] { return Self.success(version + "\n") }

    var output = ""
    for command in Self.commands(in: Array(argv)) {
      let result = tmuxCommand(command)
      guard result.exitStatus == 0 else { return result }
      output += result.standardOutput
    }
    return Self.success(output)
  }

  /// Whether the command being run was given `-u`.
  private var utf8 = false

  /// What tmux prints without `-u` in a locale that is not UTF-8.
  private static func asciiOnly(_ output: String) -> String {
    String(
      output.unicodeScalars.map { scalar -> Character in
        scalar == "\n" || (scalar.isASCII && scalar.value >= 0x20) ? Character(scalar) : "_"
      })
  }

  /// tmux's own reading of an argument list, `cmd_parse_from_arguments`.
  ///
  /// An argument that is `;` ends a command. One that ends in `;` ends it too, and keeps the
  /// text before the `;`, unless a backslash comes before the `;`, which becomes a plain `;`
  /// that the argument keeps. Measured against tmux 3.7c.
  static func commands(in argv: [String]) -> [[String]] {
    var commands: [[String]] = [[]]
    for argument in argv {
      guard argument.hasSuffix(";") else {
        commands[commands.count - 1].append(argument)
        continue
      }
      var kept = String(argument.dropLast())
      if kept.hasSuffix("\\") {
        kept.removeLast()
        commands[commands.count - 1].append(kept + ";")
      } else {
        if !kept.isEmpty { commands[commands.count - 1].append(kept) }
        commands.append([])
      }
    }
    return commands.filter { !$0.isEmpty }
  }

  private func tmuxCommand(_ command: [String]) -> CommandResult {
    var flags = Flags(Array(command.dropFirst()))
    if let bad = flags.unknown.first { return Self.failure("unknown flag \(bad)", status: 1) }
    switch command[0] {
    case "list-panes":
      return listPanes(&flags)
    case "send-keys":
      return sendKeys(&flags)
    case "capture-pane":
      guard let location = target(flags.value("-t")) else { return Self.noPane(flags.value("-t")) }
      let pane = sessions[location.session].windows[location.window].panes[location.pane]
      return Self.success(pane.screen.map { $0 + "\n" }.joined())
    case "split-window":
      return split(&flags)
    case "kill-pane":
      return kill(&flags)
    case "select-pane":
      guard let location = target(flags.value("-t")) else { return Self.noPane(flags.value("-t")) }
      if let title = flags.value("-T") {
        let session = sessions[location.session]
        let window = session.windows[location.window]
        let expanded = expand(title, session: session, window: window, pane: window.panes[location.pane], printed: false)
        // Measured on 3.7c: a title with a control character, a newline or a tab, exits 0 and
        // changes nothing.
        if !expanded.contains(where: Self.isControl) {
          sessions[location.session].windows[location.window].panes[location.pane].title = expanded
        }
      }
      return Self.success("")
    case "rename-session":
      guard let index = sessionIndex(flags.value("-t")), let name = flags.positional.first else {
        return Self.failure("can't find session", status: 1)
      }
      let session = sessions[index]
      let window = session.windows.first(where: \.isActive) ?? session.windows[0]
      let expanded = expand(name, session: session, window: window, pane: window.panes[0], printed: false)
      guard !expanded.contains(where: Self.isControl) else {
        return Self.failure("invalid session name: \(expanded)", status: 1)
      }
      sessions[index].name = expanded
      return Self.success("")
    case "rename-window":
      guard let location = windowLocation(flags.value("-t")), let name = flags.positional.first
      else { return Self.failure("can't find window", status: 1) }
      let session = sessions[location.session]
      let window = session.windows[location.window]
      let expanded = expand(name, session: session, window: window, pane: window.panes[0], printed: false)
      guard !expanded.contains(where: Self.isControl) else {
        return Self.failure("invalid window name: \(expanded)", status: 1)
      }
      sessions[location.session].windows[location.window].name = expanded
      sessions[location.session].windows[location.window].isAutoNamed = false
      return Self.success("")
    case "copy-mode":
      // Only `-q`, which leaves any mode. No pane here is ever in one.
      guard flags.has("-q") else { return Self.failure("unknown command: copy-mode", status: 1) }
      guard target(flags.value("-t")) != nil else { return Self.noPane(flags.value("-t")) }
      return Self.success("")
    case "new-window":
      return newWindow(&flags)
    case "new-session":
      return newSession(&flags)
    default:
      return Self.failure("unknown command: \(command[0])", status: 1)
    }
  }

  /// A command's flags, by what the commands here take.
  private struct Flags {
    private(set) var values: [String: String] = [:]
    private(set) var switches: Set<String> = []
    private(set) var positional: [String] = []
    /// Flags tmux would refuse as `unknown flag`: a dash and something, before any `--`, that
    /// no command here takes. This is what a label that starts with `-` becomes without `--`.
    private(set) var unknown: [String] = []

    private static let known: Set<String> = ["-a", "-d", "-h", "-v", "-P", "-l", "-H", "-e", "-p", "-q"]
    private static let withValue: Set<String> = ["-t", "-F", "-c", "-T", "-s", "-n", "-f"]

    init(_ arguments: [String]) {
      var rest = arguments[...]
      var parsing = true
      while let argument = rest.popFirst() {
        if parsing, argument == "--" {
          parsing = false
        } else if parsing, Self.withValue.contains(argument), let value = rest.popFirst() {
          values[argument] = value
        } else if parsing, Self.known.contains(argument) {
          switches.insert(argument)
        } else if parsing, argument.hasPrefix("-"), argument.count >= 2 {
          unknown.append(argument)
        } else {
          positional.append(argument)
        }
      }
    }

    func value(_ flag: String) -> String? { values[flag] }
    func has(_ flag: String) -> Bool { switches.contains(flag) }
  }

  private struct Location {
    let session: Int
    let window: Int
    let pane: Int
  }

  private func target(_ id: String?) -> Location? {
    guard let id, id.first == "%", let number = Int(id.dropFirst()) else { return nil }
    for (s, session) in sessions.enumerated() {
      for (w, window) in session.windows.enumerated() {
        if let p = window.panes.firstIndex(where: { $0.id == number }) {
          return Location(session: s, window: w, pane: p)
        }
      }
    }
    return nil
  }

  private func windowLocation(_ id: String?) -> (session: Int, window: Int)? {
    guard let id, id.first == "@", let number = Int(id.dropFirst()) else { return nil }
    for (s, session) in sessions.enumerated() {
      if let w = session.windows.firstIndex(where: { $0.id == number }) { return (s, w) }
    }
    return nil
  }

  private func sessionIndex(_ id: String?) -> Int? {
    guard let id, id.first == "$", let number = Int(id.dropFirst()) else { return nil }
    return sessions.firstIndex { $0.id == number }
  }

  private static func noPane(_ id: String?) -> CommandResult {
    failure("can't find pane: \(id ?? "")", status: 1)
  }

  private func noServer() -> CommandResult {
    Self.failure("no server running on /tmp/tmux-1000/default", status: 1)
  }

  private func listPanes(_ flags: inout Flags) -> CommandResult {
    guard !sessions.isEmpty else { return noServer() }
    let format = flags.value("-F") ?? "#{pane_id}"
    var lines = ""
    for session in sessions {
      for window in session.windows {
        for pane in window.panes {
          lines += expand(format, session: session, window: window, pane: pane) + "\n"
        }
      }
    }
    return Self.success(lines)
  }

  /// A format as tmux expands it: `##` is `#`, `#S`, `#W` and `#T` are the session, window and
  /// pane title, `#{name}` is a variable, and `#(…)` runs a command, which the fake models as
  /// consuming its text and printing nothing. Another `#x` is left as it is. A variable it does
  /// not know is empty, which is what tmux does, so a misspelt one shows as an empty field.
  ///
  /// `printed` is for an answer tmux prints, as `-F` does, and not for text it stores: an answer
  /// is ASCII-only without `-u`.
  private func expand(
    _ format: String, session: Session, window: Window, pane: Pane, printed: Bool = true
  ) -> String {
    let title = pane.title.isEmpty ? Self.hostName : pane.title
    let values: [String: String] = [
      "pane_id": "%\(pane.id)",
      "window_id": "@\(window.id)",
      "session_id": "$\(session.id)",
      "session_name": session.name,
      "session_attached": String(session.attached),
      "session_activity": String(session.activity),
      "window_index": String(window.index),
      "window_name": window.name,
      "automatic-rename": window.isAutoNamed ? "1" : "0",
      "window_active": window.isActive ? "1" : "0",
      "pane_active": pane.isActive ? "1" : "0",
      "pane_tty": pane.tty,
      "pane_width": String(pane.width),
      "pane_height": String(pane.height),
      // tmux's default title is the host's name.
      "pane_title": title,
      "host": Self.hostName,
      "host_short": String(Self.hostName.split(separator: ".").first ?? ""),
      "pane_current_command": pane.command,
      "pane_current_path": pane.path,
    ]
    let chars = Array(format)
    var out = ""
    var i = 0
    while i < chars.count {
      guard chars[i] == "#", i + 1 < chars.count else {
        out.append(chars[i])
        i += 1
        continue
      }
      switch chars[i + 1] {
      case "#": out += "#"; i += 2
      case "S": out += session.name; i += 2
      case "W": out += window.name; i += 2
      case "T": out += title; i += 2
      case "{", "(":
        let close: Character = chars[i + 1] == "{" ? "}" : ")"
        guard let end = chars[(i + 2)...].firstIndex(of: close) else {
          out += String(chars[i...])
          i = chars.count
          continue
        }
        if close == "}" { out += values[String(chars[(i + 2)..<end])] ?? "" }
        i = end + 1
      default:
        out.append("#")
        i += 1
      }
    }
    return printed && !utf8 ? Self.asciiOnly(out) : out
  }

  private func sendKeys(_ flags: inout Flags) -> CommandResult {
    guard let location = target(flags.value("-t")) else { return Self.noPane(flags.value("-t")) }
    let id = "%\(sessions[location.session].windows[location.window].panes[location.pane].id)"
    if flags.has("-l") {
      input[id, default: []].append(.text(flags.positional.joined()))
    } else {
      for name in flags.positional { input[id, default: []].append(.key(name)) }
    }
    return Self.success("")
  }

  private func split(_ flags: inout Flags) -> CommandResult {
    guard let location = target(flags.value("-t")) else { return Self.noPane(flags.value("-t")) }
    let origin = sessions[location.session].windows[location.window].panes[location.pane]
    // `-c` is a format. `#{pane_current_path}` is the origin's path.
    let path = flags.value("-c") == "#{pane_current_path}" ? origin.path : (flags.value("-c") ?? origin.path)
    let pane = Pane(id: nextPane, path: path, width: origin.width / 2, height: origin.height)
    nextPane += 1
    sessions[location.session].windows[location.window].panes.insert(pane, at: location.pane + 1)
    return Self.success("")
  }

  private func kill(_ flags: inout Flags) -> CommandResult {
    guard let location = target(flags.value("-t")) else { return Self.noPane(flags.value("-t")) }
    sessions[location.session].windows[location.window].panes.remove(at: location.pane)
    if sessions[location.session].windows[location.window].panes.isEmpty {
      sessions[location.session].windows.remove(at: location.window)
    }
    if sessions[location.session].windows.isEmpty { sessions.remove(at: location.session) }
    return Self.success("")
  }

  private func newWindow(_ flags: inout Flags) -> CommandResult {
    guard
      let index = sessions.indices.max(by: { sessions[$0].activity < sessions[$1].activity })
    else { return noServer() }
    let pane = Self.newPane(id: nextPane, flags)
    nextPane += 1
    let window = Window(
      id: nextWindow, index: (sessions[index].windows.map(\.index).max() ?? -1) + 1,
      name: flags.value("-n") ?? "zsh", isAutoNamed: flags.value("-n") == nil, panes: [pane])
    nextWindow += 1
    sessions[index].windows.append(window)
    return Self.success(flags.has("-P") ? expand(flags.value("-F") ?? "", session: sessions[index], window: window, pane: pane) + "\n" : "")
  }

  private func newSession(_ flags: inout Flags) -> CommandResult {
    let pane = Self.newPane(id: nextPane, flags)
    nextPane += 1
    let window = Window(
      id: nextWindow, index: 0, name: flags.value("-n") ?? "zsh",
      isAutoNamed: flags.value("-n") == nil, isActive: true, panes: [pane])
    nextWindow += 1
    let session = Session(id: nextSession, name: String(nextSession), windows: [window])
    nextSession += 1
    sessions.append(session)
    return Self.success(flags.has("-P") ? expand(flags.value("-F") ?? "", session: session, window: window, pane: pane) + "\n" : "")
  }

  /// A new window's pane, in the folder `-c` names. tmux expands a format in `-c`, and `##` is
  /// its only way to a `#`. Any other `#` is a format this fake does not expand, so the pane
  /// lands in the home folder, as tmux's does when the expansion names no folder.
  private static func newPane(id: Int, _ flags: Flags) -> Pane {
    guard let folder = flags.value("-c") else { return Pane(id: id, isActive: true) }
    let unescaped = folder.replacingOccurrences(of: "##", with: "")
    guard !unescaped.contains("#") else { return Pane(id: id, isActive: true) }
    return Pane(id: id, path: folder.replacingOccurrences(of: "##", with: "#"), isActive: true)
  }

  private static func isControl(_ character: Character) -> Bool {
    character.isNewline
      || character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }

  private static func success(_ output: String) -> CommandResult {
    CommandResult(standardOutput: output, standardError: "", exitStatus: 0)
  }

  private static func failure(_ message: String, status: Int) -> CommandResult {
    CommandResult(standardOutput: "", standardError: message + "\n", exitStatus: status)
  }
}
#endif

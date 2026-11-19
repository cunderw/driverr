import DriverrCore
import Foundation

/// How a value becomes one argument of a tmux command that crosses a remote shell.
///
/// Two layers, and each needs its own protection:
///
/// - **The remote shell** reads the command string. `shellQuoted` makes a value one literal
///   word, so a quote, a `$(…)` or a newline in typed text is data.
/// - **tmux** then reads its own argument list. An argument that ends in `;` is a command
///   separator to tmux, and the text before it is kept, so typed `ls;` would send `ls` and
///   open a second, empty command. tmux's escape is `\;`, which it turns back into `;`.
///   Measured against tmux 3.7c: `foo;` types `foo`, and `foo\;` types `foo;`.
enum TmuxArgument {
  /// `value` as tmux must be given it to read `value` back.
  ///
  /// Only the final `;` is escaped, because only a trailing one means anything. tmux strips
  /// the `;`, and replaces the backslash before it, if there is one, with `;`. So a value
  /// that ends in a backslash and a `;` goes with two backslashes and a `;`, and still reads
  /// back as it was.
  static func escaped(_ value: String) -> String {
    guard value.hasSuffix(";") else { return value }
    return String(value.dropLast()) + #"\;"#
  }

  /// One shell word that reaches tmux as `value`.
  static func quoted(_ value: String) -> String {
    shellQuoted(escaped(value))
  }

  /// A name or title that tmux stores, as the one line and the literal text it must be given.
  ///
  /// `rename-session`, `rename-window` and `select-pane -T` run their text through tmux's format
  /// expansion: `format_single_from_target` in `cmd-rename-session.c`, `cmd-rename-window.c` and
  /// `cmd-select-pane.c`, the same calls in the 3.2 tag, which is the floor. So `#S`,
  /// `#{pane_id}` and `#(…)` are consumed, and `##` is the only way to a `#`. Every `#` is
  /// doubled. `send-keys -l` does no expansion, so typed text never goes through this.
  ///
  /// A control character is a space. A newline or a tab makes `select-pane -T` exit 0 and
  /// change nothing, and the two renames refuse it with `invalid … name`. Measured on 3.7c for
  /// the whole range below 0x20, and DEL is treated the same way here.
  static func label(_ value: String) -> String {
    let oneLine = String(value.map { $0.isControl ? " " : $0 })
    return quoted(oneLine.replacingOccurrences(of: "#", with: "##"))
  }

  /// Between two tmux commands in one invocation. The shell turns `\;` into a bare `;`, which
  /// tmux reads as a separator.
  static let separator = #" \; "#
}

/// Every tmux command line Driverr sends, as a string a remote `/bin/sh` runs.
///
/// Static and pure, so a test asserts the whole string. `binary` is `shellQuoted(binaryPath)`.
/// A pane, window or session id arrives already shell-quoted, as `shellQuoted(TmuxID.raw(of:))`:
/// `$1` unquoted is the shell's first parameter, and `%3` is a job in some shells. `input` and
/// `keys` are the exception: they take the raw pane id, checked by `TmuxID.rawPane(of:)`,
/// because it also goes inside a tmux command. See `leaveModes(pane:)`.
enum TmuxCommands {
  /// Every pane, then every client, in one call. The clients are for `TmuxMirrors`: a tmux
  /// client running in a herdr pane makes that pane a mirror.
  static func listPanes(binary: String) -> String {
    "\(binary) list-panes -a -F \(shellQuoted(TmuxPaneFormat.format))"
      + TmuxArgument.separator + "list-clients -F \(shellQuoted(TmuxClientFormat.format))"
  }

  /// Types `text` into a pane, and then Enter when `submit`. `nil` when there is nothing to
  /// send. `pane` is the raw id, `%3`. Any mode the pane is in is left first, in the same
  /// invocation. See `leaveModes(pane:)`.
  ///
  /// **`-l`, so every character is literal.** Without it tmux reads `Enter`, `C-c` and `Up` in
  /// typed text as key names. **`--`, so text that starts with `-` is not a flag.**
  ///
  /// A submit is one invocation, `send-keys -l … \; send-keys Enter`, because a failure
  /// between two would leave a half-typed answer in the pane. Claude Code reads a line feed
  /// as a line break and Enter as submit, so the text goes as typed and Enter follows.
  static func input(binary: String, pane: String, text: String, submit: Bool) -> String? {
    let quoted = shellQuoted(pane)
    var commands: [String] = []
    if !text.isEmpty {
      commands.append("send-keys -t \(quoted) -l -- \(TmuxArgument.quoted(text))")
    }
    if submit { commands.append("send-keys -t \(quoted) Enter") }
    guard !commands.isEmpty else { return nil }
    return "\(binary) " + ([leaveModes(pane: pane)] + commands).joined(separator: TmuxArgument.separator)
  }

  /// Takes the pane out of any mode it is in, and runs nothing for a pane in none. A tmux
  /// command, for the front of an invocation. `pane` is the raw id, `%3`.
  ///
  /// **A pane in a mode never gets the text.** Copy mode and view mode read typed text as the
  /// mode's keys, measured on 3.7c and 3.2a: `send-keys -l` exits 0 and nothing reaches the
  /// program. A pane is in one when the desk scrolls, or when `run-shell` or a server's start-up
  /// configuration prints something. Driverr leaves it before every send, so a desk scrolling
  /// that pane loses its place. The owner chose that cost on #128.
  ///
  /// **`copy-mode -q`, not `send-keys -X cancel`.** `-q` leaves copy, view and tree mode, on 3.7c
  /// and 3.2a. `cancel` leaves only copy and view mode, and fails with `not in a mode` on a pane
  /// in none, which would stop the send behind it.
  ///
  /// **`if-shell -F` on `#{pane_in_mode}`**, so only a pane in a mode runs `copy-mode`, in the same
  /// invocation and with no read first. The inner command needs its own `-t`: without one it
  /// fails with `no current client`, measured on both. The raw id is safe inside the quotes,
  /// because `TmuxID` admits only `%` and digits.
  static func leaveModes(pane: String) -> String {
    "if-shell -F -t \(shellQuoted(pane)) '#{pane_in_mode}' \(shellQuoted("copy-mode -q -t \(pane)"))"
  }

  /// A reply as it goes over: trailing newlines and spaces trimmed, everything else as typed.
  /// The same rule as `CLIControl.submittable`, for the same reason: Enter submits the whole
  /// message, so a trailing newline would only add a stray blank line.
  static func submittable(_ text: String) -> String {
    var text = Substring(text)
    while let last = text.last, last.isNewline || last == " " || last == "\t" {
      text = text.dropLast()
    }
    return String(text)
  }

  /// tmux's name for a key, and whether it is a name or a character to type.
  static func key(_ key: PaneKey) -> (name: String, isLiteral: Bool) {
    switch key {
    case .enter: ("Enter", false)
    case .esc: ("Escape", false)
    case .up: ("Up", false)
    case .down: ("Down", false)
    case .left: ("Left", false)
    case .right: ("Right", false)
    case .tab: ("Tab", false)
    case .backTab: ("BTab", false)
    case .interrupt: ("C-c", false)
    case .yes, .no, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8,
      .digit9:
      (key.rawValue, true)
    }
  }

  /// One tmux call per key, chained in one exec. `pane` is the raw id, `%3`.
  ///
  /// Two keys in one `send-keys` arrive as one burst, and Claude Code's picker drops both.
  /// Separate processes are spaced by their own start-up. `&&` stops at the first refusal.
  /// The first call leaves any mode the pane is in, which is enough for the rest.
  static func keys(binary: String, pane: String, keys: [PaneKey]) -> String? {
    guard !keys.isEmpty else { return nil }
    let quoted = shellQuoted(pane)
    return keys.enumerated().map { index, pressed in
      let (name, isLiteral) = key(pressed)
      let send =
        isLiteral
        ? "send-keys -t \(quoted) -l -- \(shellQuoted(name))"
        : "send-keys -t \(quoted) \(shellQuoted(name))"
      return index == 0
        ? "\(binary) \(leaveModes(pane: pane))\(TmuxArgument.separator)\(send)"
        : "\(binary) \(send)"
    }
    .joined(separator: " && ")
  }

  /// What separates one pane's rows from the next in a batched read. It carries the pane id,
  /// because pane output is arbitrary: a bare marker in a pane's text would shift every later
  /// pane onto the wrong tile.
  static let paneMarker = "__DRIVERR_PANE__"

  /// One command that reads every pane's visible screen, a boundary printed before each.
  ///
  /// A pane that is gone makes tmux print `can't find pane` and nothing else, which reads as
  /// an empty pane, and the batch goes on. `readPanes` is the one that tells a refused batch
  /// from one closed pane.
  static func readPanes(binary: String, panes: [(id: String, quoted: String)]) -> String {
    panes.map { id, quoted in
      #"printf '\n%s\n' "# + shellQuoted("\(paneMarker) \(id)") + "; "
        + "\(binary) capture-pane -p -t \(quoted)"
    }
    .joined(separator: "; ")
  }

  /// One pane's visible screen with its styling, for the reply surface. `-e` keeps the escape
  /// sequences the parser turns into `PaneScreenStyle`, as `--format ansi` does for herdr.
  static func readScreen(binary: String, pane: String) -> String {
    "\(binary) capture-pane -p -e -t \(pane)"
  }

  /// Splits `output` back into one array of rows per pane. Every id asked for gets an entry,
  /// so "asked and got nothing" differs from "never asked".
  static func panes(from output: String, ids: [String], lines: Int) -> [String: [String]] {
    var boundaries: [String: String] = [:]
    for id in ids { boundaries["\(paneMarker) \(id)"] = id }
    var panes = [String: [String]](minimumCapacity: ids.count)
    for id in ids { panes[id] = [] }

    var current: String?
    var chunk: [String] = []
    func flush() {
      if let current { panes[current] = rows(of: chunk, limit: lines) }
      chunk = []
    }
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      if let id = boundaries[String(line)] {
        flush()
        current = id
      } else if current != nil {
        chunk.append(String(line))
      }
      // Output before the first boundary belongs to no pane.
    }
    flush()
    return panes
  }

  /// One pane's chunk as the rows a thumbnail draws: trailing blank rows gone, then the tail.
  static func rows(of chunk: [String], limit: Int) -> [String] {
    var rows = chunk.map { line -> String in
      var line = line
      while let last = line.last, last.isWhitespace { line.removeLast() }
      return line
    }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return Array(rows.suffix(limit))
  }

  static func perform(binary: String, action: PaneAction, pane: String) -> String {
    switch action {
    case .split(let direction):
      // `-d` leaves the desk's focus where it is. `-c` starts the new pane where this one is,
      // which tmux expands as a format. `-h` is side by side, so `.right`.
      let flag = direction == .right ? "-h" : "-v"
      return "\(binary) split-window -d \(flag) -t \(pane) -c \(shellQuoted("#{pane_current_path}"))"
    case .rename(let label):
      // tmux has no pane name. The title is what the pane's program may overwrite, and it is
      // the closest thing.
      return "\(binary) select-pane -t \(pane) -T \(TmuxArgument.label(label))"
    case .close:
      return "\(binary) kill-pane -t \(pane)"
    }
  }

  static func rename(binary: String, target: RenameTarget, id: String, label: String) -> String {
    switch target {
    // `--`, so a label that starts with `-` is not a flag.
    case .workspace:
      "\(binary) rename-session -t \(id) -- \(TmuxArgument.label(label))"
    case .tab:
      "\(binary) rename-window -t \(id) -- \(TmuxArgument.label(label))"
    }
  }

  /// A window in the most recently used session, which prints the id its pane has. `-d`, so
  /// the desk's current window stays current.
  static func newWindow(binary: String) -> String {
    "\(binary) new-window -d -P -F \(shellQuoted("#{pane_id}"))"
  }

  /// For a host with no server, which `new-window` cannot target.
  static func newSession(binary: String) -> String {
    "\(binary) new-session -d -P -F \(shellQuoted("#{pane_id}"))"
  }

  /// `newWindow(binary:)`, named `name` and started in `folder`.
  ///
  /// tmux expands a format in `-c`, so every `#` is doubled: measured on 3.7c, a folder named
  /// `c#Sx` opened in `$HOME` and `c##Sx` opened `c#Sx`. `-n` takes `label(_:)`, which doubles
  /// them too, and turns off the window's automatic rename.
  static func newWindow(binary: String, named name: String, in folder: String) -> String {
    newWindow(binary: binary) + startingIn(name: name, folder: folder)
  }

  /// `newSession(binary:)`, named and started as `newWindow(binary:named:in:)`.
  static func newSession(binary: String, named name: String, in folder: String) -> String {
    newSession(binary: binary) + startingIn(name: name, folder: folder)
  }

  private static func startingIn(name: String, folder: String) -> String {
    " -n \(TmuxArgument.label(name)) -c \(TmuxArgument.quoted(folder.replacingOccurrences(of: "#", with: "##")))"
  }
}

extension Character {
  /// A control character below 0x20, DEL, or a newline of any kind, such as `\r\n`.
  fileprivate var isControl: Bool {
    isNewline || unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }
}

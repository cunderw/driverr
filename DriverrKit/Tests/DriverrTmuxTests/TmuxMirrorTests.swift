import DriverrCore
import DriverrHerdr
import Foundation
import Testing

@testable import DriverrTmux

/// A herdr TUI that answers with one tree, or fails as a host with no session does.
private actor StubTUI: HerdrControl {
  nonisolated let binaryPath = "herdr"
  private let read: Result<SessionTree, AppError>
  private let answer: HerdrAvailability

  init(_ read: Result<SessionTree, AppError>, answer: HerdrAvailability = .notInstalled) {
    self.read = read
    self.answer = answer
  }

  func snapshot() async throws -> SessionTree { try read.get() }
  func availability() async -> HerdrAvailability { answer }
  nonisolated func attachCommand(for pane: Pane) -> String? { "" }
  func sendText(paneID: String, text: String) async throws {}
  func submitText(paneID: String, text: String) async throws {}
  func sendKeys(paneID: String, keys: [PaneKey]) async throws {}
  func readPanes(ids: [String], lines: Int) async throws -> [String: [String]] { [:] }
  func readScreen(of pane: Pane, lines: Int) async throws -> PaneScreen {
    PaneScreen.sanitised("", lines: lines)
  }
  func perform(_ action: PaneAction, on paneID: String) async throws {}
  func rename(_ target: RenameTarget, to label: String) async throws {}
}

/// herdr's tree: `w1:p1` a shell, `w1:p2` the pane running a tmux client.
private let herdrTree = SessionTree(
  workspaces: [
    Workspace(
      id: "w1", number: 1, label: "herdr",
      tabs: [
        DriverrCore.Tab(
          id: "w1:t1", workspaceID: "w1", number: 1, label: "one",
          panes: [
            Pane(id: "w1:p1", tabID: "w1:t1", workspaceID: "w1", title: "zsh"),
            Pane(id: "w1:p2", tabID: "w1:t1", workspaceID: "w1", title: "tmux"),
          ])
      ])
  ],
  focusedPaneID: "w1:p2")

private let noSession = AppError.herdrCommandFailed(reason: "no session running")

/// A tmux server with two panes: `%0` a shell and `%1` running the given herdr command line. The
/// herdr process carries `TMUX`, as every process in a tmux pane does. `clients` attach to it.
private func host(
  herdr arguments: String? = "/opt/homebrew/bin/herdr --session work",
  herdrEnvironment: [String: String] = [:],
  herdrEnvironmentReadable: Bool = true,
  clients: [(pid: Int, environment: [String: String])] = []
) -> FakeTmuxHost {
  var processes = [FakeTmuxHost.Process(pid: 7000, tty: "ttys100", command: "zsh")]
  if let arguments {
    let program = String(arguments.split(separator: " ")[0])
    processes.append(
      FakeTmuxHost.Process(
        pid: 7001, tty: "ttys101", command: program, arguments: arguments,
        environment: herdrEnvironmentReadable
          ? herdrEnvironment.merging(
            ["TMUX": "/tmp/tmux-1000/default,1,0", "SECRET_TOKEN": "hunter2"]) { mine, _ in mine }
          : [:]))
  } else {
    processes.append(FakeTmuxHost.Process(pid: 7001, tty: "ttys101", command: "zsh"))
  }
  for client in clients {
    processes.append(
      FakeTmuxHost.Process(
        pid: client.pid, tty: "ttys050", command: "tmux", arguments: "tmux attach",
        environment: client.environment.merging(["SECRET_TOKEN": "hunter2"]) { mine, _ in mine }))
  }
  return FakeTmuxHost(
    sessions: [
      FakeTmuxHost.Session(
        id: 0, name: "desk", attached: 1,
        windows: [
          FakeTmuxHost.Window(
            id: 0, index: 0, name: "main", isActive: true,
            panes: [
              FakeTmuxHost.Pane(id: 0, isActive: true),
              FakeTmuxHost.Pane(id: 1, command: "herdr"),
            ])
        ])
    ],
    processes: processes,
    clients: clients.map(\.pid)
  )
}

private let inHerdr = [
  "HERDR_PANE_ID": "w1:p2",
  "HERDR_SOCKET_PATH": "/home/dev/.config/herdr/sessions/work/herdr.sock",
]

@Suite("tmux mirrors")
struct TmuxMirrorTests {
  // MARK: Reading a herdr command line

  @Test(
    "a herdr client's command line names its session",
    arguments: [
      ("herdr --session work", HerdrSessionKey.named("work")),
      ("/opt/homebrew/bin/herdr --session=work", .named("work")),
      ("herdr session attach work", .named("work")),
      ("herdr", .standard),
    ])
  func clientSession(arguments: String, key: HerdrSessionKey) {
    #expect(TmuxMirrors.herdrClientSession(arguments: arguments, environment: [:]) == key)
  }

  @Test(
    "anything that is not a herdr client of this computer names no session",
    arguments: [
      "herdr --remote box", "herdr --remote=box --session work", "herdr --machine box",
      "herdr server", "herdr pane list", "herdr --session work status",
      "/home/dev/.local/bin/herdr-core", "Herdr", "zsh",
    ])
  func notAClient(arguments: String) {
    #expect(TmuxMirrors.herdrClientSession(arguments: arguments, environment: inHerdr) == nil)
  }

  @Test("with no flag, the socket path decides, then the session name, else the standard one")
  func noFlag() {
    let both = ["HERDR_SOCKET_PATH": "/x/sessions/a/herdr.sock", "HERDR_SESSION": "b"]
    #expect(TmuxMirrors.herdrClientSession(arguments: "herdr", environment: both) == .named("a"))
    #expect(
      TmuxMirrors.herdrClientSession(arguments: "herdr", environment: ["HERDR_SESSION": "b"])
        == .named("b"))
    #expect(
      TmuxMirrors.herdrClientSession(
        arguments: "herdr", environment: ["HERDR_SOCKET_PATH": "/x/.config/herdr/herdr.sock"])
        == .standard)
    #expect(
      TmuxMirrors.herdrClientSession(arguments: "herdr --session c", environment: both)
        == .named("c"), "the flag wins")
  }

  // MARK: The command

  @Test("the environment read keeps only four variables, filtered on the host, under sh")
  func command() {
    let command = TmuxProcessDetailsRead.command(forPIDs: [12, 34])
    #expect(command.hasPrefix("sh -c '"))
    let script = TmuxProcessDetailsRead.script(forPIDs: [12, 34])
    #expect(script.contains("grep -E '^(HERDR_PANE_ID|HERDR_SESSION|HERDR_SOCKET_PATH|TMUX)='"))
    #expect(script.contains("/proc/12/environ"))
    #expect(script.contains("ps -wwE -o command= -p 34"))
    #expect(script.components(separatedBy: "grep -E").count == 3, "one filter per pid")
  }

  @Test("what the host printed is split by pid, and a variable outside the four is dropped")
  func details() {
    let output = """

      __DRIVERR_PROCESS__ 12
      args herdr --session work
      TMUX=/tmp/tmux-1000/default,1,0
      SECRET=x

      __DRIVERR_PROCESS__ 99
      args other

      __DRIVERR_PROCESS__ 34
      args tmux attach
      HERDR_PANE_ID=w1:p2
      """
    let details = TmuxProcessDetailsRead.details(from: output, forPIDs: [12, 34])
    #expect(details[12]?.arguments == "herdr --session work")
    #expect(details[12]?.environment == ["TMUX": "/tmp/tmux-1000/default,1,0"])
    #expect(details[34]?.environment == ["HERDR_PANE_ID": "w1:p2"])
    #expect(details[99] == nil)
  }

  @Test("a list-clients line is told apart from a pane row")
  func clientLines() {
    let output = "%0\u{1F}@0\n\(TmuxClientFormat.marker) 4242\n\(TmuxClientFormat.marker) x\n"
    #expect(TmuxClientFormat.pids(from: output) == [4242])
  }

  // MARK: A tmux host's snapshot

  @Test("a host with no herdr process runs no extra command and claims nothing")
  func noHerdrNoCommand() async throws {
    let fake = host(herdr: nil, clients: [(pid: 8000, environment: inHerdr)])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims.isEmpty)
    let commands = await fake.commands
    #expect(commands[0].contains("list-clients"), "the clients ride on the listing")
    #expect(commands.count == 3, "listing, process table, Claude's records: \(commands)")
    #expect(!commands.contains { $0.contains(TmuxProcessDetailsRead.marker) })
  }

  @Test("a tmux pane whose foreground is a herdr client claims that herdr session")
  func herdrInTmux() async throws {
    let fake = host()
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(paneID: "tmux:%1", session: .named("work"))])
    // The read asked for the herdr leader alone, and the shell pane's process stayed out.
    let read = try #require(await fake.commands.last)
    #expect(read == TmuxProcessDetailsRead.command(forPIDs: [7001]))
  }

  @Test("a tmux client in a herdr pane claims that herdr pane")
  func tmuxInHerdr() async throws {
    let fake = host(herdr: "herdr server", clients: [(pid: 8000, environment: inHerdr)])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(paneID: "w1:p2", session: .named("work"))])
  }

  @Test("the standard session is read from its socket path")
  func standardByPath() async throws {
    let fake = host(
      herdr: nil,
      clients: [
        (
          pid: 8000,
          environment: [
            "HERDR_PANE_ID": "w1:p2", "HERDR_SOCKET_PATH": "/home/dev/.config/herdr/herdr.sock",
          ]
        )
      ])
    // A herdr server elsewhere on the host is what turns the read on.
    await fake.setProcesses(
      await fake.processes + [
        FakeTmuxHost.Process(pid: 6000, tty: "??", command: "/opt/homebrew/bin/herdr")
      ])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(paneID: "w1:p2", session: .standard)])
  }

  @Test("a client started inside tmux carries the server's HERDR_ variables and is skipped")
  func clientInTmux() async throws {
    var environment = inHerdr
    environment["TMUX"] = "/tmp/tmux-1000/default,1,0"
    let fake = host(herdr: "herdr server", clients: [(pid: 8000, environment: environment)])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims.isEmpty)
  }

  /// A process in a tmux pane always carries `TMUX`, so a leader without it is one whose
  /// environment could not be read: a hardened binary, or a `/proc` the user cannot read. Read
  /// as empty, a plain `herdr` would claim the standard session whatever it really shows.
  @Test("a herdr leader whose environment cannot be read claims nothing, flag or not")
  func unreadLeader() async throws {
    for arguments in ["herdr", "herdr --session work"] {
      let fake = host(herdr: arguments, herdrEnvironmentReadable: false)
      #expect(
        try await TmuxControl(run: fake.runner).snapshot().mirrorClaims.isEmpty, "\(arguments)")
    }
  }

  @Test("a remote herdr in a tmux pane claims nothing")
  func remoteHerdr() async throws {
    let fake = host(herdr: "herdr --remote box --session work")
    #expect(try await TmuxControl(run: fake.runner).snapshot().mirrorClaims.isEmpty)
  }

  @Test("a host that will not answer the read still has its tree, with no claims")
  func failedRead() async throws {
    let fake = host()
    let control = TmuxControl(run: { command in
      if command.contains(TmuxProcessDetailsRead.marker) {
        throw AppError.channelFailed(reason: "gone")
      }
      return try await fake.runner(command)
    })
    let tree = try await control.snapshot()
    #expect(tree.allPanes.count == 2)
    #expect(tree.mirrorClaims.isEmpty)
  }

  // MARK: Beside herdr

  private func combined(
    tui: Result<SessionTree, AppError>,
    answer: HerdrAvailability = .notInstalled,
    tmux fake: FakeTmuxHost,
    socket: String?
  ) -> any HerdrControl {
    let tmux = TmuxControl(run: fake.runner)
    return CombinedControl(
      tui: StubTUI(tui, answer: answer),
      sides: [CombinedControl.Side(prefix: TmuxID.prefix, control: tmux)]
    ).bound(toSocketPath: socket)
  }

  @Test("a herdr client in tmux is marked when the host lists that herdr session")
  func marksHerdrClient() async throws {
    let control = combined(
      tui: .success(herdrTree), tmux: host(),
      socket: "/home/dev/.config/herdr/sessions/work/herdr.sock")
    let tree = try await control.snapshot()
    #expect(tree.allPanes.filter(\.isMirror).map(\.id) == ["tmux:%1"])
    #expect(tree.hidingMirrors().allPanes.map(\.id) == ["w1:p1", "w1:p2", "tmux:%0"])
    // A pushed change is merged the same way.
    #expect(try await control.changedSnapshot().allPanes.filter(\.isMirror).map(\.id) == ["tmux:%1"])
  }

  @Test("a herdr pane holding a tmux client is marked, and the focus it had goes when hidden")
  func marksHerdrPane() async throws {
    let control = combined(
      tui: .success(herdrTree), tmux: host(herdr: "herdr server", clients: [(8000, inHerdr)]),
      socket: "~/.config/herdr/sessions/work/herdr.sock")
    let tree = try await control.snapshot()
    #expect(tree.allPanes.filter(\.isMirror).map(\.id) == ["w1:p2"])
    #expect(tree.focusedPaneID == "w1:p2")
    let hidden = tree.hidingMirrors()
    #expect(hidden.allPanes.map(\.id) == ["w1:p1", "tmux:%0", "tmux:%1"])
    #expect(hidden.focusedPaneID == nil)
  }

  @Test("an unbound host is the standard session")
  func unboundIsStandard() async throws {
    let control = combined(tui: .success(herdrTree), tmux: host(herdr: "herdr"), socket: nil)
    #expect(try await control.snapshot().allPanes.filter(\.isMirror).map(\.id) == ["tmux:%1"])
  }

  @Test("a host on another herdr session hides nothing")
  func otherSession() async throws {
    for socket in [nil, "/home/dev/.config/herdr/sessions/play/herdr.sock", "/tmp/odd.sock"] {
      let control = combined(tui: .success(herdrTree), tmux: host(), socket: socket)
      #expect(try await control.snapshot().allPanes.allSatisfy { !$0.isMirror }, "\(socket ?? "nil")")
    }
  }

  @Test("with no herdr session listed, the tmux pane is the only way in and stays")
  func noSessionHidesNothing() async throws {
    let control = combined(
      tui: .failure(noSession), answer: .serverNotRunning(version: nil), tmux: host(),
      socket: "/home/dev/.config/herdr/sessions/work/herdr.sock")
    let tree = try await control.snapshot()
    #expect(tree.allPanes.map(\.id) == ["tmux:%0", "tmux:%1"])
    #expect(tree.allPanes.allSatisfy { !$0.isMirror })
    // The poll in the backoff gap answers from the sides alone, and hides nothing either.
    #expect(try await control.snapshot().allPanes.allSatisfy { !$0.isMirror })
  }

  @Test("a failed herdr read throws as before, and marks nothing")
  func failedTUI() async {
    let control = combined(
      tui: .failure(.herdrResponseUnreadable), tmux: host(),
      socket: "/home/dev/.config/herdr/sessions/work/herdr.sock")
    await #expect(throws: AppError.self) { try await control.snapshot() }
  }

  /// A core standing in for an absent TUI is not a herdr session, so a claim on the standard
  /// session must not match the unbound host's standard key.
  @Test("beside a core that stands in for the TUI, a claim marks nothing")
  func corePrimary() async throws {
    let core = StubTUI(.success(SessionTree(workspaces: [
      Workspace(
        id: "core:ws", number: 1, label: "core",
        tabs: [
          DriverrCore.Tab(
            id: "core:tab", workspaceID: "core:ws", number: 1, label: "Terminals",
            panes: [Pane(id: "core:t1", tabID: "core:tab", workspaceID: "core:ws", title: "t1")])
        ])
    ])))
    let tmux = TmuxControl(run: host(herdr: "herdr").runner)
    let control = CombinedControl(
      primary: core, sides: [CombinedControl.Side(prefix: TmuxID.prefix, control: tmux)]
    ).bound(toSocketPath: nil)
    let tree = try await control.snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(paneID: "tmux:%1", session: .standard)])
    #expect(tree.allPanes.map(\.id) == ["core:t1", "tmux:%0", "tmux:%1"])
    #expect(tree.allPanes.allSatisfy { !$0.isMirror })
  }

  @Test("tmux alone hides nothing, even with a claim")
  func tmuxAlone() async throws {
    let tmux = TmuxControl(run: host().runner)
    let joined = try #require(CombinedControl.joining(tui: nil, sides: [
      CombinedControl.Side(prefix: TmuxID.prefix, control: tmux)
    ]))
    let tree = try await joined.bound(toSocketPath: nil).snapshot()
    #expect(tree.mirrorClaims.count == 1)
    #expect(tree.allPanes.allSatisfy { !$0.isMirror })
  }
}

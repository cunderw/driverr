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
      // Measured on herdr 0.9.5: `--session default` joins the standard session's server.
      ("herdr --session default", .standard),
      ("herdr --session=default", .standard),
      ("herdr session attach default", .standard),
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

  // MARK: Reading an hc command line

  @Test(
    "an hc attach command line names the terminal by its address",
    arguments: [
      ("hc attach t1", "t1"),
      ("/home/x/.local/bin/hc attach t12", "t12"),
      ("herdr-core attach t1b", "t1b"),
      ("hc attach box/t7", "box/t7"),
      ("hc attach --observe t1", "t1"),
      ("hc attach --history 50 t1", "t1"),
      ("hc --json attach t1", "t1"),
    ])
  func attachedAddress(arguments: String, address: String) {
    #expect(TmuxMirrors.attachedAddress(arguments: arguments) == address)
  }

  @Test(
    "the picker, a name, and anything that is not hc attach name no terminal",
    arguments: [
      "hc", "/home/x/.local/bin/hc", "hc attach", "hc attach tm", "hc attach reviewer",
      "hc attach --history t1", "hc attach t1 t2", "hc run tmux", "hc ls", "hc attach T1",
      "hc attach t", "hc attach tx1", "hc attach /t1", "hc attach box/", "hcx attach t1",
      "herdr attach t1", "zsh",
    ])
  func notAnAttach(arguments: String) {
    #expect(TmuxMirrors.attachedAddress(arguments: arguments) == nil)
  }

  @Test(
    "the core an hc command reaches: HC_SOCKET, else HC_SESSION, else default",
    arguments: [
      ([String: String](), CoreSessionKey.named("default")),
      (["HC_SESSION": ""], .named("default")),
      (["HC_SESSION": "default"], .named("default")),
      (["HC_SESSION": "work"], .named("work")),
      (["HC_SOCKET": "/run/user/1000/herdr-core/work.sock", "HC_SESSION": "play"], .named("work")),
      (["HC_SOCKET": "/home/x/.local/state/herdr-core/default/default.sock"], .named("default")),
      (["HC_SOCKET": "/tmp/odd.sock"], .socket("/tmp/odd.sock")),
      (["HC_SOCKET": "/home/x/.local/state/herdr-core/a/b.sock"], .socket(
        "/home/x/.local/state/herdr-core/a/b.sock")),
      (["HC_SOCKET": "/x/herdr-core/.sock"], .socket("/x/herdr-core/.sock")),
    ])
  func coreKey(environment: [String: String], key: CoreSessionKey) {
    #expect(CoreSessionKey(environment: environment) == key)
  }

  // MARK: The command

  @Test("the environment read keeps only six variables, filtered on the host, under sh")
  func command() {
    let command = TmuxProcessDetailsRead.command(forPIDs: [12, 34])
    #expect(command.hasPrefix("sh -c '"))
    let script = TmuxProcessDetailsRead.script(forPIDs: [12, 34])
    #expect(
      script.contains(
        "grep -E '^(HERDR_PANE_ID|HERDR_SESSION|HERDR_SOCKET_PATH|TMUX|HC_SESSION|HC_SOCKET)='"))
    #expect(script.contains("/proc/12/environ"))
    #expect(script.contains("ps -wwE -o command= -p 34"))
    #expect(script.components(separatedBy: "grep -E").count == 3, "one filter per pid")
    #expect(!script.contains(TmuxProcessDetailsRead.ownCoreMarker))
  }

  @Test("asked for its own core, the read first prints two of the channel's variables, filtered")
  func ownCoreCommand() {
    let script = TmuxProcessDetailsRead.script(forPIDs: [12], readingOwnCore: true)
    #expect(
      script.hasPrefix(
        "printf '\\n%s\\n' '\(TmuxProcessDetailsRead.ownCoreMarker)'; "
          + "env | grep -E '^(HC_SESSION|HC_SOCKET)='; "))
    #expect(script.components(separatedBy: "grep -E").count == 3, "the channel's, then one per pid")
  }

  @Test("the channel's own lines are read apart from every process's")
  func ownCoreOutput() {
    let output = """

      __DRIVERR_OWN_CORE__
      HC_SESSION=work
      PATH=/usr/bin

      __DRIVERR_PROCESS__ 12
      args hc attach t1
      HC_SESSION=play
      """
    #expect(TmuxProcessDetailsRead.ownCoreEnvironment(from: output) == ["HC_SESSION": "work"])
    let details = TmuxProcessDetailsRead.details(from: output, forPIDs: [12])
    #expect(details[12]?.environment == ["HC_SESSION": "play"])
    #expect(
      TmuxProcessDetailsRead.ownCoreEnvironment(from: "\n__DRIVERR_OWN_CORE__\n") == [:],
      "a channel with neither variable is the default session, not an unread one")
    #expect(TmuxProcessDetailsRead.ownCoreEnvironment(from: "\n__DRIVERR_PROCESS__ 12\n") == nil)
  }

  @Test("what the host printed is split by pid, and a variable outside the six is dropped")
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

  // MARK: A tmux host beside a herdr-core

  /// The core itself, as `ps` names it when `hc` started it: the link's path.
  private static let core = FakeTmuxHost.Process(
    pid: 6100, tty: "??", command: "/home/x/.local/bin/hc", arguments: "hc --hc-launchd x")

  /// `host(…)` with `%1` led by the given `hc` command line, and the core running.
  private func coreHost(
    attach arguments: String = "/home/x/.local/bin/hc attach t3",
    environment: [String: String] = [:],
    readable: Bool = true,
    channel: [String: String] = [:],
    clients: [(pid: Int, environment: [String: String])] = []
  ) async -> FakeTmuxHost {
    let fake = host(
      herdr: arguments, herdrEnvironment: environment, herdrEnvironmentReadable: readable,
      clients: clients)
    await fake.setProcesses(await fake.processes + [Self.core])
    await fake.setChannelEnvironment(channel)
    return fake
  }

  @Test("with a core on the host, every client is a pid claim, and no command reads anything")
  func clientsBesideACore() async throws {
    let fake = host(herdr: nil, clients: [(8000, [:]), (8001, inHerdr)])
    await fake.setProcesses(await fake.processes + [Self.core])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(.tmuxClient(pid: 8000)), MirrorClaim(.tmuxClient(pid: 8001))])
    let commands = await fake.commands
    #expect(commands.count == 3, "listing, process table, Claude's records: \(commands)")
  }

  @Test(
    "a core's terminal holder, or a core run as herdr-core, is a core too",
    arguments: [
      "/home/x/.local/share/herdr-core/active/Herdr Core.app/Contents/MacOS/herdr-core",
      "herdr-core", "hc",
    ])
  func coreNames(command: String) async throws {
    let fake = host(herdr: nil, clients: [(8000, [:])])
    await fake.setProcesses(
      await fake.processes + [FakeTmuxHost.Process(pid: 6100, tty: "??", command: command)])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(tree.mirrorClaims == [MirrorClaim(.tmuxClient(pid: 8000))])
  }

  @Test("hc attach in a tmux pane claims that pane for the terminal, read with the channel's core")
  func attachInTmux() async throws {
    let fake = await coreHost(clients: [(8000, [:])])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(
      tree.mirrorClaims == [
        MirrorClaim(.coreAttach(paneID: "tmux:%1", address: "t3")),
        MirrorClaim(.tmuxClient(pid: 8000)),
      ])
    // The leader alone is read, with the channel's own core. The clients need no read.
    let read = try #require(await fake.commands.last)
    #expect(read == TmuxProcessDetailsRead.command(forPIDs: [7001], readingOwnCore: true))
  }

  @Test(
    "hc attach claims only on the core the channel reaches",
    arguments: [
      ([String: String](), [String: String](), true),
      (["HC_SESSION": "work"], ["HC_SESSION": "work"], true),
      (["HC_SESSION": "default"], [:], true),
      (["HC_SOCKET": "/run/user/1000/herdr-core/work.sock"], ["HC_SESSION": "work"], true),
      (["HC_SESSION": "play"], [:], false),
      ([:], ["HC_SESSION": "work"], false),
      (["HC_SOCKET": "/tmp/odd.sock"], [:], false),
    ])
  func attachOnAnotherCore(
    client: [String: String], channel: [String: String], claims: Bool
  ) async throws {
    let fake = await coreHost(environment: client, channel: channel)
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(
      tree.mirrorClaims
        == (claims ? [MirrorClaim(.coreAttach(paneID: "tmux:%1", address: "t3"))] : []))
  }

  @Test(
    "the picker, a name, and an hc leader whose environment cannot be read claim nothing",
    arguments: [
      ("/home/x/.local/bin/hc", true), ("hc attach reviewer", true), ("hc attach t3", false),
    ])
  func attachThatClaimsNothing(arguments: String, readable: Bool) async throws {
    let fake = await coreHost(attach: arguments, readable: readable)
    #expect(try await TmuxControl(run: fake.runner).snapshot().mirrorClaims.isEmpty)
  }

  @Test("with herdr and a core both on the host, each is read as before, in one command")
  func herdrAndCore() async throws {
    let fake = await coreHost(clients: [(8000, inHerdr)])
    await fake.setProcesses(
      await fake.processes + [
        FakeTmuxHost.Process(pid: 6000, tty: "??", command: "/opt/homebrew/bin/herdr")
      ])
    let tree = try await TmuxControl(run: fake.runner).snapshot()
    #expect(
      tree.mirrorClaims == [
        MirrorClaim(.coreAttach(paneID: "tmux:%1", address: "t3")),
        MirrorClaim(.tmuxClient(pid: 8000)),
        MirrorClaim(paneID: "w1:p2", session: .named("work")),
      ])
    let read = try #require(await fake.commands.last)
    #expect(read == TmuxProcessDetailsRead.command(forPIDs: [7001, 8000], readingOwnCore: true))
  }

  @Test("a failed read keeps the pid claims, which needed none")
  func failedReadBesideACore() async throws {
    let fake = await coreHost(clients: [(8000, [:])])
    let control = TmuxControl(run: { command in
      if command.contains(TmuxProcessDetailsRead.marker) {
        throw AppError.channelFailed(reason: "gone")
      }
      return try await fake.runner(command)
    })
    #expect(try await control.snapshot().mirrorClaims == [MirrorClaim(.tmuxClient(pid: 8000))])
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

  // MARK: Beside a herdr-core

  /// A core's tree: `core:t1` runs process 8000, which is a tmux client in these tests, and
  /// `core:t3` is the terminal `hc attach t3` shows. `core:box/t1` is on a machine the core
  /// added, and carries pid 8000 too, as another computer's process can.
  private static let coreTree = SessionTree(
    workspaces: [
      Workspace(
        id: "core:workspace", number: 1, label: "herdr-core",
        tabs: [
          DriverrCore.Tab(
            id: "core:tab", workspaceID: "core:workspace", number: 1, label: "Terminals",
            panes: [
              Pane(
                id: "core:t1", tabID: "core:tab", workspaceID: "core:workspace", title: "tmux",
                foregroundPID: 8000),
              Pane(
                id: "core:t3", tabID: "core:tab", workspaceID: "core:workspace", title: "zsh",
                foregroundPID: 9100),
            ])
        ]),
      Workspace(
        id: "core:box/workspace", number: 2, label: "box",
        tabs: [
          DriverrCore.Tab(
            id: "core:box/tab", workspaceID: "core:box/workspace", number: 1, label: "Terminals",
            panes: [
              Pane(
                id: "core:box/t1", tabID: "core:box/tab", workspaceID: "core:box/workspace",
                title: "zsh", foregroundPID: 8000)
            ])
        ]),
    ],
    coreID: "c0re")

  /// The three ways a core and tmux meet herdr: beside a TUI tree, beside a TUI with no
  /// session, and with the core standing in for the TUI.
  enum Shape: CaseIterable, Sendable {
    case besideTUI, noSession, corePrimary
  }

  private func coreCombined(
    _ shape: Shape, core: Result<SessionTree, AppError> = .success(coreTree), tmux fake: FakeTmuxHost
  ) -> any HerdrControl {
    let tmux = CombinedControl.Side(prefix: TmuxID.prefix, control: TmuxControl(run: fake.runner))
    let core = StubTUI(core)
    switch shape {
    case .besideTUI, .noSession:
      let tui =
        shape == .besideTUI
        ? StubTUI(.success(herdrTree))
        : StubTUI(.failure(noSession), answer: .serverNotRunning(version: nil))
      return CombinedControl(
        tui: tui, sides: [CombinedControl.Side(prefix: CorePaneID.prefix, control: core), tmux]
      ).bound(toSocketPath: nil)
    case .corePrimary:
      return CombinedControl(primary: core, sides: [tmux]).bound(toSocketPath: nil)
    }
  }

  @Test(
    "a core terminal running a tmux client of this server is marked, wherever the core is read",
    arguments: Shape.allCases)
  func marksCoreTerminal(shape: Shape) async throws {
    let fake = host(herdr: nil, clients: [(8000, [:])])
    await fake.setProcesses(await fake.processes + [Self.core])
    let control = coreCombined(shape, tmux: fake)
    let tree = try await control.snapshot()
    #expect(tree.allPanes.filter(\.isMirror).map(\.id) == ["core:t1"], "\(shape)")
    #expect(!tree.hidingMirrors().allPanes.map(\.id).contains("core:t1"))
    // A pushed change is merged the same way.
    #expect(
      try await control.changedSnapshot().allPanes.filter(\.isMirror).map(\.id) == ["core:t1"])
  }

  @Test("a pid that matches no client marks nothing, and a client that matches no pid neither")
  func pidMatchesNothing() async throws {
    let fake = host(herdr: nil, clients: [(8050, [:])])
    await fake.setProcesses(await fake.processes + [Self.core])
    for shape in Shape.allCases {
      let tree = try await coreCombined(shape, tmux: fake).snapshot()
      #expect(tree.mirrorClaims == [MirrorClaim(.tmuxClient(pid: 8050))])
      #expect(tree.allPanes.allSatisfy { !$0.isMirror }, "\(shape)")
    }
  }

  /// A pid names a process on one computer. `core:box/t1` runs on a machine the core added, so
  /// its 8000 is not this host's tmux client 8000, even though the numbers agree.
  @Test("a terminal on a machine the core added never matches a pid, even an equal one")
  func addedMachineNeverMatches() async throws {
    let fake = host(herdr: nil, clients: [(8000, [:])])
    await fake.setProcesses(await fake.processes + [Self.core])
    let tree = try await coreCombined(.corePrimary, tmux: fake).snapshot()
    #expect(tree.pane(id: "core:box/t1")?.isMirror == false)
    #expect(tree.pane(id: "core:t1")?.isMirror == true)
  }

  @Test("a tmux pane attached to a core terminal is marked when the core lists it", arguments: Shape.allCases)
  func marksAttachedPane(shape: Shape) async throws {
    let fake = await coreHost()
    let tree = try await coreCombined(shape, tmux: fake).snapshot()
    #expect(tree.allPanes.filter(\.isMirror).map(\.id) == ["tmux:%1"], "\(shape)")
  }

  @Test("a tmux pane attached to a terminal the core does not list stays")
  func attachedToAnUnlistedTerminal() async throws {
    let fake = await coreHost(attach: "hc attach t9")
    for shape in Shape.allCases {
      let tree = try await coreCombined(shape, tmux: fake).snapshot()
      #expect(tree.mirrorClaims == [MirrorClaim(.coreAttach(paneID: "tmux:%1", address: "t9"))])
      #expect(tree.allPanes.allSatisfy { !$0.isMirror }, "\(shape)")
    }
  }

  /// With the core's read failed, the tmux pane is the only way to the terminal it shows.
  @Test("with the core's read failed, nothing is marked")
  func coreReadFailed() async throws {
    let fake = await coreHost(clients: [(8000, [:])])
    let control = coreCombined(
      .besideTUI, core: .failure(.channelFailed(reason: "gone")), tmux: fake)
    let tree = try await control.snapshot()
    #expect(tree.mirrorClaims.count == 2)
    #expect(tree.allPanes.allSatisfy { !$0.isMirror })
  }

  @Test("tmux alone hides nothing for a core either")
  func tmuxAloneBesideNoCore() async throws {
    let fake = await coreHost(clients: [(8000, [:])])
    let joined = try #require(
      CombinedControl.joining(tui: nil, sides: [
        CombinedControl.Side(prefix: TmuxID.prefix, control: TmuxControl(run: fake.runner))
      ]))
    let tree = try await joined.bound(toSocketPath: nil).snapshot()
    #expect(tree.mirrorClaims.count == 2)
    #expect(tree.allPanes.allSatisfy { !$0.isMirror })
  }
}

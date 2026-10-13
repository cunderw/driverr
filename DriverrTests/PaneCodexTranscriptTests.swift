import DriverrCore
import DriverrHerdr
import DriverrTranscript
import Foundation
import Testing

@testable import Driverr

/// A Codex pane's Chat surface draws its own rollout, not the screen fallback.
///
/// Separate from `PaneTranscriptModelTests`, whose `host(…)` helper answers Claude's commands.
/// The routing is asserted in `CodexResolverTests`; this is `PaneTranscriptModel`, which the
/// Chat surface reads, going `.ready` with the rollout's turns.
@MainActor
@Suite("Codex pane transcript")
struct PaneCodexTranscriptTests {
  /// The rollout the fake host serves, with the pane's own `cwd` on it.
  ///
  /// `FakeTranscriptHost`, so the records go through `TranscriptCommands.codexReadCommand`'s
  /// selector and `TranscriptParser.codexPage` as a host's would.
  private static let rollout = FakeTranscriptHost.CodexSession(
    id: "01a00000-1111-7222-8333-444455556666",
    cwd: "/Users/x/Dev/tower",
    turns: [
      .init(speaker: .human, text: "sync the schema", secondsAgo: 300),
      .init(speaker: .tools([ToolCall(name: "exec", target: "psql -f schema.sql")]), secondsAgo: 240),
      .init(speaker: .assistant, text: "Schema synced, 4 tables changed.", secondsAgo: 120),
    ]
  )

  /// A host with both agents' files on it, so reading one pane out of the other agent's file
  /// can fail here.
  private func host() -> FakeTranscriptHost {
    FakeTranscriptHost(
      sessionID: "3f8c1d20-0000-4000-8000-000000000002",
      turns: [
        .init(speaker: .human, text: "make the connection pool async", secondsAgo: 900),
        .init(speaker: .assistant, text: "The pool is async now.", secondsAgo: 240),
      ],
      codexSessions: [Self.rollout]
    )
  }

  private func codexPane(
    session: AgentSession? = nil,
    directory: String? = "/Users/x/Dev/tower"
  ) -> Pane {
    Pane(
      id: "w2:p1",
      tabID: "w2:t1",
      workspaceID: "w2",
      title: "schema sync",
      agent: Agent(name: "Codex", kind: "codex", status: .idle, session: session),
      terminalID: "term_w2p1",
      directory: directory
    )
  }

  private func settled(_ model: PaneTranscriptModel) async {
    await model.currentLoad?.value
  }

  /// A Codex pane reaches the host and resolves to its rollout, rather than
  /// `.absent(.agentNotSupported(agent: "Codex"))` and the captured screen.
  @Test("a Codex pane's chat is its rollout, not the screen fallback")
  func codexPaneLoadsItsRollout() async {
    let model = PaneTranscriptModel(pane: codexPane(), reader: TranscriptReader(run: host().run))

    model.loadIfNeeded()
    await settled(model)

    guard case .ready(let source, let transcript) = model.state else {
      Issue.record(
        "A Codex pane must resolve to its own rollout rather than fall to the screen. State: \(model.state)"
      )
      return
    }

    // The rollout under `~/.codex/sessions`, not the Claude file on the same host, which would
    // parse and render a complete, wrong conversation.
    #expect(source.file.path.contains(".codex/sessions"))
    #expect(source.file.agent == .codex)
    #expect(source.provenance == .matchedByDirectory)
    #expect(source.directory == "/Users/x/Dev/tower")

    // The words are the rollout's own, not the Claude fixture's.
    let said = transcript.turns.compactMap(\.text)
    #expect(said.contains("sync the schema"))
    #expect(said.contains("Schema synced, 4 tables changed."))
    #expect(
      !said.contains("make the connection pool async"),
      "The Codex pane drew the Claude session file on this host, which is the bug this test exists for."
    )

    // The tool run comes from `response_item`, a different stream from the prose, so a page
    // that dropped the calls fails here.
    let run = transcript.turns.compactMap(\.toolRun).first
    #expect(run?.calls.map(\.name) == ["exec"])
    // `.unknown`: a call the fixture leaves `.unknown` is raw shell text, with no `cmd:`
    // literal to join to a completion. See `CodexRecord`'s header.
    #expect(run?.calls.first?.outcome == .unknown)
  }

  /// Tier 1 for Codex, which matches a **field** rather than a filename.
  ///
  /// Codex names a rollout `rollout-<timestamp>-<uuid>.jsonl`, so the reported id is in the
  /// header, `payload.id` on line 1, not the filename. A mismatch resolves nothing, silently.
  @Test("a reported Codex session id matches the rollout's header, not its filename")
  func reportedSessionResolvesTierOne() async {
    let model = PaneTranscriptModel(
      pane: codexPane(
        session: AgentSession(
          agent: "codex",
          kind: "id",
          value: Self.rollout.id,
          source: "herdr:codex"
        )
      ),
      reader: TranscriptReader(run: host().run)
    )

    model.loadIfNeeded()
    await settled(model)

    guard case .ready(let source, _) = model.state else {
      Issue.record("Expected the reported rollout to resolve, got \(model.state)")
      return
    }
    #expect(source.provenance == .reportedByHerdr(sessionID: Self.rollout.id))
    #expect(source.file.path.contains(Self.rollout.id))
  }

  /// A reported id that no rollout under this `cwd` carries **draws nothing**, and does not
  /// fall through to the newest one.
  ///
  /// `TranscriptAbsence.reportedSessionMissing`'s rule: an id that matches nothing means these
  /// rollouts are not this pane's, so the newest is another agent's conversation.
  @Test("a reported Codex session that is not on the host is named, never guessed past")
  func reportedSessionMissingDrawsNothing() async {
    let model = PaneTranscriptModel(
      pane: codexPane(
        session: AgentSession(
          agent: "codex",
          kind: "id",
          value: "99999999-0000-0000-0000-000000000000",
          source: "herdr:codex"
        )
      ),
      reader: TranscriptReader(run: host().run)
    )

    model.loadIfNeeded()
    await settled(model)

    #expect(
      model.state
        == .unavailable(
          .absent(
            .reportedSessionMissing(
              sessionID: "99999999-0000-0000-0000-000000000000",
              directory: "/Users/x/Dev/tower"
            )
          )
        )
    )
  }

  /// A Codex pane whose `cwd` has no rollout on this host says so, rather than showing
  /// another directory's newest conversation.
  @Test("a Codex pane in a directory with no rollout reports that")
  func noRolloutForThisDirectory() async {
    let model = PaneTranscriptModel(
      pane: codexPane(directory: "/Users/x/Dev/elsewhere"),
      reader: TranscriptReader(run: host().run)
    )

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .unavailable(.absent(.noSessionFiles(directory: "/Users/x/Dev/elsewhere"))))
  }

  /// The Claude pane on the same host still reads Claude's file, or a build that sent every
  /// pane to the Codex reader would pass.
  @Test("a Claude pane on the same host still reads its own session file")
  func claudePaneIsUnaffected() async {
    let pane = Pane(
      id: "w1:p2",
      tabID: "w1:t1",
      workspaceID: "w1",
      title: "needs a decision",
      agent: Agent(name: "Claude", kind: "claude", status: .blocked),
      terminalID: "term_w1p2",
      directory: "/Users/x/Dev/driverr"
    )
    let model = PaneTranscriptModel(pane: pane, reader: TranscriptReader(run: host().run))

    model.loadIfNeeded()
    await settled(model)

    guard case .ready(let source, let transcript) = model.state else {
      Issue.record("Expected the Claude pane to resolve as it always has, got \(model.state)")
      return
    }
    #expect(source.file.agent == .claude)
    #expect(source.file.path.hasSuffix(".jsonl"))
    #expect(!source.file.path.contains(".codex"))
    #expect(transcript.turns.compactMap(\.text).contains("make the connection pool async"))
  }

  /// An agent with no reader is the third state the Chat surface draws; `w2:p1` in
  /// `FakeControl.seededTree` carries it.
  @Test("an agent with no reader is still named rather than guessed at")
  func unreadableAgentIsUnchanged() async {
    let pane = Pane(
      id: "w2:p1",
      tabID: "w2:t1",
      workspaceID: "w2",
      title: "schema sync",
      agent: Agent(name: "Gemini", kind: "gemini", status: .idle),
      terminalID: "term_w2p1",
      directory: "/Users/x/Dev/tower"
    )
    let model = PaneTranscriptModel(pane: pane, reader: TranscriptReader(run: host().run))

    model.loadIfNeeded()
    await settled(model)

    #expect(model.state == .unavailable(.absent(.agentNotSupported(agent: "Gemini"))))
  }
}

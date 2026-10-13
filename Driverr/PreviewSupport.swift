#if DEBUG

  import DriverrCore
  import DriverrHerdr
  import DriverrSSH
  import DriverrTranscript
  import Foundation
  import SwiftUI

  /// What the `#Preview`s in this target are built from.
  ///
  /// Everything comes from `FakeControl` and `FakeSSHTransport`, not hand-written values,
  /// so a preview shows what the tests and the tour see. The whole file is `#if DEBUG`, so
  /// none of it ships.
  @MainActor
  enum PreviewSupport {
    /// The host the previews connect to, the same one the UI suite seeds.
    static let host = DriverrCore.Host.uiTestSeed

    /// `AppEnvironment.ephemeral`, with this host's key trusted and its password saved.
    ///
    /// The key is pre-trusted because a fresh known-hosts store would raise the trust
    /// prompt, and a preview has nobody to answer it. The real validator still runs. With a
    /// saved password the host screen connects on appearance, through the app's own path.
    static func environment() async -> AppEnvironment {
      var environment = AppEnvironment.ephemeral
      environment.knownHostsStore = InMemoryKnownHostsStore(
        seeded: [host.hostname: FakeSSHTransport.defaultHostKey]
      )
      try? await environment.passwordStore.save("hunter2", for: host.id)
      return environment
    }

    /// The session the UI suite and the store tour both see. Re-exported so previews
    /// elsewhere need not `import DriverrHerdr`.
    static let seededSession = FakeControl.seededTree
    /// Thirteen panes across four workspaces.
    static let crowdedSession = FakeControl.crowdedTree
    /// The seed with a second agent blocked, as the UI suite's fake polls its way to.
    static let blockedSession = FakeControl.treeWithSecondBlockedPane

    /// A pane with no agent, taken from the seed so it cannot drift. Force-unwrapped so a
    /// seed without a shell pane breaks the preview loudly.
    static let shellPane = seededSession.allPanes.first { $0.agent == nil }!

    /// The blocked Gemini pane, an agent this build has no reader for. Force-unwrapped like
    /// `shellPane`.
    static let unreadableAgentPane = blockedSession.allPanes.first { $0.id == "w2:p1" }!

    /// Thumbnails for a fixed tree, answered by the fake's fixture. Every tile is cold,
    /// because a preview holds no terminal sessions.
    static func thumbnails(_ tree: SessionTree, showing targets: [TerminalTarget])
      -> PaneThumbnailModel
    {
      let control = FakeControl(tree: tree)
      return PaneThumbnailModel(
        control: { control },
        targets: { targets },
        warmLines: { _ in nil }
      )
    }

    /// A session model over a fixed tree. The caller loads it through a `.task`, as the app
    /// does, because `HerdrControl` is an actor. Static, not scripted, so the preview holds
    /// still.
    static func model(_ tree: SessionTree) -> SessionModel {
      SessionModel(control: FakeControl(tree: tree))
    }

    /// The seed's pane with a reported `agent_session`, so a chat preview draws the exact
    /// header. Chosen by session, not kind, because the first Claude pane has no session.
    /// Force-unwrapped like `shellPane`.
    static let agentPane = seededSession.allPanes.first { $0.agent?.session != nil }!

    /// A pane's transcript from the fake environment's fixture. Loaded on construction,
    /// because the model owns its fetch.
    static func transcript(
      for pane: DriverrCore.Pane = agentPane,
      run: @escaping CommandRunner = AppEnvironment.seededTranscript.run
    ) -> PaneTranscriptModel {
      let model = PaneTranscriptModel(pane: pane, reader: TranscriptReader(run: run))
      model.loadIfNeeded()
      return model
    }

    /// A pane's captured screen from the UI suite's fake. Loaded on construction, like
    /// `transcript(for:)`.
    ///
    /// `failing:` is herdr refusing the read. `showing: .blank` is a pane showing nothing.
    /// They are different states.
    static func paneScreen(
      for pane: DriverrCore.Pane = agentPane,
      failing failure: AppError? = nil,
      showing screen: PaneScreen? = nil
    ) -> PaneScreenModel {
      let control = FakeControl(tree: seededSession, failure: failure, screen: screen)
      let model = PaneScreenModel(pane: pane, control: { control })
      model.loadIfNeeded()
      return model
    }

    /// A pane's composer on the UI suite's fake, in a given state. See
    /// `PaneComposerModel.init(pane:control:showing:)`.
    static func composer(
      for pane: DriverrCore.Pane = agentPane,
      in state: PaneComposerState = PaneComposerState()
    ) -> PaneComposerModel {
      let control = FakeControl(tree: seededSession)
      return PaneComposerModel(pane: pane, control: { control }, showing: state)
    }

    /// A host with two session files written seconds apart, which the resolver refuses to
    /// choose between. A real fake, so the picker can read opening lines and a pick can be
    /// read.
    static let ambiguousTranscript: CommandRunner = AppEnvironment.ambiguousTranscript.run

    /// The seeded session's conversations, from the ephemeral environment's fixture.
    ///
    /// The fixture answers for the Claude panes and the Codex pane `w3:p1`, but the tree asks
    /// only for a blocked pane. Of the two in `blockedSession`, `w1:p2` has one. The Gemini
    /// pane `w2:p1` has none, because this build has no Gemini reader. The real cache shows
    /// both.
    static let transcripts = PaneTranscriptCache(
      reader: TranscriptReader(run: AppEnvironment.seededTranscript.run)
    )
  }

  /// A session tree in a `Form`. `SessionTreeView` is `Section`s for `HostDetailView`'s
  /// `Form`, and bare it would draw spacing it never has.
  struct PreviewSessionTree: View {
    var tree: SessionTree = PreviewSupport.seededSession
    /// Whether the rows are interactive. `true` matches the host screen. `false` shows the
    /// read-only shape.
    var interactive = true

    @State private var model: SessionModel?

    var body: some View {
      Form {
        if let model {
          SessionTreeView(
            model: model,
            transcripts: PreviewSupport.transcripts,
            onSelect: interactive ? { _ in } : nil,
            onReply: interactive ? { _ in } : nil
          )
        }
      }
      .task {
        let model = PreviewSupport.model(tree)
        await model.refresh()
        self.model = model
      }
    }
  }

#endif

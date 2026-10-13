import DriverrCore
import DriverrSSH
import Testing

@testable import Driverr

/// The claim the previews rest on, asserted rather than assumed.
///
/// No gate runs a `#Preview`, so a build proves only that it compiles. What can silently rot
/// is the premise: that `PreviewSupport.environment()` reaches `connected` without a human
/// answering a trust prompt. Otherwise every host-screen preview sits at "connecting".
@MainActor
@Suite("Preview support")
struct PreviewSupportTests {
  @Test("the preview environment connects without anyone answering a trust prompt")
  func connectsWithoutTheTrustPrompt() async throws {
    // A fresh known-hosts store has never seen the fake transport's key, so TOFU asks, and
    // nobody answers in a preview canvas.
    let environment = await PreviewSupport.environment()

    // `require`, before connecting: an unanswered `askToTrust` never resumes, so a broken seed
    // would hang the gate rather than fail here.
    let trusted = await environment.knownHostsStore.trustedKey(for: PreviewSupport.host.hostname)
    try #require(
      trusted == FakeSSHTransport.defaultHostKey,
      "the preview's host key is not pre-trusted; connecting would block on the prompt"
    )

    let prompt = InteractiveHostKeyPrompt()
    let model = ConnectionModel(
      host: PreviewSupport.host,
      environment: environment,
      prompt: prompt
    )

    await model.connect(password: "hunter2", persistence: .promptEveryTime)

    #expect(model.phase == .connected)
    #expect(prompt.pending == nil, "the preview would be stuck on a prompt it cannot answer")
  }

  @Test("the host screen's password field is filled from the preview environment")
  func passwordIsAlreadyThere() async {
    // `HostDetailView` reads this on appearance. Without it the preview's Connect does
    // nothing.
    let environment = await PreviewSupport.environment()
    let model = ConnectionModel(
      host: PreviewSupport.host,
      environment: environment,
      prompt: InteractiveHostKeyPrompt()
    )

    #expect(await model.savedPassword() == "hunter2")
  }

  @Test("connecting brings a session with it, so the tree previews have a tree")
  func connectingProducesASession() async throws {
    let environment = await PreviewSupport.environment()
    // The same guard as in `connectsWithoutTheTrustPrompt`.
    let trusted = await environment.knownHostsStore.trustedKey(for: PreviewSupport.host.hostname)
    try #require(trusted == FakeSSHTransport.defaultHostKey)

    let model = ConnectionModel(
      host: PreviewSupport.host,
      environment: environment,
      prompt: InteractiveHostKeyPrompt()
    )

    await model.connect(password: "hunter2", persistence: .promptEveryTime)
    await model.session?.refresh()

    #expect(model.herdrAvailability?.isReady == true)
    #expect(model.session?.tree.isEmpty == false)
  }

  @Test("every fixture the previews render comes from FakeControl, already populated")
  func fixturesArePopulated() async {
    // Asserts the shape a preview needs, one of each kind of row, rather than counts the
    // fixture may change.
    let seeded = PreviewSupport.seededSession
    #expect(seeded.allPanes.contains { $0.agent?.status == .blocked })
    #expect(seeded.allPanes.contains { $0.agent?.status == .done })
    #expect(seeded.allPanes.contains { $0.agent?.status == .working })
    #expect(seeded.allPanes.contains { $0.agent == nil }, "a shell pane, which wears no badge")

    // Big enough that collapsing is the point rather than a nicety.
    let crowded = PreviewSupport.crowdedSession
    #expect(crowded.workspaces.count >= 4)
    #expect(crowded.allPanes.count >= 12)
    #expect(crowded.workspaces.contains { $0.tabs.count >= 3 })
    #expect(crowded.workspaces.contains { $0.status == nil }, "a workspace with no agent")
  }

  @Test("a session model handed a fixture loads that fixture")
  func modelLoadsItsFixture() async {
    // `PreviewSessionTree` refreshes on appearance; without it every session preview shows
    // only its loading row.
    let model = PreviewSupport.model(PreviewSupport.crowdedSession)
    await model.refresh()

    #expect(model.tree == PreviewSupport.crowdedSession)
  }
}

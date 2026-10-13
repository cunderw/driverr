import DriverrCore
import DriverrTranscript
import SwiftUI
import Testing

@testable import Driverr

/// The tree reads a stop only off a transcript something else has loaded. The reason is at
/// the `existingModel` lookup in `SessionTreeView`.
@MainActor
@Suite("Session tree transcript reads")
struct SessionTreeTranscriptReadTests {
  /// The blocked pane is the Needs You row's too, which reads it anyway, so the tree asks
  /// for its model rather than depend on that row having been built first.
  @Test("drawing the tree makes a model for a blocked pane and none for a pane nobody opened")
  func theTreeMakesNoModelForAnUnopenedPane() async throws {
    let tree = PreviewSupport.seededSession
    let working = try #require(tree.allPanes.first { $0.agent?.status == .working })
    let blocked = try #require(tree.allPanes.first { $0.agent?.status == .blocked })
    let model = PreviewSupport.model(tree)
    await model.refresh()
    let transcripts = PaneTranscriptCache(
      reader: TranscriptReader(run: AppEnvironment.seededTranscript.run))

    let window = HostedProbe.window(
      Form { SessionTreeView(model: model, transcripts: transcripts, onSelect: { _ in }) })

    #expect(transcripts.existingModel(for: working.id) == nil)
    #expect(transcripts.existingModel(for: blocked.id) != nil)
    withExtendedLifetime(window) {}
  }
}

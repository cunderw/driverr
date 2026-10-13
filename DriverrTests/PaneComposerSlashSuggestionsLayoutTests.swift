import DriverrCore
import SwiftUI
import Testing
import UIKit

@testable import Driverr

/// The `/` completion list is laid out as part of the bar, above the card, rather than as an
/// overlay that could float free of it. A bar showing suggestions measures taller than the same
/// bar idle, measured through `onLayoutProbe`. This does not show the list clears the keyboard
/// on a device.
@MainActor
@Suite("Composer slash suggestions layout")
struct PaneComposerSlashSuggestionsLayoutTests {
  private func commandTurn(_ text: String) -> TranscriptTurn {
    TranscriptTurn(id: UUID().uuidString, speech: .human(text), isCommand: true)
  }

  private var transcript: Transcript {
    Transcript(
      turns: [commandTurn("/run-tests"), commandTurn("/push")],
      window: .none
    )
  }

  private func bar(
    text: String,
    transcript: Transcript?,
    isCollapsed: Bool = false,
    onHeight: @escaping (Double) -> Void
  ) -> some View {
    var state = PaneComposerState()
    state.text = text
    let composer = PreviewSupport.composer(for: PreviewSupport.agentPane, in: state)
    return PaneComposerBar(
      model: composer,
      transcript: transcript,
      header: PaneComposerHeader(pane: PreviewSupport.agentPane),
      onLayoutProbe: { onHeight(Double($0.height)) },
      isCollapsed: isCollapsed
    )
  }

  @Test("a bare slash grows the bar taller than idle")
  func bareSlashGrowsTheBar() {
    var idleHeight: Double = 0
    var slashHeight: Double = 0

    let idle = HostedProbe.window(bar(text: "", transcript: transcript) { idleHeight = $0 })
    let slash = HostedProbe.window(bar(text: "/", transcript: transcript) { slashHeight = $0 })
    withExtendedLifetime((idle, slash)) {}

    #expect(idleHeight > 0)
    #expect(slashHeight > idleHeight)
  }

  @Test("a space ending the command word collapses the bar back to idle height")
  func spaceCollapsesTheList() {
    var idleHeight: Double = 0
    var afterSpaceHeight: Double = 0

    let idle = HostedProbe.window(bar(text: "", transcript: transcript) { idleHeight = $0 })
    let afterSpace = HostedProbe.window(
      bar(text: "/run-tests ", transcript: transcript) { afterSpaceHeight = $0 }
    )
    withExtendedLifetime((idle, afterSpace)) {}

    #expect(afterSpaceHeight == idleHeight)
  }

  @Test("no transcript, no list — the shell-pane case")
  func noTranscriptNoList() {
    var withTranscriptHeight: Double = 0
    var withoutTranscriptHeight: Double = 0

    let with = HostedProbe.window(bar(text: "/", transcript: transcript) { withTranscriptHeight = $0 })
    let without = HostedProbe.window(bar(text: "/", transcript: nil) { withoutTranscriptHeight = $0 })
    withExtendedLifetime((with, without)) {}

    #expect(withTranscriptHeight > withoutTranscriptHeight)
  }

  /// The collapsed, landscape-with-keyboard bar. A bare `/` must leave it exactly as tall as idle,
  /// not merely shorter, which a one-row list would also pass.
  @Test("collapsed, a bare slash offers nothing and the bar does not grow")
  func collapsedOffersNothing() {
    var idleHeight: Double = 0
    var slashHeight: Double = 0
    var expandedSlashHeight: Double = 0

    let idle = HostedProbe.window(
      bar(text: "", transcript: transcript, isCollapsed: true) { idleHeight = $0 }
    )
    let slash = HostedProbe.window(
      bar(text: "/", transcript: transcript, isCollapsed: true) { slashHeight = $0 }
    )
    let expanded = HostedProbe.window(
      bar(text: "/", transcript: transcript) { expandedSlashHeight = $0 }
    )
    withExtendedLifetime((idle, slash, expanded)) {}

    #expect(idleHeight > 0)
    #expect(slashHeight == idleHeight)
    // The same query on an expanded bar does grow it, so this measures the gate rather than a
    // fixture that offers nothing.
    #expect(expandedSlashHeight > slashHeight)
  }
}

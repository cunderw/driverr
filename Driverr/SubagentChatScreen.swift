import DriverrCore
import SwiftUI
import UIKit

/// A sub-agent's conversation, pushed over the pane scene on the phone's stack.
///
/// `PhoneStackPath.Route.subagent` resolves here. The system back button and the edge swipe
/// pop it, and `ContentView.phonePath`'s setter closes the sub-agent on the pane's model. Put
/// nothing custom in the leading slot: replacing the back button disables the edge swipe
/// (CLAUDE.md). The iPad's detail column cannot push, so there `TerminalScreen` shows the
/// sub-agent in place instead.
///
/// No composer: a reply would go to the pane's agent, not the sub-agent.
struct SubagentChatScreen: View {
  /// The sub-agent open on the pane's model, or `nil` once it closes.
  let opened: PaneTranscriptModel?
  /// The pane's agent's name and captured screen, which `PaneChatView` needs. A sub-agent's
  /// chat never offers the screen, because the screen is the pane's.
  let agentName: String
  let screen: PaneScreenModel

  /// The sub-agent this screen was pushed for, held so the pop animation still draws it after
  /// Back has closed it on the model.
  @State private var held: PaneTranscriptModel?
  /// The chat image being viewed full size, drawn over the whole screen, as on
  /// `TerminalScreen`.
  @State private var viewingImage: TranscriptImage?

  init(opened: PaneTranscriptModel?, agentName: String, screen: PaneScreenModel) {
    self.opened = opened
    self.agentName = agentName
    self.screen = screen
    _held = State(initialValue: opened)
  }

  private var shown: PaneTranscriptModel? { opened ?? held }

  var body: some View {
    Group {
      if let shown {
        PaneChatView(
          model: shown,
          agentName: agentName,
          screen: screen,
          onOpenImage: { viewingImage = $0 }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { ChatColumn.ground.ignoresSafeArea() }
    .overlay {
      if let viewingImage {
        TranscriptImageViewer(image: viewingImage) { self.viewingImage = nil }
      }
    }
    // Set but not drawn, as on the pane scene's bar: VoiceOver, the back button's long-press
    // menu and the multitasking switcher name the sub-agent.
    .navigationTitle(shown?.subagent?.title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(removing: .title)
    .onChange(of: opened.map(ObjectIdentifier.init)) {
      if let opened { held = opened }
    }
  }
}

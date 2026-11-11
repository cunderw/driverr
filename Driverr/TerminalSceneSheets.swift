import DriverrCore
import SwiftUI
import UIKit

/// The pane scene's sheets, the pane switcher, the chat's sub-agent list and Settings,
/// attached once at `ContentView`'s root for both routes.
///
/// **This exists because the detail column may not present** (CLAUDE.md). The phone's scene
/// is a push, not a presentation, so the root serves both routes. The flags live on
/// `TerminalSceneModel`, so they can be read from here.
struct TerminalSceneSheets: ViewModifier {
  /// The scene whose flags these sheets read, or `nil` when nothing is presented.
  let scene: TerminalSceneModel?
  /// The route the window is on.
  let route: TerminalSceneRoute

  /// The other hosts the switcher can offer, and where a pick on one goes.
  ///
  /// **Passed in, never read from the environment.** A `ViewModifier`'s `@Environment`
  /// resolves above its attachment point, and this modifier sits outside `ContentView`'s
  /// `.environment` lines. It would read a default `ConnectionRegistry` with no hosts
  /// (CLAUDE.md, "Two environment rules").
  let connections: ConnectionRegistry
  let presenter: TerminalPresenter

  @Environment(\.settingsModel) private var settingsModel

  /// The sub-agent a row picked, opened once the list has finished going away. See
  /// `openPickedSubagent()`.
  @State private var pickedSubagent: PickedSubagent?

  private struct PickedSubagent {
    let paneID: String
    let link: SubagentLink
    let title: String
  }

  /// Whether there is a scene for these sheets to be about.
  ///
  /// **Read by the bindings, never a branch around the modifier.** A `@ViewBuilder`
  /// `if`/`else` changes view identity, so the iPad's `NavigationSplitView` would be rebuilt,
  /// losing its state, every time a pane opened or closed. With no scene both bindings
  /// answer `false` and the sheets are inert.
  private var isAttached: Bool { scene != nil }

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: settingsPresentation) {
        SettingsView()
          // Half height, so the terminal whose font is being chosen stays visible.
          //
          // **No `presentationBackgroundInteraction`.** It keeps the terminal first
          // responder, so the keyboard stays up over the sheet and hides the form. Resigning
          // on open does not help; the terminal takes focus straight back.
          .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: panePresentation) {
        paneSheet
      }
      .sheet(isPresented: subagentPresentation, onDismiss: openPickedSubagent) {
        subagentSheet
      }
  }

  /// The pane's own conversation, from the connection's existing models, as `agentStop:` below
  /// reads it. The sheet opens only over a chat that has one.
  private var chatModel: PaneTranscriptModel? {
    guard let scene, let paneID = scene.currentPane?.id else { return nil }
    return connections.existingModel(for: scene.host.id)?.transcripts?.existingModel(for: paneID)
  }

  /// The session's sub-agents, from `chatModel`.
  @ViewBuilder
  private var subagentSheet: some View {
    if let scene, let chatModel {
      SubagentSheetView(
        list: chatModel.subagentList,
        turns: chatModel.transcript?.turns ?? [],
        isRegularWidth: route == .detailColumn,
        onOpen: { row in
          pickedSubagent = PickedSubagent(
            paneID: chatModel.pane.id, link: row.summary.link, title: row.summary.title)
          scene.hideSubagentSheet()
        },
        onDone: { scene.hideSubagentSheet() }
      )
    }
  }

  /// Opens the row the list was closed by, once it is gone, so the chat and the bar under it
  /// do not change while the sheet is still sliding away. Only onto the pane it was picked
  /// on: a scene that closed or moved meanwhile drops the pick.
  private func openPickedSubagent() {
    guard let picked = pickedSubagent else { return }
    pickedSubagent = nil
    guard let chatModel, chatModel.pane.id == picked.paneID else { return }
    // Keyboard down before the phone pushes: Back restores the composer's focus, and the pane
    // screen does not lay out for a keyboard that rises during the pop (composer hidden).
    if route == .stack {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    chatModel.openSubagent(link: picked.link, title: picked.title)
  }

  /// The pane switcher, built from `scene.strip`, the same value the toolbar badge counts,
  /// so the two cannot disagree.
  @ViewBuilder
  private var paneSheet: some View {
    if let scene, let thumbnails = scene.paneThumbnails {
      PaneSheetView(
        hostName: scene.host.displayName,
        model: scene.strip,
        settings: settingsModel.settings,
        thumbnails: thumbnails,
        onSelect: { target in
          scene.select(target)
          scene.hidePaneSheet()
        },
        // It needs a pane to start beside, and Driverr's own pty is not one.
        onNewPane: scene.canStartNewPane
          ? {
            scene.newPane()
            scene.hidePaneSheet()
          }
          : nil,
        // A closure, because dismissing is the scene's business.
        onDone: { scene.hidePaneSheet() },
        // From the registry's existing models, whose trees are already polled, so this
        // opens no channel.
        otherHosts: CrossHostPanes(
          currentHostID: scene.host.id,
          hosts: connections.paneSwitcherHosts()
        ),
        // **Lower the sheet before presenting.** `present` ends the standing scene, and this
        // sheet's binding reads that scene's flag.
        onSelectOnAnotherHost: { hostID, paneID in
          scene.hidePaneSheet()
          presenter.present(hostID: hostID, paneID: paneID)
        },
        // From the route, which knows the window's width. See
        // `PaneSheetView.isRegularWidth`.
        isRegularWidth: route == .detailColumn,
        // A stopped pane's tile shows the stop. Existing models only, so no read starts.
        agentStop: { hostID, pane in
          connections.existingModel(for: hostID ?? scene.host.id)?.transcripts?
            .existingModel(for: pane.id)?.transcript?.agentStop
        }
      )
    }
  }

  /// The pane sheet's `isPresented`, written by hand, not from `@Bindable`, so a swipe-down
  /// and Done both run the scene's close bookkeeping through one tested path. With no scene
  /// it reads `false` and refuses writes; see `isAttached`.
  private var panePresentation: Binding<Bool> {
    Binding(
      get: { isAttached && scene?.isShowingPaneSheet == true },
      set: { raised in
        guard isAttached, let scene else { return }
        raised ? scene.showPaneSheet() : scene.hidePaneSheet()
      }
    )
  }

  /// The sub-agent list's `isPresented`, for the reason above.
  private var subagentPresentation: Binding<Bool> {
    Binding(
      get: { isAttached && scene?.isShowingSubagentSheet == true },
      set: { raised in
        guard isAttached, let scene else { return }
        raised ? scene.showSubagentSheet() : scene.hideSubagentSheet()
      }
    )
  }

  /// Settings' `isPresented`, for the reason above.
  private var settingsPresentation: Binding<Bool> {
    Binding(
      get: { isAttached && scene?.isShowingSettings == true },
      set: { raised in
        guard isAttached, let scene else { return }
        raised ? scene.showSettings() : scene.hideSettings()
      }
    )
  }
}

extension View {
  /// Attaches the pane scene's sheets, inert while there is no scene. Unconditional; see
  /// `TerminalSceneSheets.isAttached`. Called once, at `ContentView`'s root.
  func terminalSceneSheets(
    scene: TerminalSceneModel?,
    route: TerminalSceneRoute,
    connections: ConnectionRegistry,
    presenter: TerminalPresenter
  ) -> some View {
    modifier(
      TerminalSceneSheets(
        scene: scene,
        route: route,
        connections: connections,
        presenter: presenter
      )
    )
  }
}

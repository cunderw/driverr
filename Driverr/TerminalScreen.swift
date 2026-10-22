import DriverrCore
import DriverrSSH
import DriverrTerm
import SwiftUI
import UIKit

/// One host's terminal scene, on screen.
///
/// The screen owns the presentation. `TerminalSceneModel` owns which pane is shown and the
/// warm ones around it, because a rotation or Split View reflow rebuilds this view while
/// several sessions stay alive.
struct TerminalScreen: View {
  @Environment(\.colorScheme) private var colorScheme
  /// Whether the scene is short: a landscape phone, and nothing else this app runs on.
  ///
  /// From the size class, not a width-height comparison, because a `GeometryReader` here
  /// would rebuild the terminal on every keyboard frame. Compact vertical is exactly "phone
  /// turned sideways". See `isComposerCollapsed`.
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.terminalPresenter) private var presenter
  @Environment(\.settingsModel) private var settingsModel
  /// For the pane menu's Start/Stop Live Activity. Read here, because `PaneActionsMenu`
  /// has no host.
  @Environment(\.liveActivityPreferences) private var liveActivityPreferences
  /// For the pane menu's Continue in Background. Read here for the same reason.
  @Environment(\.backgroundWatch) private var backgroundWatch

  let scene: TerminalSceneModel
  /// Which route this screen is drawn on: the phone's stack or the detail column.
  ///
  /// **Passed in, not derived from this view's `horizontalSizeClass`.** A
  /// `NavigationSplitView` gives its columns their own traits, so only `ContentView`, at the
  /// root, can answer for the window. Same reason as `PaneSheetView.isRegularWidth`.
  let route: TerminalSceneRoute

  /// Whether `ContentView` has a sheet or alert up at its root, over this scene. Passed in,
  /// because only the root holds those flags. See `PaneKeyActions.isBehindRootPresentation`.
  var isBehindRootPresentation = false

  private var host: DriverrCore.Host { scene.host }
  private var model: ConnectionModel { scene.model }

  /// The forced notice's own closed flag. `AppEnvironment.isForcingHardwareKeyboardNotice`
  /// bypasses `KeyboardNoticeModel`, so without this the close button could not be tested.
  @State private var isHardwareNoticeDismissed = false
  @FocusState private var isReconnectFieldFocused: Bool
  /// Where the terminal region ends, in window coordinates. The other half of the keyboard
  /// obstruction is where the accessory row starts, which only the terminal can see.
  @State private var terminalRegionBottom: Double = 0
  /// Where `paneSurfaces` ends, in window coordinates.
  ///
  /// A diagnostic, not a layout input. `debug.keyboardMetrics` and
  /// `PaneSwitchUITests.testLandscapeKeepsTheComposerAndTheSegmentReachable` read it, and
  /// that test catches a re-ordered modifier chain.
  ///
  /// Read from the surfaces' own frame, below its floor and clip, where the composer bar is
  /// attached. The content would read taller than the slot in a landscape phone with the
  /// keyboard up.
  @State private var surfacesBottom: Double = 0
  /// Where `paneSurfaces` starts. A block centred in a slot it does not fit overhangs both
  /// edges, so the top says by how much. Read in the same `onGeometryChange` as the bottom,
  /// because two probes can report from different layout passes.
  @State private var surfacesTop: Double = 0
  /// The region the whole pane stack is laid out in: the safe area below the navigation
  /// bar. Nothing inside the stack moves it, so the surfaces' maximum height is safe to
  /// derive from it, and it is the baseline for spotting an overflow.
  @State private var regionTop: Double = 0
  @State private var regionBottom: Double = 0
  /// Where the chat surface is laid out, when there is one. The terminals take whatever
  /// they are offered; the chat's chrome can report more than the slot. A diagnostic, left
  /// stale on the terminal side to save a write per switch.
  @State private var chatTop: Double = 0
  @State private var chatBottom: Double = 0
  /// Where the chat surface's own frame starts horizontally. Tells a sideways content
  /// offset (the scroll view's fault) from a misplaced frame. See `ChatScrollProbe`.
  @State private var chatMinX: Double = 0
  /// The conversation's scroll geometry, reported by `PaneChatView` only on a launch with
  /// `-uiTestingKeyboardMetrics`. See `ChatScrollProbe`.
  @State private var chatScroll = ChatScrollProbe()
  /// Where the reader's place is and who put it there, under the same flag. See
  /// `ChatPlaceProbe`.
  @State private var chatPlace = ChatPlaceProbe()
  /// Where the terminals block starts, in window coordinates.
  @State private var terminalRegionTop: Double = 0
  /// The composer bar's own frame, as a diagnostic only.
  ///
  /// Nothing lays out from it: `safeAreaBar` insets the chat in one layout pass, where a
  /// published height was a frame late. It feeds the `keyboardTop` against
  /// `composerBottom` readout, and is measured only with `-uiTestingKeyboardMetrics`, so a
  /// shipping build never measures the bar.
  @State private var composerFrame: CGRect = .zero
  /// The top of the software keyboard in window coordinates, or `nil` when there is none.
  ///
  /// From the keyboard notification, not a view. With the keyboard up its end frame still
  /// sits below the composer by the bottom safe-area inset.
  @State private var keyboardTop: Double?
  /// Whether the composer has the keyboard, so the chat can return to the newest turn when
  /// the viewport shrinks. Held here because the composer and the chat are siblings.
  @State private var isComposerFocused = false

  /// The chat image being viewed full size, or `nil`.
  ///
  /// Here, not in `PaneChatView`: the composer is a `safeAreaBar` attached around the chat
  /// in `paneSurfaces`, so a viewer drawn inside the chat would sit under the reply field.
  /// It is drawn at the end of this screen's chain instead.
  @State private var viewingImage: TranscriptImage?
  /// What is typed into the inline reconnect prompt. On the screen, not the scene, so a
  /// password does not outlive the bar.
  @State private var reconnectPassword = ""

  var body: some View {
    content
      .navigationTitle(scene.title)
      // Which host this is. Keep it: the phone's system back button is a bare chevron, so
      // without the subtitle the host's name is nowhere on the pane screen. Empty on the
      // detail route, whose back control already names the host. An empty string draws no
      // second line.
      .navigationSubtitle(route == .detailColumn ? "" : (scene.subtitle ?? ""))
      .navigationBarTitleDisplayMode(.inline)
      // The bar sits on the host screen's colour, so the accent glyphs contrast the same.
      // This scene's base fill runs up under the bar, and the glass capsule lightens whatever
      // it sits over, so on that backdrop the accent glyphs fell under the 3:1 non-text
      // floor in dark. The accent may not be dimmed or swapped (CLAUDE.md, Style), so the
      // surface is what changes.
      //
      // **Both lines are needed.** An unscrolled bar's background is hidden and ignores the
      // style alone; `.toolbarBackgroundVisibility(.visible, …)` makes it land.
      .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
      .toolbarBackgroundVisibility(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          // A named back control in the detail column, where the column swapped its content
          // and the way back is the host screen.
          //
          // **Nothing on the phone's stack.** A custom leading item disables the edge-swipe
          // pop (CLAUDE.md). `leavePaneScene` finds the system back button by position.
          if route == .detailColumn {
            Button {
              presenter.dismiss()
            } label: {
              // **An `HStack`, not a `Label`.** A navigation bar draws a `Label` icon-only even
              // with `.titleAndIcon`, which hides the host's name. The accessibility tree
              // keeps the name either way, so only a capture shows this.
              HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                Text(host.displayName)
              }
            }
            // Label-coloured: a text control on the toolbar glass (CLAUDE.md, Style).
            .tint(Color.primary)
            // Spoken as a destination, not a bare host name.
            .accessibilityLabel("Back to \(host.displayName)")
            .accessibilityIdentifier("terminal.back")
          }
        }
        // Absent on a host with no panes, per `PaneStripModel.showsSwitcher`. Otherwise a
        // plain shell grows a button whose sheet holds only the terminal already on screen.
        //
        // **Do not add `|| isLinkDown`.** It would hide the brief empty tree after a
        // reconnect, but it cannot tell that from a host with no herdr session, and would
        // show the button there for the whole outage. `Self.showsPanesButton(strip:)` names
        // the rule so `TerminalScreenPanesButtonTests` can call it; no UI test drops the link.
        if Self.showsPanesButton(strip: scene.strip) {
          ToolbarItem(placement: .primaryAction) {
            Button {
              scene.showPaneSheet()
            } label: {
              // The count of waiting panes, so the reason to open this shows without opening
              // it. See `PanesButtonLabel`.
              PanesButtonLabel(count: scene.strip.blockedElsewhereCount)
            }
            .accessibilityLabel("Panes")
            .accessibilityValue(
              scene.strip.blockedElsewhereCount > 0
                ? Text(scene.strip.blockedElsewhereCount, format: .number) : Text(""))
            // The label stops growing at `.accessibility1`, so a long press shows it large,
            // count included, because the drawn count is what the reader could not see.
            .accessibilityShowsLargeContentViewer {
              let count = scene.strip.blockedElsewhereCount
              Label(
                count > 0 ? "Panes, \(count) waiting" : "Panes",
                systemImage: "square.grid.2x2")
            }
            // Dimmed and inert while the link is down. Opening the sheet would start
            // `pane read` polls against an absent host.
            .opacity(isLinkDown ? 0.45 : 1)
            .disabled(isLinkDown)
            .animation(.default, value: isLinkDown)
            // Glyphs keep the accent, matching the host screen's toolbar glyphs one level up
            // (CLAUDE.md, Style).
            .accessibilityIdentifier("terminal.panes")
          }
        }
        ToolbarItem(placement: .primaryAction) {
          // Accent glyph, as above. `PaneActionsMenu` does not tint itself.
          PaneActionsMenu(
            model: scene.actions,
            liveActivity: settingsModel.settings.liveActivities
              ? LiveActivityMenuItem(
                isStarted: liveActivityPreferences.isStarted(for: host.id),
                toggle: {
                  liveActivityPreferences.setStarted(
                    !liveActivityPreferences.isStarted(for: host.id), for: host.id)
                })
              : nil,
            // Only while connected and no other host holds the run.
            // `BackgroundWatch.isInMenu` owns the rule. The menu hides the item where the host
            // screen dims it, because a `Menu` has nowhere to show the reason.
            //
            // The subject is the pane's title here, because iOS's card names it and the tap
            // came from that pane.
            backgroundWatch: BackgroundWatch.isInMenu(
              isConnected: model.phase == .connected,
              isRunningForAnotherHost: backgroundWatch.isRunningForAnotherHost(than: host.id))
              ? BackgroundWatchMenuItem(
                isRunning: backgroundWatch.isRunning(for: host.id),
                toggle: {
                  backgroundWatch.toggle(
                    host: host,
                    subject: scene.actions?.pane.title ?? host.displayName,
                    session: model)
                })
              : nil,
            onSettings: { scene.showSettings() })
        }
      }
      // No sheets are attached here. `TerminalSceneSheets` attaches them at `ContentView`'s
      // root for both routes, because the detail column must not present.
      //
      // Every tree change gives the scene a chance to adopt a split's new pane; see
      // `TerminalSceneModel.newPane()`.
      .onChange(of: model.session?.tree ?? .empty) { _, _ in
        scene.treeChanged()
      }
      // Only `start()`, which needs no balancing half: a second call from a rebuilt view
      // returns early. The retain/release pairs live in `TerminalPresenter.beginPresentation`.
      .task { scene.start() }
      // The keyboard's end frame, since nothing in the view tree can see it.
      // `willChangeFrame` carries the end frame, so it lands in the same layout pass the
      // keyboard animates into.
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
      ) { note in
        guard
          let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        // A keyboard on its way out reports a frame at or below the screen's bottom, which
        // must not count as a position.
        //
        // The screen comes from the window scene, not the deprecated `UIScreen.main`. The
        // notification's frame is in that scene's coordinates.
        let screenBottom =
          (note.object as? UIScreen)?.bounds.maxY
          ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.maxY }
            .first
          ?? .greatestFiniteMagnitude
        keyboardTop = frame.minY >= screenBottom ? nil : Double(frame.minY)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
      ) { _ in
        keyboardTop = nil
      }
      .overlay(alignment: .topLeading) { keyboardMetricsReadout }
      // Hardware key commands, behind the content because nothing here is seen or touched.
      .background { keyCommands }
      // The rest, in the Pane menu. See `PaneCommands`.
      .focusedSceneValue(\.paneKeyActions, paneKeyActions)
  }

  private var settings: TerminalSettings { settingsModel.settings }

  @ViewBuilder
  private var content: some View {
    ZStack(alignment: .bottom) {
      // **Chrome order.** The segment is the only permanent band, so it comes first and no
      // banner appearing or leaving can move it under the user's thumb. Below it, widest
      // subject first: the connection (while the link is down nothing about a pane is true),
      // then the per-pane banners, then the keyboard notice, which is about the terminal's
      // input and sits next to it.
      VStack(spacing: 0) {
        // Under the navigation bar, not in its principal slot, which would take the title
        // slot with it. See `surfaceSegment`.
        surfaceSegment
        connectionBar
        closedPaneBanner
        // Inline, not an alert: the detail column must not present (CLAUDE.md). See
        // `PanePromptBar`.
        if let actions = scene.actions { PanePromptBar(model: actions) }
        scenePromptBar
        hardwareKeyboardNotice
        // The composer is a `safeAreaBar` on the chat layer inside `paneSurfaces`; see there.
        //
        // **Not `.ignoresSafeArea()` on the bar or a stack child.** That aligns `.bottom`
        // against the screen's edge, and the card sat the home indicator's height under the
        // keys. A bar in the safe area rises with the keyboard.
        paneSurfaces
          // A floor the chrome cannot push through. The surfaces are the one flexible child,
          // so they absorb every banner. In landscape with the keyboard up, enough bands would
          // squeeze them to zero height, which nothing recovers. With a floor the chrome
          // overflows instead, which dismissing the keyboard recovers.
          //
          // A `.frame(minHeight:)` does not compress a child that will not fit: it centres it
          // and lets it hang off both ends. The surfaces plus the composer overhung upward over
          // the segment band, and the way back to the terminal was not drawn.
          //
          // **Do not fix that with `alignment: .top`. It hangs the app.** The block then no
          // longer fills its slot, the terminal's measure-and-pad loop stops converging, and
          // the app never reports idle (`PaneSwitchUITests.testDoneStillDismissesAfterSwitchingPanes`
          // times out). `.zIndex` does not help, because it is layout, not paint order.
          //
          // The fix is that nothing needs squeezing. In the one posture with no room (landscape
          // phone, keyboard up) the composer collapses to one row (`isComposerCollapsed`), the
          // floor gives way with it (`surfaceFloor`), and the segment band hides so the
          // conversation gets its height. Portrait always fits.
          .frame(minHeight: surfaceFloor)
          // **Everything below this frame is attached to the slot; everything above it to the
          // surfaces' own content.** The frame is the region the surfaces were given, and
          // `.clipped()` below hides the overhang.
          //
          // Two rules follow, and a violation compiles and passes every frame assertion:
          //
          // - Keep this probe below the frame. Above it, it reads the overflowing content,
          //   not the slot.
          // - Do not attach the composer to this chain. A `safeAreaBar` insets every child
          //   of what it is attached to, which here would include the terminals, and
          //   `DriverrTerminalView.sizeChanged` would resize the remote pane by the composer's
          //   height. The bar is on the chat layer in `paneSurfaces`, with a frame of its own
          //   pinning it to the slot.
          //
          // Only `PaneSwitchUITests.testLandscapeKeepsTheComposerAndTheSegmentReachable` catches
          // a re-order, by reading these probes on the device (including its `terminalBottom`
          // check). `PaneSurfaceLayoutTests` models the shapes on a fixture and does not guard
          // this chain.
          //
          // The probe is a diagnostic, not a layout input, and is attached only when
          // `isReportingKeyboardMetrics`; see `SurfaceGeometryProbe`. A probe on the composer
          // feeding the composer's own layout would be a feedback loop.
          .modifier(
            SurfaceGeometryProbe(
              report: Self.isReportingKeyboardMetrics
                ? { surfacesTop = Double($0.minY); surfacesBottom = Double($0.maxY) }
                : nil
            )
          )

          // **A clip over the whole slot.** Content that does not fit is centred and would
          // paint over the segment band. In portrait nothing overflows and this does nothing.
          //
          // It must stay at the slot's bottom, below where the composer bar attaches. A clip
          // above the bar would cut the conversation at the card's top edge, leaving the glass
          // nothing to blur. `ChatGlassLayoutTests` cannot see that, because a clip on an
          // ancestor is a render mask, not a frame change; only a capture shows it.
          .clipped()
          // The last frame stays, dimmed, while the link is down. A blank surface would read as
          // the pane being gone.
          .opacity(isLinkDown ? 0.45 : 1)
          .animation(.default, value: isLinkDown)
      }
      // The slot everything above is laid out in. Bounded by its parent, so it is the
      // baseline `keyboardMetricsReadout` judges every overflow against.
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
        regionTop = Double($0.minY)
        regionBottom = Double($0.maxY)
      }
      statusBanner
    }

    // A full-bleed fill, so a landscape phone's side safe areas paint in the terminal's
    // colour.
    //
    // **A `.background`, not a `ZStack` child.** A child with `.ignoresSafeArea()` expands
    // the stack, and `alignment: .bottom` then aligns to the screen's edge, putting the
    // composer behind the keyboard's accessory row.
    //
    // The chat side gets the system background, not the terminal theme, because the chat's
    // translucent chrome blends with what is behind it.
    .background {
      (isShowingChat
        ? ChatColumn.ground
        : settings.theme.surfaceColor(for: colorScheme == .dark ? .dark : .light))
        .ignoresSafeArea()
    }
    // The full-size image, last in the chain so it covers the composer too.
    //
    // An overlay, not a sheet; see `TranscriptImageViewer`. It leaves the navigation bar
    // visible, because hiding the bar would move the region under the viewer.
    .overlay {
      if let viewingImage {
        TranscriptImageViewer(image: viewingImage) { self.viewingImage = nil }
      }
    }
    // An image belongs to its pane and surface, and `@State` survives both changes.
    .onChange(of: scene.currentPane?.id) { previous, _ in
      viewingImage = nil
      // A sub-agent opened in the pane being left closes with it. The chat view now holds
      // the next pane's model and cannot reach this one.
      if let previous { model.transcripts?.existingModel(for: previous)?.closeAllSubagents() }
    }
    .onChange(of: isShowingChat) { viewingImage = nil }
    // Leaving the scene closes a sub-agent too, so a return finds the pane's own chat.
    .onDisappear {
      if let pane = scene.currentPane {
        model.transcripts?.existingModel(for: pane.id)?.closeAllSubagents()
      }
    }
  }

  // MARK: - Chat or terminal

  /// Whether this pane gets a `Chat | Terminal` segment: if and only if it has an agent,
  /// even with an unreadable transcript. A shell pane opens straight into the terminal.
  ///
  /// The rule and the selection live on the scene, because the surface decides whether the
  /// pane holds the attach token or an observer.
  private var showsSurfaceSegment: Bool { scene.showsSurfaceSegment }

  private var surface: PaneSurface { scene.surface }

  /// Whether the chat is on screen. Needs both models as well as the selection, so a
  /// cleared cache falls back to the terminal, and `Show the screen` always has a screen
  /// model behind it.
  private var isShowingChat: Bool {
    surface == .chat && chatModel != nil && screenModel != nil
  }

  /// This pane's conversation, from the connection's cache. See `PaneTranscriptCache` for
  /// why reading it from a body is safe.
  private var chatModel: PaneTranscriptModel? {
    guard let pane = scene.currentPane, pane.agent != nil else { return nil }
    return model.transcripts?.model(for: pane)
  }

  /// This pane's composer, from the connection's cache, so a failed reply survives the
  /// bar being rebuilt by a switch to Terminal and back.
  private var composerModel: PaneComposerModel? {
    guard let pane = scene.currentPane, pane.agent != nil else { return nil }
    return model.composers?.model(for: pane)
  }

  /// The reply surface, under either chat-side surface. Here, not in `PaneChatView`, so it
  /// sits under the captured screen too.
  ///
  /// **Not on the Terminal side**, where the pane already has a keyboard and the attach
  /// token, and a second input with different rules would conflict.
  ///
  /// An ordinary bar that presents nothing.
  @ViewBuilder
  private var paneComposer: some View {
    // No composer while a sub-agent's chat is shown: a reply would go to the pane's agent.
    if isShowingChat, chatModel?.isShowingSubagent != true, let composerModel,
      let pane = scene.currentPane
    {
      PaneComposerBar(
        model: composerModel,
        // Mined for the `/` list. `nil` when there is nothing to offer.
        transcript: chatModel?.transcript,
        // What the host has installed, the other half of the `/` list.
        catalog: chatModel?.skillCatalog ?? .empty,
        // From the live pane, not the cached model's copy, so the sentence follows status.
        header: PaneComposerHeader(pane: pane),
        takeFocusRequest: { scene.takeComposerFocusRequest() },
        // A pane asking its own question keeps the keyboard down, so its chips are not
        // under it. Waits for the chat's read, and on a blocked pane for the screen read
        // that can find a question the file lacks.
        focusGate: ComposerFocusGate(
          isSettled: (chatModel.map { !$0.isLoading && $0.state != .idle } ?? true)
            && (pane.agent?.status != .blocked || screenModel?.hasReadForQuestion == true
              || chatModel?.transcript?.pendingToolCall?.asksItsOwnQuestions == true),
          pendingCall: chatModel?.transcript?.questionCall(
            screen: screenModel?.screenForQuestion, agentStatus: pane.agent?.status)
        ),
        onFocusChange: { isComposerFocused = $0 },
        // `nil` in shipping builds. See `composerFrame`.
        onLayoutProbe: Self.isReportingKeyboardMetrics ? { composerFrame = $0 } : nil,
        isCollapsed: isComposerCollapsed,
        // The bar cannot present a `PhotosPicker` from the detail column, so the scene asks
        // `ContentView`'s root to.
        onAttach: { scene.requestImageAttachment() }
      )
    }
  }

  /// Whether this launch asked for `keyboardMetricsReadout`. A name, because both the
  /// readout and `PaneChatView`'s scroll observer check it.
  ///
  /// False in Release, which reads no argument. `isShowingKeyboardMetrics` exists in `DEBUG`
  /// only, like its one reader.
  #if DEBUG
  static let isReportingKeyboardMetrics =
    ProcessInfo.processInfo.arguments.contains("-uiTestingKeyboardMetrics")

  /// Whether the readout is also drawn on screen, so a device screenshot carries the
  /// numbers. `DEBUG` only, and it also needs `-uiTestingKeyboardMetrics`. Decided at
  /// launch, because a branch that flips at run time changes view identity. Not a Settings
  /// toggle (CLAUDE.md, "Not a config surface").
  static let isShowingKeyboardMetrics =
    isReportingKeyboardMetrics
    && ProcessInfo.processInfo.arguments.contains("-uiTestingKeyboardMetricsVisible")
  #else
  static let isReportingKeyboardMetrics = false
  #endif

  /// Where the keyboard is, for a test that cannot see it.
  ///
  /// `app.keyboards.firstMatch.frame` starts 44 pt below the keyboard's drawn top, because
  /// the candidate row is drawn by the keyboard process, so a clearance assertion against it
  /// can never fail. The app publishes the numbers it lays out against through the
  /// accessibility tree, since app-side `print` never reaches the gate log (CLAUDE.md).
  ///
  /// Behind `-uiTestingKeyboardMetrics`, not `-uiTesting`, so the other UI classes do not
  /// carry an extra element.
  @ViewBuilder private var keyboardMetricsReadout: some View {
    if Self.isReportingKeyboardMetrics {
      metricsCarrier
        .accessibilityElement()
        .accessibilityIdentifier("debug.keyboardMetrics")
        .accessibilityLabel(keyboardMetricsLabel)
    }
  }

  /// What carries the readout: a 1×1 `Color.clear` that the gates read, or the same string
  /// drawn small; see `isShowingKeyboardMetrics`. No identified ancestor, so the identifier
  /// survives.
  ///
  /// **It must not inset or intercept anything**, or it changes what it measures. So it is
  /// `.fixedSize` inside an overlay, with `.allowsHitTesting(false)`. Do not add
  /// `.accessibilityHidden`: the label is what the gates read.
  @ViewBuilder private var metricsCarrier: some View {
    #if DEBUG
      if Self.isShowingKeyboardMetrics {
        Text(keyboardMetricsLabel.replacingOccurrences(of: " ", with: "\n"))
          .font(.system(size: 8, design: .monospaced))
          .foregroundStyle(.primary)
          .padding(4)
          .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
          .fixedSize()
          .allowsHitTesting(false)
      } else {
        Color.clear.frame(width: 1, height: 1)
      }
    #else
      Color.clear.frame(width: 1, height: 1)
    #endif
  }

  /// The readout as one string, so the accessibility label and the visible overlay cannot
  /// drift apart.
  private var keyboardMetricsLabel: String {
    "keyboardTop=\(keyboardTop.map { String(format: "%.2f", $0) } ?? "nil") "
      + "surfacesBottom=\(String(format: "%.2f", surfacesBottom)) "
      + "regionTop=\(String(format: "%.2f", regionTop)) "
      + "regionBottom=\(String(format: "%.2f", regionBottom)) "
      + "surfacesTop=\(String(format: "%.2f", surfacesTop)) "
      + "terminalTop=\(String(format: "%.2f", terminalRegionTop)) "
      + "terminalBottom=\(String(format: "%.2f", terminalRegionBottom)) "
      + "chatTop=\(String(format: "%.2f", chatTop)) "
      + "chatBottom=\(String(format: "%.2f", chatBottom)) "
      + "composerHeight=\(String(format: "%.2f", composerFrame.height)) "
      // The card's measured bottom edge, so `keyboardTop` minus this is the keyboard
      // deficit. Zero on a simulator; see `isComposerCollapsed` for the hardware case.
      + "composerBottom=\(String(format: "%.2f", composerFrame.maxY)) "
      // `chatMinX` is the surface's frame; the `chatContent*` fields are the scroll view's
      // own geometry. See `ChatScrollProbe`.
      + "chatMinX=\(String(format: "%.2f", chatMinX)) "
      + "chatContentOffsetX=\(String(format: "%.2f", chatScroll.contentOffsetX)) "
      + "chatContentWidth=\(String(format: "%.2f", chatScroll.contentWidth)) "
      + "chatContainerWidth=\(String(format: "%.2f", chatScroll.containerWidth)) "
      + "chatContentHeight=\(String(format: "%.2f", chatScroll.contentHeight)) "
      // The conversation's inset and the two numbers it derives from. See
      // `ChatCollectionView.Coordinator.applyBottomInset`.
      + "chatInsetBottom=\(String(format: "%.2f", chatScroll.insetBottom)) "
      + "chatBoundsHeight=\(String(format: "%.2f", chatScroll.boundsHeight)) "
      + "chatSlotHeight=\(String(format: "%.2f", chatScroll.slotHeight)) "
      // A `chatDistanceFromEnd` well past `ChatEndProximity.jumpTolerance` with
      // `chatHasStandingTarget=true` means a stale scroll target is re-applied on every
      // layout pass. With `false` it is a reader who scrolled back.
      // `chatPositionedByUser` says which moved the content last; it is reported, not acted
      // on.
      //
      // The parser in `DriverrUITests/UITestSupport.swift` ignores unknown keys, so new
      // fields break no test.
      + "chatDistanceFromEnd=\(String(format: "%.2f", chatPlace.distanceFromEnd)) "
      + "chatPositionedByUser=\(chatPlace.isPositionedByUser) "
      + "chatHasStandingTarget=\(chatPlace.hasStandingTarget) "
      + "grid=\(gridDescription)"
  }

  /// The grid SwiftTerm last reported to the far side over SIGWINCH, for comparing against
  /// the visible region in a gate.
  private var gridDescription: String {
    guard let size = scene.session(for: scene.current)?.reportedSize else { return "none" }
    return "\(size.columns)x\(size.rows)"
  }

  /// The one state with no room for a two-row composer: a landscape phone with the keyboard
  /// up, which leaves about 100 pt. The composer collapses to one row, and the segment band
  /// hides (`surfaceSegment`), so the conversation keeps some height. Both inputs are values
  /// this screen already tracks.
  ///
  /// **Keyboard facts no simulator shows.** On hardware the keyboard's end frame sits about
  /// 31 pt (the home indicator's inset) higher than a composer laid out on the safe area
  /// alone. The simulator reads 0. If the card ever runs under the keys on a device, correct
  /// it inside `PaneComposerBar`, bounded, and read `keyboardTop` against `composerBottom` in
  /// `debug.keyboardMetrics`. `UIWindow.keyboardLayoutGuide` reports the window's bottom with
  /// the keyboard up and is no use here.
  ///
  /// Not guaranteed: the interrupt confirmation and any banner raised while collapsed
  /// still ask for more than the region. The clip keeps them inside it, and the conversation
  /// gives way.
  private var isComposerCollapsed: Bool {
    verticalSizeClass == .compact && keyboardTop != nil
  }

  /// The surfaces' floor: `minimumSurfaceHeight`, or zero when collapsed. There a floor
  /// would overflow the small region on its own, and with the band hidden the surfaces
  /// still get about 46 pt.
  private var surfaceFloor: CGFloat {
    isComposerCollapsed ? 0 : Self.minimumSurfaceHeight
  }

  /// What the conversation says about itself at its foot. `ChatActivity` owns the rule. A
  /// blocked pane says nothing here, because the conversation already shows the question
  /// and its chips.
  private var chatActivity: ChatActivity? {
    guard let pane = scene.currentPane else { return nil }
    return ChatActivity(
      header: PaneComposerHeader(pane: pane),
      status: composerModel?.status
    )
  }

  /// This pane's captured screen, from the connection's cache, so it survives the chat
  /// surface being rebuilt.
  private var screenModel: PaneScreenModel? {
    guard let pane = scene.currentPane, pane.agent != nil else { return nil }
    return model.paneScreens?.model(for: pane)
  }

  /// The `Chat | Terminal` segment. **Hidden while `isComposerCollapsed`.** Otherwise the
  /// conversation gets about 3 pt and paints over the band. Dismissing the keyboard or
  /// turning the phone upright brings it back.
  @ViewBuilder
  private var surfaceSegment: some View {
    if showsSurfaceSegment && !isComposerCollapsed {
      Picker(
        "Surface",
        selection: Binding(
          get: { surface },
          set: { scene.show($0) }
        )
      ) {
        // Identifiers on the segments, never on the `Picker`, which would overwrite them.
        Text("Chat").tag(PaneSurface.chat)
          .accessibilityIdentifier("pane.surface.chat")
        Text("Terminal").tag(PaneSurface.terminal)
          .accessibilityIdentifier("pane.surface.terminal")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // **The picker takes the readable measure; the band spans the full width.** An
      // uncapped picker on a wide iPad dwarfs the conversation it switches, and a capped
      // band leaves the toolbar controls floating either side of it.
      .readableColumn(route)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity)
      // The navigation bar's colour, not a material, which drew a third grey between the
      // bar and the content. The `Divider` separates the band from the conversation.
      .background(Color(.systemGroupedBackground))
      .overlay(alignment: .bottom) { Divider() }
    }
  }

  /// The two surfaces: the terminals always laid out, the chat drawn over them.
  ///
  /// **The terminals are never torn down by the switch.** An `if` would take their
  /// emulators with it, and the pane would reopen cold after every read of the chat.
  ///
  /// The chat is a plain `if`. Hidden with `opacity` and `.accessibilityHidden`, its
  /// rows stayed in the accessibility tree over the terminal. Rebuilding it costs only a
  /// scroll position, because the transcript is cached on the connection.
  @ViewBuilder
  private var paneSurfaces: some View {
    ZStack {
      terminals
      if isShowingChat, let chatModel, let screenModel {
        // A flexible `Color.clear` takes the slot exactly, and an overlay cannot change its
        // parent's frame, so the composer bar below stays pinned to the slot's bottom edge.
        Color.clear.overlay(alignment: .bottom) {
          PaneChatView(
            model: chatModel,
            agentName: scene.currentPane?.agent?.name ?? "Agent",
            // The pane's captured screen: the exit from every chat failure, and the Chat side
            // for agents with no transcript reader. Reading it stays on `.chat` and uses its
            // own `pane read` channel, so it never takes the attach token.
            screen: screenModel,
            // The chat renders the pending question's options; the composer sends them.
            onSendReply: composerModel.map { model in { chip in Task { await model.send(chip) } } },
            onScreenQuestionAdvanced: composerModel.map { model in { model.transcriptAdvanced() } },
            isSending: composerModel?.isSending ?? false,
            // Built here because it needs the live pane and the composer's send state.
            activity: chatActivity,
            onRetry: composerModel.map { model in { Task { await model.retry() } } },
            // **The keyboard is dismissed first.** It is drawn in its own window, so no
            // overlay can cover it, and the composer's focus is `PaneComposerBar`'s own
            // `@FocusState`. Focus is not restored on close; the typed text survives on the
            // model, and a tap brings the keyboard back.
            onOpenImage: { image in
              UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
              viewingImage = image
            },
            isComposerFocused: isComposerFocused,
            // The one posture where scrolling may dismiss the keyboard, because that brings
            // the hidden segment band back.
            isComposerCollapsed: isComposerCollapsed,
            // `nil` unless the readout was asked for. See `ChatScrollProbe`.
            onScrollGeometry: Self.isReportingKeyboardMetrics ? { chatScroll = $0 } : nil,
            onPlaceChange: Self.isReportingKeyboardMetrics ? { chatPlace = $0 } : nil
          )
          // A readable measure on the detail route, centred by the `ZStack`. Never on the
          // terminal: its width is the remote pane's, and narrowing it would reflow the PTY.
          .readableColumn(route)
          // The composer, on the conversation only, pinned to the slot.
          //
          // - **Not on `paneSurfaces`' chain.** A `safeAreaBar` insets every child of what it
          //   is attached to, so the terminals would shrink by the composer's height and
          //   `DriverrTerminalView.sizeChanged` would resize the remote pane.
          // - Inside the `Color.clear` overlay. On the conversation alone, the bar's
          //   proposal is the conversation's height; in landscape the composite overflows and
          //   `.frame(minHeight:)` centres the overflow across both edges. The overlay keeps
          //   the bottom edge on the slot, so an overflow goes upward, where `.clipped()`
          //   hides it.
          // - Do not re-try `.frame(maxHeight: .infinity, alignment: .bottom)`. It reports
          //   its content's height when the content will not fit, so it does not clamp.
          // - Do not re-try `.ignoresSafeArea(.container, edges: .bottom)` on `terminals`.
          //   The grid runs under the home indicator and reports hidden rows to the far side.
          //
          // `ChatComposerBarPlacementTests` measures this placement against the bar on the
          // conversation without the overlay; the other rejected shapes are prose there.
          // `outsetBy` gives back the insets
          // `PaneComposerBar.barContent` adds, or it is capped twice; see
          // `readableColumn(_:outsetBy:)`. The device check is
          // `PaneSwitchUITests.testLandscapeKeepsTheComposerAndTheSegmentReachable`.
          .safeAreaBar(edge: .bottom, spacing: 0) {
            paneComposer.readableColumn(route, outsetBy: ChatColumn.inset * 2)
          }
          // Which child of this `ZStack` reports more than the slot. Gated, diagnostic only.
          .modifier(
            SurfaceGeometryProbe(
              report: Self.isReportingKeyboardMetrics
                ? {
                  chatTop = Double($0.minY)
                  chatBottom = Double($0.maxY)
                  chatMinX = Double($0.minX)
                }
                : nil
            )
          )
        }
      }
    }
    // No fetch starts here. `PaneChatView` asks on appearance, the only moment the session
    // tree is sure to have arrived; a trigger here could fire before the pane's agent is
    // known and leave a spinner nothing resolves.
  }

  /// One terminal view per warm entry, all in the hierarchy, only the current one visible.
  ///
  /// **The hidden ones are laid out, not just retained**, so an observed pane's emulator is
  /// fed at the phone's size and paints at once when chosen. Hidden by `opacity`, not `if`,
  /// which would destroy the emulator. They are not hit-testable, hidden from
  /// accessibility (so a test finds the visible `terminal.view`), and never take the
  /// keyboard.
  @ViewBuilder
  private var terminals: some View {
    ZStack {
      // In the same stack, so warm views keep their full size while a cold pane opens.
      if scene.isOpening {
        ProgressView("Opening…")
          .accessibilityIdentifier("terminal.progress")
      }
      ForEach(scene.orderedEntries) { entry in
        // A terminal behind the chat is treated as not current, for the same three rules.
        let isCurrent = entry.target == scene.current && !isShowingChat
        DriverrTerminalView(
          session: entry.session,
          settings: settings,
          focusRequest: scene.focusRequest,
          wantsKeyboardFocus: isCurrent,
          keyboardNotice: scene.keyboardNotice,
          copyNotice: scene.copyNotice,
          // Read in this body, not in the representable. `updateUIView` does not establish
          // observation, so the row would not react to a keyboard being plugged in.
          showsAccessoryRow: scene.keyboardNotice.showsAccessoryRow,
          accessibilityIdentifier: isCurrent ? "terminal.view" : "terminal.view.warm"
        )
        .opacity(isCurrent ? 1 : 0)
        .allowsHitTesting(isCurrent)
        .accessibilityHidden(!isCurrent)
      }
    }
    // **Not `.ignoresSafeArea(.container, edges: .bottom)`.** SwiftTerm sizes its grid from
    // the view's bounds and reports the rows over SIGWINCH, so rows under the home indicator
    // would be counted but unseen. The fill behind already paints edge to edge.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The keyboard accessory row iOS left inside the safe area; see
    // `KeyboardNoticeModel.obstruction(forRegionEndingAt:)`.
    .padding(.bottom, scene.keyboardNotice.obstruction(forRegionEndingAt: terminalRegionBottom))
    // **Measured outside the padding, which is why it converges.** The block still takes
    // all the height left, so this number describes the safe area, not the inset derived
    // from it. From layout, not the keyboard notification, which can disagree.
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      terminalRegionTop = Double($0.minY)
      terminalRegionBottom = Double($0.maxY)
    }
    // A gutter, so the first column is off the display edge. The grid is measured inside
    // it, so no counted column is hidden.
    .padding(.horizontal, Self.terminalGutter)
    // **Width from the container, not the `VStack`.** A `VStack` is as wide as its widest
    // child, so a chrome row too wide at large text sizes dragged the terminal off both
    // edges, and the far side was told about columns nobody could see.
    .containerRelativeFrame(.horizontal)
    // Over the terminals, not a band above them. See `copyNoticeOverlay`.
    .copyNoticeOverlay(scene.copyNotice)
  }

  /// The least the conversation or terminal may be squeezed to: about three terminal lines.
  /// Not scaled with text size, because it is a floor against chrome, and growing it would
  /// push chrome off a landscape phone.
  ///
  /// Not `private`, so `PaneSurfaceLayoutTests` binds to it rather than copying it.
  static let minimumSurfaceHeight: CGFloat = 64

  /// The gutter down each side of the grid. The theme's fill shows through it.
  private static let terminalGutter: CGFloat = 8

  /// Whether the connection is gone: reconnecting, waiting for a password, or given up.
  /// Everything it greys out talks to the host.
  private var isLinkDown: Bool {
    switch scene.notice {
    case .reconnecting?, .needsPassword?, .disconnected?: true
    default: false
    }
  }

  // MARK: - Hardware keys

  /// The two keys the Pane menu cannot carry, ⌘, (not on iPad) and Escape, as tiny buttons
  /// behind the content. The rest are in `PaneCommands`, which says why these two stayed.
  ///
  /// **Buttons with `.keyboardShortcut`, not `onKeyPress` or `UIKeyCommand`.** A device
  /// probe found every key reached a `.keyboardShortcut` button, and Escape reached nothing
  /// else.
  ///
  /// Escape and ⌘, have no UI test: XCUITest does not deliver Escape to a SwiftUI field, and
  /// ⌘, did not arrive over an open pane. The Escape rule is asserted as a value in
  /// `DriverrTests`. Read `PaneKeyCommandUITests`' class comment before changing a shortcut.
  ///
  /// Keep the 1 pt frame and near-zero opacity, the shape the probe verified. `.hidden()`
  /// removes the view from layout, and its shortcut is not reliable then.
  @ViewBuilder
  private var keyCommands: some View {
    ZStack {
      // ⌘, opens the scene's Settings sheet, not on iPad; see `KeyCommand.isSettingsBound`.
      // `ContentView.settingsShortcut` binds ⌘, only when there is no scene, so exactly one
      // binding is live.
      if KeyCommand.isSettingsBound {
        Button(KeyCommand.settings.title) { scene.showSettings() }
          .keyboardShortcut(KeyCommand.settings.shortcut)
      }

      // Escape only when there is something to close. Otherwise the button is absent and
      // the key reaches SwiftTerm, because remote programs need it. It never leaves the
      // pane scene.
      if let action = escapeAction {
        Button(KeyCommand.dismiss.title) { perform(action) }
          .keyboardShortcut(KeyCommand.dismiss.shortcut)
      }
    }
    .frame(width: 1, height: 1)
    .opacity(0.01)
    // Not for readers. The system's shortcut list reads the titles from the key commands.
    .accessibilityHidden(true)
  }

  /// The keys the Pane menu carries, acting on this scene. Only `.commands` reaches the
  /// iPadOS menu bar. See `PaneCommands`; `PaneKeyCommandUITests` presses every key.
  private var paneKeyActions: PaneKeyActions {
    PaneKeyActions(
      // ⌘1 to ⌘9: the switcher's places in sheet order. Keys past the end are no-ops.
      goToPlace: { index in
        guard let target = scene.strip.target(atShortcutIndex: index) else { return }
        scene.select(target)
      },
      // ⌘⇧] and ⌘⇧[: the neighbours, wrapping. See `PaneStripModel.target(after:)`.
      nextPane: {
        guard let target = scene.strip.target(after: scene.current) else { return }
        scene.select(target)
      },
      previousPane: {
        guard let target = scene.strip.target(before: scene.current) else { return }
        scene.select(target)
      },
      // ⌘⇧T toggles the segment. Shifted, so ⌘T stays free for "new tab". Gated on the pane
      // having two surfaces, not on the segment being drawn, so it works while the segment
      // is collapsed away.
      surfaceCommand: scene.showsSurfaceSegment
        ? (surface == .chat ? .showTerminal : .showChat) : nil,
      toggleSurface: { scene.show(surface.toggled) },
      // A `focusedSceneValue` is scene-wide, so the menu is still live while the scene
      // presents over itself. The pane's own keys go quiet then; see `PaneKeyActions`.
      isPresenting: scene.isShowingPaneSheet || scene.isShowingSettings
        || scene.isShowingPhotoPicker,
      isBehindRootPresentation: isBehindRootPresentation,
      commandW: commandW,
      // ⌘W closes what is up over the scene, or else leaves it, through
      // `TerminalPresenter.dismiss()` like the back control and the phone's pop.
      performCommandW: {
        switch commandW {
        case .closeSwitcher: scene.hidePaneSheet()
        case .closeSettings: scene.hideSettings()
        case .closePhotos: scene.hidePhotoPicker()
        default: presenter.dismiss()
        }
      }
    )
  }

  /// What ⌘W does now. `KeyCommand.commandW` owns the rule.
  private var commandW: KeyCommand {
    KeyCommand.commandW(
      isShowingPaneSheet: scene.isShowingPaneSheet,
      isShowingSettings: scene.isShowingSettings,
      isShowingPhotoPicker: scene.isShowingPhotoPicker
    )
  }

  /// What Escape closes on this screen now, or `nil` when the key must reach the terminal.
  /// A value, so `TerminalScreenEscapeTests` can assert it; XCUITest cannot send Escape.
  enum EscapeAction: Equatable {
    case closePaneSheet
    case closeSettings
    case dismissPrompt
  }

  /// The rule.
  ///
  /// - Parameter terminalHoldsKeyboard: whether typing would reach the terminal. The sheets
  ///   ignore it, because a sheet takes first responder whatever the surface says.
  static func escapeAction(
    isShowingPaneSheet: Bool,
    isShowingSettings: Bool,
    hasPrompt: Bool,
    terminalHoldsKeyboard: Bool
  ) -> EscapeAction? {
    if isShowingPaneSheet { return .closePaneSheet }
    if isShowingSettings { return .closeSettings }
    // The prompt bar is inline, so the terminal may still hold the keyboard, and then
    // Escape belongs to the far side.
    if hasPrompt && !terminalHoldsKeyboard { return .dismissPrompt }
    return nil
  }

  private var escapeAction: EscapeAction? {
    Self.escapeAction(
      isShowingPaneSheet: scene.isShowingPaneSheet,
      isShowingSettings: scene.isShowingSettings,
      hasPrompt: scene.actions?.prompt != nil,
      terminalHoldsKeyboard: terminalHoldsKeyboard
    )
  }

  /// Whether typing would reach the terminal: not when the chat is showing or the prompt's
  /// rename field has the keyboard. Other prompt variants have no field.
  private var terminalHoldsKeyboard: Bool {
    if isShowingChat { return false }
    if case .rename = scene.actions?.prompt { return false }
    return true
  }

  private func perform(_ action: EscapeAction) {
    switch action {
    case .closePaneSheet: scene.hidePaneSheet()
    case .closeSettings: scene.hideSettings()
    case .dismissPrompt: scene.actions?.dismissPrompt()
    }
  }

  /// Whether the Panes toolbar item belongs on screen. Static so `DriverrTests` can call it.
  /// **Takes no link state**; see the call site and `TerminalScreenPanesButtonTests`.
  static func showsPanesButton(strip: PaneStripModel) -> Bool {
    strip.showsSwitcher
  }

  /// The pane is gone, so say so rather than dismiss under the reader's thumb. The way out
  /// is in the toolbar.
  @ViewBuilder
  private var closedPaneBanner: some View {
    // Closed from the menu, or ended by herdr for a reason other than another device.
    if scene.actions?.didClose == true || scene.paneWasClosed || scene.notice == .closed {
      // With a next step, naming the pane it goes to, because every other control now
      // addresses a pane that is gone.
      if let next = scene.nearestLivePane {
        noticeBar(
          "This pane was closed.",
          textIdentifier: "terminal.pane.closed",
          action: "Go to \(next.title)",
          actionIdentifier: "terminal.pane.closed.goTo"
        ) {
          scene.select(.pane(id: next.id))
        }
      } else {
        Text("This pane was closed.")
          .font(.footnote)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity)
          .background(.thinMaterial)
          .accessibilityIdentifier("terminal.pane.closed")
      }
    }
  }

  /// What the scene has to say about two clients on one pane, or a failed open.
  ///
  /// Inline, like `PanePromptBar`, not an alert, because the detail column must not present.
  /// Separate from
  /// `PaneActionsModel.Prompt`, which must not know the bridge exists. No identifier on the
  /// container.
  @ViewBuilder
  private var scenePromptBar: some View {
    switch scene.notice {
    case .refused?:
      noticeBar(
        "Another device is controlling this pane.",
        textIdentifier: "terminal.pane.refused",
        action: "Take Over",
        actionIdentifier: "terminal.takeover"
      ) {
        scene.takeOver()
      }
    case .takenOver?:
      noticeBar(
        "Another device took control of this pane.",
        textIdentifier: "terminal.pane.takenOver",
        action: "Take Back",
        actionIdentifier: "terminal.takeback"
      ) {
        scene.takeOver()
      }
    case .failed(let error)?:
      // With a Retry, because most opens fail transiently.
      noticeBar(
        error.errorDescription ?? "The pane could not be opened.",
        textIdentifier: "terminal.error",
        action: "Retry",
        actionIdentifier: "terminal.error.retry"
      ) {
        scene.retryOpen()
      }
    // `.closed` is drawn by `closedPaneBanner`, so both kinds of close read the same. The
    // connection cases are `connectionBar`'s.
    case .closed?, .reconnecting?, .needsPassword?, .disconnected?, nil:
      EmptyView()
    }
  }

  /// What the connection has to say, the widest subject on this screen. Inline, including
  /// the password case, for the pane bars' reason.
  @ViewBuilder
  private var connectionBar: some View {
    switch scene.notice {
    case .reconnecting?:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reconnecting to \(host.displayName)…")
          .font(.footnote)
          .accessibilityIdentifier("terminal.reconnecting")
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial)
    case .disconnected?:
      noticeBar(
        "The connection to \(host.displayName) was lost.",
        textIdentifier: "terminal.disconnected",
        action: "Reconnect",
        actionIdentifier: "terminal.reconnect"
      ) {
        scene.reconnectNow()
      }
    case .needsPassword?:
      reconnectPasswordBar
    case .refused?, .takenOver?, .closed?, .failed?, nil:
      EmptyView()
    }
  }

  /// The password prompt for reconnecting a host whose password was never saved: a bar with
  /// a secure field, not an alert. Nothing retries while it is up. No identifier on the
  /// container.
  @ViewBuilder
  private var reconnectPasswordBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("The connection to \(host.displayName) was lost. Its password is needed to get back.")
        .font(.footnote)
        .accessibilityIdentifier("terminal.reconnect.prompt")
      // Only after a refusal, so the first ask accuses nobody.
      if scene.passwordWasRefused {
        Text("That password was refused.")
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("terminal.reconnect.refused")
      }
      SecureField("Password", text: $reconnectPassword)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // Lets the password manager offer a saved password.
        .textContentType(.password)
        // Return submits.
        .submitLabel(.go)
        .onSubmit(submitReconnect)
        .focused($isReconnectFieldFocused)
        .accessibilityIdentifier("terminal.reconnect.password")
      HStack {
        Spacer()
        Button(action: submitReconnect) { BorderedButtonLabel("Reconnect") }
          // An empty password would only be refused.
          .disabled(reconnectPassword.isEmpty)
          .accessibilityIdentifier("terminal.reconnect")
      }
    }
    // The bar exists to be typed into, so it takes the keyboard.
    .onAppear { isReconnectFieldFocused = true }
    .buttonStyle(.bordered)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial)
  }

  /// The one submit path for the button and Return.
  private func submitReconnect() {
    guard !reconnectPassword.isEmpty else { return }
    scene.reconnect(with: reconnectPassword)
    // Cleared, so a refusal does not bring the field back pre-filled.
    reconnectPassword = ""
  }

  private func noticeBar(
    _ message: String,
    textIdentifier: String,
    action: String,
    actionIdentifier: String,
    perform: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(message)
        .font(.footnote)
        .accessibilityIdentifier(textIdentifier)
      HStack {
        Spacer()
        Button(action: perform) { BorderedButtonLabel(action) }
          .accessibilityIdentifier(actionIdentifier)
      }
    }
    .buttonStyle(.bordered)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial)
  }

  /// Explains the missing software keyboard. iOS hides it when it sees a hardware one, and
  /// with iPhone Mirroring no keyboard is anywhere near the phone. Inline, like the other
  /// banners.
  @ViewBuilder
  private var hardwareKeyboardNotice: some View {
    // The forcing flag is OR'd in because `GCKeyboard.coalesced` is nil in a UI-test
    // launch, so the model never shows the notice there and UI tests can only check
    // rendering. `KeyboardNoticeModelTests` covers the state machine.
    if scene.keyboardNotice.showsHardwareKeyboardNotice
      || (AppEnvironment.isForcingHardwareKeyboardNotice && !isHardwareNoticeDismissed)
    {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        // The model's words, which depend on the idiom.
        Text(scene.keyboardNotice.noticeText)
          .font(.footnote)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("terminal.keyboard.hardwareNotice")
        // A close button. It stays closed for the life of the scene.
        Button {
          scene.keyboardNotice.dismissNotice()
          isHardwareNoticeDismissed = true
        } label: {
          Image(systemName: "xmark")
            .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("terminal.keyboard.hardwareNotice.close")
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial)
    }
  }

  @ViewBuilder
  private var statusBanner: some View {
    // Quiet while the scene has something more specific to say, and while a reattach is in
    // flight: the ended stream left the session `.closed`, and "The session ended." would
    // be false. A failed reattach raises `Notice.failed` instead.
    if scene.notice == nil, !scene.isReattaching, let session = scene.currentSession {
      switch session.state {
      case .idle, .running:
        EmptyView()
      case .closed:
        // "The shell ended." for the plain shell, which the user never thought of as a
        // session.
        banner(
          scene.current == .shell ? "The shell ended." : "The session ended.",
          identifier: "terminal.closed"
        )
      case .failed(let error):
        banner(
          error.errorDescription ?? "The session ended unexpectedly.",
          identifier: "terminal.failed"
        )
      }
    }
  }

  private func banner(_ text: String, identifier: String) -> some View {
    Text(text)
      .font(.footnote)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .background(.thinMaterial)
      .accessibilityIdentifier(identifier)
  }
}

extension View {
  /// Caps a column of prose at the route's readable measure.
  ///
  /// A no-op where `TerminalSceneRoute.readableContentWidth` is `nil`, so no frame is
  /// inserted on the phone. The container does the centring.
  ///
  /// `outsetBy` is for a view that caps itself inside its own padding.
  /// `PaneComposerBar.barContent` caps at `ChatColumn.width` and then pads `ChatColumn.inset`
  /// each side, so the bare measure would cap it twice and the card would come out narrower
  /// than the bubbles above it.
  @ViewBuilder
  func readableColumn(_ route: TerminalSceneRoute, outsetBy outset: CGFloat = 0) -> some View {
    if let width = route.readableContentWidth {
      frame(maxWidth: CGFloat(width) + outset)
    } else {
      self
    }
  }
}

/// Reports a surface's frame in window coordinates, and attaches nothing when `report` is
/// `nil`. `onGeometryChange` costs something every layout pass, and these probes only feed
/// `debug.keyboardMetrics`, so a shipping build attaches none.
private struct SurfaceGeometryProbe: ViewModifier {
  var report: ((CGRect) -> Void)?

  func body(content: Content) -> some View {
    if let report {
      content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
    } else {
      content
    }
  }
}

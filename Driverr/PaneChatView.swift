import DriverrCore
import SwiftUI
import UIKit

/// The one column the chat side lays out in.
///
/// The transcript's rows and the composer's card both read these two numbers, so on iPad no
/// row stands beside the card and gets cut square at its edge as it scrolls behind it.
/// Nothing on this surface may cap itself independently.
enum ChatColumn {
  static let width: CGFloat = 680
  static let inset: CGFloat = 16

  /// The gutter for a conversation of `columnWidth`: 0 where the readable column's cap binds,
  /// `inset` where it does not.
  ///
  /// The rule: the turn card's leading edge is the composer card's leading edge.
  /// `TerminalScreen.readableColumn` caps `PaneChatView` at `width`. On a phone nothing binds
  /// and both cards sit `inset` from the window. On a pad the cap binds, the composer's card
  /// sits on the conversation's frame, and so must the turn cards. Check it on the painted
  /// card, not a row's layout edge. One rule, not a device check: a narrow split view gets
  /// `inset` on either device.
  static func gutter(forColumnWidth columnWidth: CGFloat) -> CGFloat {
    columnWidth >= width - 0.5 ? 0 : inset
  }
}

/// What the conversation's scroll view reports about its own geometry.
///
/// Content wider than the container, or a non-zero `contentOffsetX`, means the content has a
/// horizontal axis and something placed it there; both zero means a horizontal drift is
/// elsewhere. Published through `debug.keyboardMetrics`, because app-side `print` never
/// reaches xcodebuild's log, and readable off a phone screenshot.
struct ChatScrollProbe: Equatable {
  var contentOffsetX: Double = 0
  var contentWidth: Double = 0
  var containerWidth: Double = 0
  var contentHeight: Double = 0
  /// The strip of the conversation behind the composer's card: `adjustedContentInset.bottom`,
  /// which `Coordinator.restingOffset` rests against.
  var insetBottom: Double = 0
  /// The scroll view's `bounds.height` and the slot height SwiftUI placed it in.
  /// `Coordinator.applyBottomInset` sets `insetBottom` from their difference, so the three say
  /// whether the arithmetic or an input is wrong.
  var boundsHeight: Double = 0
  var slotHeight: Double = 0
}

/// Where the reader's place is, and who put it there.
///
/// `distanceFromEnd` is where the reader is, in points. `isPositionedByUser` says whether the
/// reader last moved the position. `hasStandingTarget` is always `false`: nothing keeps a
/// standing scroll target any more. Published through `debug.keyboardMetrics`, so a
/// screenshot of a stuck state on a phone says which mechanism it is.
struct ChatPlaceProbe: Equatable {
  var distanceFromEnd: Double = 0
  var isPositionedByUser = false
  var hasStandingTarget = false
}


/// Which of a pane's two surfaces is being looked at.
///
/// Only a pane with an agent has two; see `TerminalScreen.showsSurfaceSegment`. A shell opens
/// straight into the terminal.
enum PaneSurface: Hashable {
  case chat
  case terminal

  /// The other one, which ⌘⇧T switches to. A `switch`, so a third surface fails to compile
  /// here instead of making inline ternaries wrong.
  var toggled: PaneSurface {
    switch self {
    case .chat: .terminal
    case .terminal: .chat
    }
  }
}

/// What the transcript watcher is keyed on: which conversation, and whether anyone is looking.
/// A named value, so a new condition cannot be appended without being seen.
private struct WatchKey: Equatable {
  let pane: String
  /// The sub-agent on screen, so opening or closing one restarts the loop on the conversation
  /// now shown.
  let subagent: SubagentLink?
  let isActive: Bool
}

/// Which conversation the chat is showing: the pane's own, or a sub-agent opened from a spawn
/// line. Keyed on the link, because a sub-agent's path is known only once the load resolves it.
private struct ShownKey: Equatable {
  let pane: String
  let subagent: SubagentLink?
}

/// When the chat reads the pane's screen for a question. See
/// `PaneChatView.watchesScreenForQuestion`.
private struct ScreenQuestionKey: Equatable {
  let pane: String
  let isWatching: Bool
}

/// The agent's conversation, read from its own session file and drawn as chat.
///
/// Speaker, ordering and boundaries are typed fields in the session file, so nothing here
/// infers a speaker from appearance, as reading the pane's screen would. Every sentence comes
/// from `DriverrCore` (`TranscriptHeader`, `TranscriptNotice`, `ToolRun`), where `swift test`
/// covers it; this view is wiring and layout.
struct PaneChatView: View {
  let model: PaneTranscriptModel
  /// The agent's own name, so the header never calls a Codex session a Claude one.
  let agentName: String
  /// The pane's captured screen, the exit from every chat failure. Held here so Show the
  /// Screen always works with nothing installed.
  let screen: PaneScreenModel

  /// Taps a reply chip under a pending turn. `nil` for a shell pane; see `sendReply`.
  var onSendReply: ((ReplyChip) -> Void)?
  /// The screen moved on to the picker's next question: evidence the last answer landed, so
  /// `TerminalScreen` retires the composer's `Sent` notice.
  var onScreenQuestionAdvanced: (() -> Void)?
  var isSending = false

  /// What the conversation says about itself at its foot, or `nil`. Built by `TerminalScreen`
  /// from the live pane and the composer's send state.
  var activity: ChatActivity?
  /// Retries the send `activity` reports a failure for. `nil` for a shell pane.
  var onRetry: (() -> Void)?
  /// Opens one of a turn's images full size.
  ///
  /// The viewer is drawn by `TerminalScreen`, not here: the composer is a `safeAreaBar` over
  /// this view, so anything drawn here would be under the composer.
  var onOpenImage: ((TranscriptImage) -> Void)?

  /// Whether the composer below has the keyboard.
  ///
  /// The keyboard takes about 40% of the viewport, and holding the reader's place would push
  /// the newest turn, the one being answered, off the bottom. So focusing the field returns to
  /// the newest turn, as chat apps do. A reader deep in history loses their place, because the
  /// composer exists to answer the newest thing.
  var isComposerFocused = false

  /// Whether the composer is collapsed: compact vertical size class with the keyboard up, as in
  /// `TerminalScreen.isComposerCollapsed`. There is no height to spare then, so it hides the
  /// agent-stop row and the Show the Screen row, and it picks the keyboard dismissal mode.
  var isComposerCollapsed = false

  /// Reports the conversation's scroll geometry, `nil` unless `-uiTestingKeyboardMetrics` is
  /// set. Only `TerminalScreen` reads it, for `debug.keyboardMetrics`. See `ChatScrollProbe`.
  var onScrollGeometry: ((ChatScrollProbe) -> Void)?

  /// Reports where the reader's place is and who put it there, on the same terms as
  /// `onScrollGeometry`. See `ChatPlaceProbe`.
  var onPlaceChange: ((ChatPlaceProbe) -> Void)?

  /// VoiceOver focus, moved to the newest turn when the transcript first renders, where a
  /// sighted reader's eye lands anyway.
  @AccessibilityFocusState private var focusedTurnID: TranscriptTurn.ID?

  /// What the scroll owner reports about the reader.
  ///
  /// `ChatCollectionView.Coordinator` owns the `ChatReaderPlace`; this view never sees it. It
  /// gets back two booleans: whether the jump-to-latest control belongs on screen, and whether
  /// the reader is near enough the front to fetch older turns.
  @State private var readerState = ChatReaderState()

  /// This view's only request of the scroll position. See `ChatCollectionView.jumpToken`.
  @State private var jumpToken = 0

  /// Bumped when the reader opens a tool run or expands a bounded turn. The scroll owner sees
  /// only a cell resizing, which looks like a turn growing at the end. See
  /// `ChatReaderPlace.Event.rowExpansionChanged`.
  @State private var expansionToken = 0

  /// The height of the slot the conversation is placed in, handed across the hosting boundary.
  ///
  /// SwiftUI never tells a hosted UIKit view the composer bar's height; it shrinks the
  /// representable's frame instead. The coordinator derives `contentInset.bottom` from this
  /// and its own `bounds.height`; see `ChatCollectionView.Coordinator.applyBottomInset`.
  ///
  /// Not a feedback loop: `contentInset` changes what the scroll view does with its content,
  /// not what SwiftUI proposes to this view, so it cannot move the measurement.
  @State private var chatSlotHeight: CGFloat = 0



  /// Whether the last automatic fetch failed, which disarms it.
  ///
  /// Cleared only by a tap on the control, never by scrolling. Otherwise a reader at the top of
  /// an unreadable conversation would retry on every small movement.
  @State private var autoLoadFailed = false


  /// Whether the captured screen is what this surface is showing.
  ///
  /// Either the reader took Show the Screen from a chat failure, or the agent is one this build
  /// has no reader for. For those agents there was never a conversation, so a notice would
  /// present a normal state as an error (`TranscriptAbsence.isUnreadableAgentKind`). Every
  /// other absence keeps its notice, because something expected is missing.
  private var showsCapturedScreen: Bool {
    // The captured screen is the pane's, so a sub-agent's chat never offers it.
    if isShowingSubagent { return false }
    if isShowingScreen { return true }
    if case .unavailable(let resolution) = shown.state {
      return resolution.isUnreadableAgentKind
    }
    return false
  }

  /// Whether the reader has taken the exit to the pane's captured screen.
  ///
  /// The screen renders on the Chat side, not by switching to Terminal, which would be the
  /// attach-a-terminal loop this surface replaces. Reset when this view is rebuilt, so a
  /// switch to Terminal and back offers the notice and its retry again. `PaneScreenModel` is
  /// cached on the connection, so the screen itself survives.
  @State private var isShowingScreen = false

  /// Whether the file picker has replaced the refusal.
  ///
  /// Inline, not a sheet, like `PanePromptBar`. The refusal draws nothing behind it, so the
  /// picker replaces it rather than sliding over it. Reset on a pane switch, because SwiftUI
  /// keeps `@State` when a different model arrives in the same place, and the picker would
  /// offer another pane's files.
  @State private var isChoosingFile = false
  /// Whether the sub-agent list under the provenance row is open. Closed on a pane switch
  /// and when a row opens its sub-agent.
  @State private var isSubagentListOpen = false

  /// This view's outer width, passed to each `TranscriptTurnView` as `estimatedContentWidth`.
  /// A row corrects it to its exact width a frame later; this keeps a bounded turn from
  /// measuring at 0 on its first frame and visibly growing.
  @State private var contentWidthEstimate: CGFloat = 0

  /// Which answers have been chosen under the pending call.
  ///
  /// Held here because both the chips and the unanswered count at the foot need it. Only the
  /// last call of the last run can be pending, so one selection covers the one question.
  @State private var replySelection = ReplyChipSelection()

  /// Where the chips sat in the band while the question came from the screen, and where they
  /// sit now. The difference is the headroom that keeps the chips still when the transcript
  /// takes the question over. See `ChatReplyAnchor.headroom(screenBandTop:bandTop:)`.
  @State private var screenBandTop: CGFloat?
  @State private var bandTop: CGFloat = 0

  /// Whether this app is on screen. The transcript watcher stops when it is not, and returning
  /// is an appearance, which `loadIfNeeded()` treats as a refresh trigger.
  @Environment(\.scenePhase) private var scenePhase
  /// The theme's accent. Never `Color.accentColor`, which ignores `.tint`.
  @Environment(\.themeAccent) private var themeAccent
  /// Read only to pass across `ChatCollectionView`'s hosting boundary: a
  /// `UIHostingConfiguration`'s content is a separate hierarchy that does not inherit it.
  @Environment(\.themeAccentForeground) private var themeAccentForeground

  // MARK: - Which conversation is on screen

  /// The conversation this surface draws: the pane's own, or an opened sub-agent. Everything
  /// about the conversation reads this; everything about the pane still reads `model`.
  private var shown: PaneTranscriptModel { model.shown }

  private var isShowingSubagent: Bool { model.isShowingSubagent }

  /// What herdr says the pane's agent is doing, and `nil` while a sub-agent is shown: the
  /// pane's status is not the sub-agent's, so it must not mark its turns blocked or waiting.
  private var agentStatus: AgentStatus? {
    isShowingSubagent ? nil : model.pane.agent?.status
  }

  /// `onSendReply`, or `nil` while a sub-agent is shown: a chip there would answer the pane.
  /// `nil` also turns off the reply band and the screen-question read.
  private var sendReply: ((ReplyChip) -> Void)? {
    isShowingSubagent ? nil : onSendReply
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsCapturedScreen {
        // Replaces the chat, because this pane has no conversation to show.
        //
        // `.safeAreaPadding(.bottom)` stops it above the composer: a character grid behind a
        // blurred panel is a smear. `PaneScreenView` is a `ScrollView`, so without the padding
        // its fill, border and rows draw behind the card.
        PaneScreenView(model: screen, agentName: agentName)
          .safeAreaPadding(.bottom)
      } else {
        // The way back sits over every state a sub-agent's chat can be in, so a link still
        // resolving or one that found nothing never strands the reader.
        if let title = model.shown.subagent?.title {
          SubagentBackBar(title: title, horizontalInset: chatGutter) {
            model.closeSubagent()
          }
        }
        switch shown.state {
        case .idle, .loading:
          loading
        case .ready(let source, let transcript):
          chat(source: source, transcript: transcript)
        case .unavailable(let resolution):
          notice(for: resolution)
        case .failed(let error):
          failure(error)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Feeds `contentWidthEstimate`.
    .onGeometryChange(for: CGFloat.self, of: \.size.width) { contentWidthEstimate = $0 }
    // Not `systemBackground`, which is pure black in dark, where a translucent card reads as a
    // grey box. `TerminalScreen` paints the same colour behind the whole chat side.
    .background(Color(.secondarySystemBackground))
    // Load when the chat appears, so a pane whose chat is never opened is never read.
    // `loadIfNeeded()` is not `async`: the model owns the load task, so cancelling this task
    // cannot strand it.
    //
    // Keyed on the pane, because a pane switch hands this view a different model in the same
    // place and a bare `.task` would not re-run. Also on the shown sub-agent, so opening or
    // closing one loads the right page.
    .task(id: ShownKey(pane: model.pane.id, subagent: model.shown.subagent?.link)) {
      shown.loadIfNeeded()
      // The `/` list's catalogue, requested here because the bar is rebuilt on every keystroke
      // and must not start a round trip. A no-op unless the answer is old.
      model.loadSkillsIfNeeded()
    }
    // Keep re-reading the conversation while it is on screen, because an agent writing while
    // it stays `working` changes no herdr status. A tick costs a size check, not a page; see
    // `PaneTranscriptModel.watch(every:)`.
    //
    // Keyed on the pane, the sub-agent and the scene phase. The `guard` makes the scene part
    // work, because a `.task` runs for every id value, including "not on screen". Switching to
    // the terminal removes this view, and the task with it.
    .task(
      id: WatchKey(
        pane: model.pane.id, subagent: model.shown.subagent?.link,
        isActive: scenePhase == .active)
    ) {
      guard scenePhase == .active else { return }
      await model.watch()
    }
    // Read the screen for a question while the pane is blocked and the transcript has none.
    // Claude Code writes a pending `AskUserQuestion` to the session file only once answered.
    // The same cadence also shows a multi-question prompt's next tab after a chip answers.
    .task(
      id: ScreenQuestionKey(
        pane: model.pane.id, isWatching: scenePhase == .active && watchesScreenForQuestion)
    ) {
      guard scenePhase == .active, watchesScreenForQuestion else { return }
      screen.startWatchingForQuestion()
      while !Task.isCancelled {
        screen.refresh()
        try? await Task.sleep(for: PaneTranscriptModel.watchInterval)
      }
    }
    // Rebuilt when the question changes, not when the view redraws. The chat polls and this
    // view is rebuilt constantly, so a selection seeded in `init` would be cleared under the
    // reader's finger. A new question, or a call no longer pending, starts with nothing chosen.
    .onChange(of: pendingGroups, initial: true) { previous, groups in
      if ReplyChipGroup.screenQuestionAdvanced(from: previous, to: groups) {
        onScreenQuestionAdvanced?()
      }
      replySelection = ReplyChipSelection(groups: groups)
      if groups.isEmpty { screenBandTop = nil }
    }
    // Opening or closing a sub-agent is a new conversation in the same place. Both open at
    // the newest turn; the place in the pane's chat is not restored.
    .onChange(of: model.subagents.depth) {
      // The captured screen is the pane's, so it is never the way into or out of a sub-agent.
      isShowingScreen = false
      jumpToken += 1
      autoLoadFailed = false
      readerState = ChatReaderState()
    }
    // The list is hidden while the composer is collapsed, and comes back closed, so the
    // keyboard going down does not open it over the conversation.
    .onChange(of: isComposerCollapsed) { _, collapsed in
      if collapsed { isSubagentListOpen = false }
    }
    .onChange(of: model.pane.id) {
      isShowingScreen = false
      isChoosingFile = false
      isSubagentListOpen = false
      // SwiftUI keeps the coordinator across a pane switch, so without this the new pane's chat
      // would hold an anchor from the previous pane's transcript instead of opening at the
      // newest turn.
      jumpToken += 1
      // A failed read of this pane's file says nothing about the next pane's.
      autoLoadFailed = false
      // The reader's state belongs to the old conversation; the coordinator reports the new
      // one within a layout pass.
      readerState = ChatReaderState()
    }
  }

  // MARK: - A conversation

  /// The conversation, with one reader and one writer of its scroll position.
  ///
  /// `ChatCollectionView.Coordinator` is the only reader and writer of `contentOffset`, holding
  /// a `DriverrCore.ChatReaderPlace`. This view asks through `jumpToken` and is told through
  /// `ChatReaderState`; it scrolls nothing itself.
  ///
  /// The place names an item and an offset within it, so one rule covers three cases: opening
  /// a run does not move the reader, older turns arriving do not move the turns being read,
  /// and a new turn does not pull a reader up in the history to the end.
  ///
  /// The paging control, working row and tail marker are one-item sections. The
  /// jump-to-latest control is a SwiftUI overlay, because it must stay reachable while the
  /// content moves.
  @ViewBuilder
  private func chat(source: TranscriptSource, transcript: Transcript) -> some View {
    // A sub-agent's chat draws `SubagentBackBar` in this row's place.
    if !isShowingSubagent {
      provenanceHeader(source: source, contextUsage: transcript.contextUsage)
    }
    // Every sub-agent the session spawned, from its meta files. Not over a sub-agent's chat,
    // where the back bar holds this place, and not while the composer is collapsed, for the
    // stop row's reason below.
    if !isShowingSubagent, !isComposerCollapsed, !model.subagentList.isEmpty {
      SubagentListBar(
        list: model.subagentList, turns: transcript.turns, isExpanded: $isSubagentListOpen,
        horizontalInset: chatGutter
      ) { row in
        isSubagentListOpen = false
        model.openSubagent(link: row.summary.link, title: row.summary.title)
      }
    }
    // The agent stopped on a failed API request. Hidden while the composer is collapsed, like
    // the row below, and over a sub-agent's chat, whose stop is not the pane's.
    if let stop = transcript.agentStop, !isComposerCollapsed, !isShowingSubagent {
      AgentStopRow(stop: stop, horizontalInset: chatGutter)
    }
    // Show the Screen is reachable from a readable chat on a blocked pane, not only from a
    // failure, so the reader never has to switch to Terminal to see a prompt.
    //
    // Not while the composer is collapsed, like the band in `TerminalScreen.surfaceSegment`.
    // A landscape phone with the keyboard up leaves this surface about 100 pt, and without
    // this row the rest fits. The row returns with the keyboard's dismissal or rotation.
    if agentStatus == .blocked && !isComposerCollapsed {
      HStack {
        Spacer(minLength: 0)
        showScreenButton(isProminent: false)
      }
      // `chatGutter`, because this row is a sibling of the collection view and section insets
      // do not reach it.
      .padding(.horizontal, chatGutter)
      .padding(.top, 4)
    }
    // `Color.clear` takes the safe-area slot and the two overlays cannot change it, as in
    // `TerminalScreen.paneSurfaces`. The conversation draws into the bottom safe area so it
    // passes behind the composer's glass. The jump-to-latest control is aligned to the slot's
    // bottom, the composer's top edge, so it never sits behind the card.
    Color.clear
      // The slot's height, the SwiftUI half of the inset arithmetic. The gutter is not passed
      // down; the layout reads its own container. See `ChatColumn.gutter(forColumnWidth:)`.
      .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chatSlotHeight = $0 }
      .overlay {
        ChatCollectionView(
          turns: transcript.turns,
          showsPaging: shown.paging != nil,
          showsActivity: footActivity != nil,
          replyAfter: replyTurnID,
          replyHeadroom: CGFloat(
            ChatReplyAnchor.headroom(
              screenBandTop: screenBandTop.map(Double.init), bandTop: Double(bandTop))),
          visibleHeight: chatSlotHeight,
          accent: themeAccent,
          accentForeground: themeAccentForeground,
          // What decides whether an existing cell is reconfigured. See `ChatRowInputs`.
          rowInputs: ChatRowInputs(
            agentStatus: agentStatus,
            openRuns: shown.openRuns,
            expanded: shown.expanded,
            selection: replySelection,
            isSending: isSending,
            contentWidth: contentWidthEstimate,
            render: shown.render,
            paging: shown.paging,
            isPagingBack: shown.isPagingBack,
            pagingError: shown.lastPagingError?.errorDescription,
            activity: footActivity
          ),
          jumpToken: jumpToken,
          expansionToken: expansionToken,
          dismissesKeyboardImmediately: isComposerCollapsed,
          onReaderState: { readerState = $0 },
          onScrollGeometry: onScrollGeometry,
          onPlaceChange: onPlaceChange
        ) { item in
          chatRow(item, in: transcript)
        }
        // Gives the representable its whole frame back. Otherwise SwiftUI shrinks it to the
        // bar's top edge, rows stop above the card and the material has nothing to blur. The
        // bar's height arrives through `chatSlotHeight`.
        .ignoresSafeArea(.container, edges: .bottom)
      }
      // Above the collection view, so rows fade out under the rows above the slot.
      .overlay(alignment: .top) { ChatTopFade() }
      // A new turn while the reader is up in the history shows a control instead of moving
      // them. `ChatEndProximity.showsJumpToLatest` is the rule; the tail marker can only hide
      // the control.
      .overlay(alignment: .bottom) {
        if readerState.showsJumpToLatest {
          // Asks rather than scrolls: the coordinator owns `contentOffset`.
          jumpToLatest { jumpToken += 1 }
        }
      }
      // Once per appearance of a ready transcript. This branch's identity is stable across
      // scrolls and expansions, so a later refresh does not steal focus back.
      .onAppear { focusedTurnID = transcript.turns.last?.id }
      // Focusing the composer returns to the newest turn; see `isComposerFocused`. No deferral
      // is needed: the coordinator sets a place, and every layout pass the inset change causes
      // re-applies it.
      .onChange(of: isComposerFocused) { _, focused in
        guard focused else { return }
        jumpToken += 1
      }
      // Coming within a screen of the front fetches older turns. The reader scrolling back has
      // already asked, and the bill and priced control stay on screen, so no page is spent
      // quietly.
      //
      // A rising edge. The coordinator's first report is the baseline, so a conversation
      // shorter than its viewport never fetches by itself. The reader is `reading`, so the
      // coordinator keeps their item in place when the page lands.
      .onChange(of: readerState.isNearStart) { wasNearStart, isNearStart in
        // Every reason not to fire is `ChatBackfill`, in `DriverrCore`: the rising edge, the
        // start of the file, a fetch in flight, and the disarm after a failure.
        guard
          ChatBackfill.loadsMore(
            isNearStart: isNearStart,
            wasNearStart: wasNearStart,
            isPagingBack: shown.isPagingBack,
            hasPageBehind: shown.paging?.loadMore != nil,
            lastAutoLoadFailed: autoLoadFailed
          )
        else { return }
        shown.loadMore()
      }
      // A failed fetch disarms the automatic one until the reader taps. Watched here because
      // the failure arrives a round trip later, through `lastPagingError`. Keyed on the nil to
      // non-nil edge, so a second failure disarms again after a tap cleared it. Never re-armed
      // by scrolling.
      .onChange(of: shown.lastPagingError != nil) { _, hasError in
        if hasError { autoLoadFailed = true }
      }
      // A reader scrolled back is told the agent started, because the collection view never
      // creates the working row's cell off screen, so it is missing from their accessibility
      // tree. `ChatActivityAnnouncement` in `DriverrCore` decides whether there is anything to
      // say; this only posts it.
      .onChange(of: footActivity) { previous, current in
        guard
          let announcement = ChatActivityAnnouncement.onArrival(
            previous: previous,
            current: current,
            // True exactly for the reader whose realised cells do not reach the end.
            isScrolledBack: readerState.showsJumpToLatest
          )
        else { return }
        UIAccessibility.post(notification: .announcement, argument: announcement)
      }
    // The tail of a page that stopped mid-record, under the turns that did parse.
    if let notice = TranscriptNotice(
      outcome: transcript.outcome,
      turnCount: transcript.turns.count,
      bytesFetched: transcript.window.bytesFetched,
      agentStatus: agentStatus
    ) {
      noticeBar(notice)
    }
  }

  /// One row of the conversation, whichever kind it is.
  ///
  /// The column cap is the row's and the gutter is the section's, because a cell inset by the
  /// layout cannot be overflowed by its content. Every row gets `.padding(.vertical, 9)`, so
  /// rows sit 18 apart, and `ChatCollectionView.endMargin` and `ChatTopFade.height` add the
  /// ends' extra.
  @ViewBuilder
  private func chatRow(_ item: ChatItem, in transcript: Transcript) -> some View {
    switch item {
    case .paging:
      // Above the oldest turn, where older ones arrive. The place is an item id, and ids are
      // the session file's record uuids, so a wider page keeps the reader's item.
      if let paging = shown.paging {
        chatColumn { pagingControl(paging, outcome: transcript.outcome) }
      }
    case .turn(let id):
      // The lookup cannot miss today; drawing nothing is still better than a crash.
      if let index = transcript.turns.firstIndex(where: { $0.id == id }) {
        chatColumn { turnRow(at: index, in: transcript) }
      }
    case .reply:
      replyRow
    case .activity:
      // What the conversation is doing, as the last thing in it, above the tail marker so the
      // marker still names the end. It softens under the composer like every other row.
      if let activity = footActivity {
        chatColumn { activityRow(activity) }
      }
    case .tail:
      // The end of the conversation. See `ChatItem.tail`. Nine points either side, with the last
      // turn's own 9, give the usual 18 pt gap.
      Color.clear
        .frame(height: 1)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
  }

  /// The gutter every row kind shares. See `ChatColumn.gutter(forColumnWidth:)`.
  ///
  /// Turn cards get it from their section. Rows that are not cells, such as the provenance
  /// header and the Show the Screen row, must ask for it here, or they draw inside the edge
  /// the cards and the composer share. `contentWidthEstimate` is 0 until measured, so the
  /// phone's answer applies until then.
  private var chatGutter: CGFloat {
    ChatColumn.gutter(forColumnWidth: contentWidthEstimate)
  }

  /// The one column every row is laid out in.
  private func chatColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      // The cap is here and the inset is the section's. A row capped and then padded would be
      // 32 pt wider than its cell and overflow it. See `ChatCollectionView.makeCollection`.
      .frame(maxWidth: ChatColumn.width, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 9)
  }

  /// The chips that answer the pending call, as their own item after the turn that carries
  /// it. See `ChatItem.reply`.
  ///
  /// Not inside the tool run's card, which reads as secondary. `PendingToolCallNotice` decides
  /// whether to draw them. A shell pane has no composer, so no chips.
  ///
  /// 1 pt above rather than 9, so the band sits 10 pt under its run.
  ///
  /// A question read off the screen is drawn as the agent's turn, with its name and waiting
  /// line, because the transcript has no turn for it yet and the band would read as part of
  /// the reader's bubble. When the transcript turn arrives, its tool card replaces the two
  /// lines and `replyHeadroom` keeps the chips in place.
  @ViewBuilder
  private var replyRow: some View {
    if !pendingGroups.isEmpty {
      let isFromScreen = pendingGroups.contains { $0.pickerTab != nil }
      VStack(alignment: .leading, spacing: 0) {
        if isFromScreen, let notice = screenQuestionNotice {
          VStack(alignment: .leading, spacing: 4) {
            Text(agentName)
              .font(.caption.weight(.semibold))
              .foregroundStyle(themeAccent)
              .accessibilityAddTraits(.isHeader)
            Text(notice)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.orange)
              .accessibilityIdentifier("pane.chat.turn.pending")
          }
          .padding(.bottom, 10)
        }
        ReplyChipRow(
          groups: pendingGroups,
          selection: replySelection,
          isSending: isSending,
          onTap: { group, chip in choose(chip, in: group) },
          onSend: { confirmReply() }
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.replySpace)).minY }) {
          top in
          bandTop = top
          if isFromScreen { screenBandTop = top }
        }
      }
      .frame(maxWidth: ChatColumn.width, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      // An agent turn's 9 above, so the name sits under the reader's bubble as a real agent
      // turn's does. The transcript's band hangs 1 under its tool card.
      .padding(.top, isFromScreen ? 9 : 1)
      .padding(.bottom, 9)
      .coordinateSpace(.named(Self.replySpace))
    }
  }

  /// The band item's own coordinate space, which the chips' offset is read in.
  private nonisolated static let replySpace = "pane.chat.reply"

  /// The waiting line for a question read off the screen: the sentence the transcript's tool
  /// card would draw for the same call.
  private var screenQuestionNotice: String? {
    guard
      let call = model.transcript?.questionCall(
        screen: screenForQuestion, agentStatus: agentStatus)
    else { return nil }
    return call.pendingNotice(agentStatus: agentStatus).label
  }

  /// The turn the chips follow, or `nil` while nothing offers any. Only the last run can carry
  /// a pending call; see `Transcript.pendingToolCall`.
  private var replyTurnID: TranscriptTurn.ID? {
    guard !pendingGroups.isEmpty else { return nil }
    // A question read off the screen has no run yet, so its chips follow the newest turn.
    if pendingGroups.contains(where: { $0.pickerTab != nil }) {
      return model.transcript?.turns.last?.id
    }
    return model.transcript?.turns.last { $0.toolRun != nil }?.id
  }

  /// One turn, with everything `TranscriptTurnView` needs to draw it.
  private func turnRow(at index: Int, in transcript: Transcript) -> some View {
    let turn = transcript.turns[index]
    let isNewest = index == transcript.turns.count - 1
    return TranscriptTurnView(
      turn: turn,
      agentName: agentName,
      isNewest: isNewest,
      previousTurn: index > 0 ? transcript.turns[index - 1] : nil,
      isFinalBlockedAnswer: isNewest && turn.isAssistant
        && agentStatus == .blocked,
      agentStatus: agentStatus,
      isOpen: shown.openRuns.isOpen(turn),
      isExpanded: shown.expanded.contains(turn.id),
      onToggleOpen: {
        expansionToken += 1
        withAnimation(.snappy) { shown.openRuns.toggle(turn) }
      },
      onToggleExpand: { toggleExpand(turn.id) },
      onOpenImage: onOpenImage,
      // Only the pane's own chat opens one: a sub-agent's spawn lines carry no link.
      onOpenSubagent: isShowingSubagent
        ? nil : { link, title in model.openSubagent(link: link, title: title) },
      estimatedContentWidth: contentWidthEstimate,
      render: shown.render[turn.id]
    )
    // Whether `@AccessibilityFocusState` reaches across a `UIHostingConfiguration` cannot be
    // tested in-process (see `HostedProbe`), so it is kept rather than replaced by an equally
    // unverifiable UIKit notification.
    .accessibilityFocused($focusedTurnID, equals: turn.id)
  }

  /// The floating jump-to-latest control: a circle over the conversation, above the composer.
  private func jumpToLatest(_ scroll: @escaping () -> Void) -> some View {
    Button(action: scroll) {
      Image(systemName: "arrow.down")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .background(.thinMaterial, in: Circle())
        .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 0.75) }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(.bottom, 8)
    .accessibilityLabel(TranscriptChatCopy.jumpToLatest)
    .accessibilityIdentifier("pane.chat.jumpToLatest")
  }

  /// The chips the pending call offers, one group per question. Seeds the selection, feeds
  /// the count below, and is drawn by `replyRow`.
  private var pendingGroups: [ReplyChipGroup] {
    guard sendReply != nil,
      let call = model.transcript?.questionCall(
        screen: screenForQuestion, agentStatus: agentStatus)
    else { return [] }
    return call.pendingNotice(agentStatus: agentStatus).groups
  }

  /// Whether to read the screen for a question: a blocked pane, a composer to answer through,
  /// and a transcript whose pending call has no question of its own. A transcript question wins.
  private var watchesScreenForQuestion: Bool {
    sendReply != nil && agentStatus == .blocked
      && model.transcript?.pendingToolCall?.asksItsOwnQuestions != true
  }

  /// The pane's screen, if this view read it while watching for a question.
  private var screenForQuestion: PaneScreen? {
    guard watchesScreenForQuestion else { return nil }
    return screen.screenForQuestion
  }

  /// The foot of the transcript: how much of a multi-question call is unanswered, or whatever
  /// the conversation would otherwise say.
  ///
  /// A send verdict outranks the count. The selection is marked sent once a reply goes, so a
  /// rule counting incomplete answers would put "0 of 2 answered" over the `Sent` notice.
  private var footActivity: ChatActivity? {
    // A sub-agent's chat has no composer, and the activity is the pane's.
    guard !isShowingSubagent else { return nil }
    // Nothing to count once the reply has gone.
    guard !replySelection.hasSent else { return activity }
    // `ChatActivity.foot` in `DriverrCore` sets the order: a send verdict, then the count, then
    // the pane's status.
    return ChatActivity.foot(
      reporting: activity,
      answering: ChatActivity.answering(
        chosen: replySelection.answeredCount, of: pendingGroups.count)
    )
  }

  // MARK: - What the conversation is doing

  /// The last row in the transcript. `ChatActivity` in `DriverrCore` decides what it says,
  /// including that most states say nothing. No padding of its own, so it reads as the next
  /// thing said.
  @ViewBuilder
  private func activityRow(_ activity: ChatActivity) -> some View {
    HStack(spacing: 8) {
      if activity.showsSpinner {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(activity.message)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint(of: activity.tone))
        // herdr's own words, under a headline true whatever they say.
        if let detail = activity.detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      // One element for the whole verdict, so a sentence and its cause are one swipe.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(activity.accessibilityLabel)
      .accessibilityIdentifier("pane.chat.activity")
      Spacer(minLength: 0)
      if activity.offersRetry, let onRetry {
        Button(action: onRetry) { BorderedButtonLabel(PaneComposerCopy.retry) }
          .font(.caption)
          .buttonStyle(.bordered)
          .disabled(isSending)
          .accessibilityIdentifier("pane.chat.activity.retry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func tint(of tone: ChatActivity.Tone) -> Color {
    switch tone {
    case .progress, .prompt: .secondary
    case .success: .green
    case .failure: .red
    }
  }

  /// Records a tap on a chip, and sends only once every question has an answer.
  ///
  /// A single-question call sends on the first tap. Several questions send one message when
  /// the last is answered, composed by `ReplyChipSelection.reply`. A call with a multi-select
  /// question sends from `confirmReply` instead, because `reply` stays nil until confirmed.
  private func choose(_ chip: ReplyChip, in group: ReplyChipGroup) {
    // A no-op once the reply has gone. `ReplyChipSelection` enforces this too; the guard says
    // so here.
    guard !replySelection.hasSent else { return }
    replySelection.toggle(chip, in: group)
    guard let reply = replySelection.reply else { return }
    sendReply?(reply)
    // Marked, not cleared. Left as is, a tap after the send settles would re-send the whole
    // message. Cleared, the chips would look untouched under the `Sent` notice. Marked, every
    // chip goes inert and the chosen ones stay solid. A new question reseeds it.
    replySelection.markSent()
  }

  /// Sends a call that waited for a Send.
  ///
  /// Every call with a multi-select question comes here, not through `choose`, so no group
  /// loses a second answer to tap order. `ReplyChipSelection.confirm()` releases the reply and
  /// does nothing on a half-answered call; the button is disabled then too.
  private func confirmReply() {
    guard !replySelection.hasSent else { return }
    replySelection.confirm()
    guard let reply = replySelection.reply else { return }
    sendReply?(reply)
    // Marked, not cleared, as in `choose`.
    replySelection.markSent()
  }

  private func toggleExpand(_ turnID: TranscriptTurn.ID) {
    // The growth must not move the reader. See `expansionToken`.
    expansionToken += 1
    if shown.expanded.contains(turnID) {
      shown.expanded.remove(turnID)
    } else {
      shown.expanded.insert(turnID)
    }
  }

  /// The bill and the load control together, above the oldest turn, where older turns arrive.
  /// What you have read and what the next page costs are one sentence.
  ///
  /// The bill's `held` line is dropped, not the whole control, when
  /// `TranscriptPaging.isBillRedundant(outcome:)` says the notice below the turns already says
  /// it. The start-of-file sentence must survive.
  @ViewBuilder
  private func pagingControl(_ paging: TranscriptPaging, outcome: TranscriptOutcome) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if !paging.isBillRedundant(outcome: outcome) {
        Text(paging.held)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.paging.held")
      }
      if let unfetched = paging.unfetched {
        Text(unfetched)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.paging.unfetched")
      }
      // Under the bill, because "Last 2 turns" is also what a two-turn session says.
      if let stoppedShort = paging.stoppedShort {
        Text(stoppedShort)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.paging.stoppedShort")
      }
      if let title = paging.loadMore {
        Button {
          // The reader is `reading` during the tap, so the coordinator keeps their item in place
          // when the page lands.
          //
          // The only thing that re-arms the automatic fetch after a failure.
          autoLoadFailed = false
          shown.loadMore()
        } label: {
          BorderedButtonLabel {
            if shown.isPagingBack {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(TranscriptChatCopy.loadingMore)
              }
            } else {
              Text(title)
            }
          }
        }
        .buttonStyle(.bordered)
        // The model guards this too; a tap in the frame before the redraw would still land.
        .disabled(shown.isPagingBack)
        .accessibilityIdentifier("pane.chat.paging.more")
        // Otherwise VoiceOver reads the visible string, tildes and `KB` included.
        .accessibilityLabel(
          shown.isPagingBack
            ? TranscriptChatCopy.loadingMore
            : paging.spokenLoadMore ?? title
        )
        // Say the failure: the model rolls the control back, and a silent snap-back looks like
        // the tap did nothing.
        if let error = shown.lastPagingError {
          Text(error.errorDescription ?? TranscriptChatCopy.pagingFailed)
            .font(.caption2)
            .foregroundStyle(.red)
            .accessibilityIdentifier("pane.chat.paging.error")
        }
      } else if let startOfFile = paging.startOfFile {
        // Replaces the control, because offering a page that does not exist is a false promise.
        Text(startOfFile)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.paging.startOfFile")
      }
    }
    // No horizontal padding: this is a cell, and its section already carries the gutter. See
    // `chatGutter`.
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  // MARK: - Where the file came from

  /// How often the header's `written … ago` advances.
  ///
  /// Thirty seconds, not one. The caption only has to show whether the session is live, and a
  /// never-ending one-hertz redraw is close to the endless animation that stalls XCUITest.
  private static let ageTick: TimeInterval = 30

  /// The caption row above the transcript; see `ProvenanceRow`.
  ///
  /// The age ticks on its own `TimelineView`, because an unchanged re-read writes no state and
  /// would otherwise freeze it. Scoped to this row, because a `TimelineView` around the whole
  /// chat would rebuild it every tick.
  private func provenanceHeader(source: TranscriptSource, contextUsage: ContextUsage?) -> some View {
    TimelineView(.periodic(from: .now, by: Self.ageTick)) { context in
      ProvenanceRow(
        header: TranscriptHeader(
          agentName: agentName, source: source, contextUsage: contextUsage, asOf: context.date
        ),
        horizontalInset: chatGutter
      )
    }
  }

  // MARK: - Everything that is not a conversation

  private var loading: some View {
    // Always resolves: the model owns the fetch, so nothing can cancel it under the spinner.
    ProgressView(TranscriptChatCopy.reading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("pane.chat.progress")
  }

  @ViewBuilder
  private func notice(for resolution: TranscriptResolution) -> some View {
    switch resolution {
    case .absent(let absence):
      centred(TranscriptNotice(absence: absence, agentStatus: agentStatus))
    case .ambiguous(let directory, let candidates):
      // The one place nothing is drawn behind what is on screen. Behind it would be a guessed,
      // possibly wrong, conversation.
      if isChoosingFile {
        picker(
          TranscriptPicker(directory: directory, candidates: candidates, briefs: model.briefs),
          directory: directory
        )
      } else if let notice = TranscriptNotice(ambiguous: directory, candidates: candidates) {
        centred(notice)
      }
    case .found:
      // Unreachable: a resolved file is `.ready`, not `.unavailable`.
      EmptyView()
    }
  }

  @ViewBuilder
  private func failure(_ error: AppError) -> some View {
    centred(TranscriptNotice(failure: error))
  }

  /// A notice with nothing above it, drawn as `ContentUnavailableView` like the app's other
  /// empty states.
  ///
  /// No identifier on the `ContentUnavailableView`, which would rename the message and
  /// buttons; each identifier is on a leaf.
  ///
  /// Wrapped in a `ScrollView` because `ContentUnavailableView` does not scroll, and a long
  /// refusal under the keyboard clipped both exits off screen. The `GeometryReader` gives it a
  /// `minHeight` so it still centres when it fits. It sits inside the safe area, whose bottom
  /// edge is the composer, so `proxy.size.height` is already the visible height; subtracting
  /// the bar again would centre it too high.
  private func centred(_ notice: TranscriptNotice) -> some View {
    GeometryReader { proxy in
      ScrollView {
        ContentUnavailableView {
          Label(notice.title ?? "", systemImage: notice.symbolName)
        } description: {
          VStack(spacing: 8) {
            Text(notice.message)
              .accessibilityIdentifier("pane.chat.notice")
            if !notice.evidence.isEmpty {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(notice.evidence, id: \.self) { line in
                  Text(line)
                    .font(.caption2.monospaced())
                    // Middle-truncated, so both the head and tail of a uuid and the trailing
                    // `written 4s ago` survive.
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("pane.chat.candidates")
            }
          }
        } actions: {
          // Side by side while they fit, stacked when not, so no exit slides off the edge at
          // large text sizes. Prominence goes to the primary action; Show the Screen leads
          // only when it is the sole exit.
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              exits(notice, isProminent: !notice.offersRetry && !notice.offersFilePicker)
            }
            VStack(spacing: 10) {
              exits(notice, isProminent: !notice.offersRetry && !notice.offersFilePicker)
            }
          }
        }
        .frame(minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  /// A notice under a conversation that did parse: the truncated tail. An inline bar, not
  /// `ContentUnavailableView`, because it sits under turns that are still there.
  private func noticeBar(_ notice: TranscriptNotice) -> some View {
    noticeBody(notice)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial)
      .overlay(alignment: .top) { Divider() }
  }

  /// No identifier on this stack, which would rename the message and button.
  @ViewBuilder
  private func noticeBody(_ notice: TranscriptNotice) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = notice.title {
        Text(title)
          .font(.headline)
      }
      // Draws the notice's symbol, which separates in-progress from fault. An `HStack`, not a
      // `Label`, because a `Label` can merge icon and title into one element and carry the
      // identifier off the `Text`.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: notice.symbolName)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text(notice.message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.notice")
      }
      if !notice.evidence.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(notice.evidence, id: \.self) { line in
            Text(line)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pane.chat.candidates")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { exits(notice, isProminent: false) }
        VStack(spacing: 10) { exits(notice, isProminent: false) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The ways out of a notice, in the order they should be reached for.
  @ViewBuilder
  private func exits(_ notice: TranscriptNotice, isProminent: Bool) -> some View {
    // A retry belongs only to a fault; every other notice is an answer, and asking again
    // gives the same sentence. `.borderedProminent`, because retry is the primary action here.
    // No notice offers both retry and the file picker.
    if notice.offersRetry {
      // `ProminentButtonLabel` on both prominent buttons: the style's fixed white label fails
      // 4.5:1 on most bundled themes.
      Button { shown.reload() } label: {
        ProminentButtonLabel(TranscriptChatCopy.retry)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("pane.chat.retry")
    }
    // The primary exit from the refusal: Driverr will not choose a file for you.
    if notice.offersFilePicker {
      Button {
        // Requested here, not when the refusal was drawn, so a refusal nobody acts on costs no
        // extra round trip.
        model.loadBriefsIfNeeded()
        isChoosingFile = true
      } label: {
        ProminentButtonLabel(TranscriptNotice.chooseFileTitle)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("pane.chat.chooseFile")
    }
    if notice.offersScreen(inSubagentChat: isShowingSubagent) {
      showScreenButton(isProminent: isProminent)
    }
  }

  // MARK: - Choosing a file by hand

  /// The file picker: one row per candidate, keyed on the first thing somebody typed.
  ///
  /// Uuids and close mtimes cannot tell sessions apart to a person. The wording, order and
  /// bound come from `TranscriptPicker` in `DriverrCore`. A row whose opening line has not
  /// arrived still draws from the filename and mtime, so the fetch never blocks the pick.
  @ViewBuilder
  private func picker(_ picker: TranscriptPicker, directory: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(picker.title)
          .font(.headline)
        Text(picker.message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.picker.message")
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(Array(picker.candidates.enumerated()), id: \.element.id) { index, candidate in
            candidateRow(candidate, at: index, in: directory)
          }
          // No silent cap, or a list stopped at six would read as the whole directory.
          if let note = picker.omittedNote {
            Text(note)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 4)
              .accessibilityIdentifier("pane.chat.picker.omitted")
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
      }
      // On the scroll view, not the stack: the rows carry their own identifiers.
      .accessibilityIdentifier("pane.chat.picker")

      HStack {
        Button { isChoosingFile = false } label: {
          BorderedButtonLabel(TranscriptPicker.cancelTitle)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("pane.chat.picker.cancel")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(.thinMaterial)
      .overlay(alignment: .top) { Divider() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// One candidate, as a tappable row.
  ///
  /// One accessibility element for the whole row. The identifier is positional, because the
  /// order is `TranscriptFile.newestFirst`, tested in `DriverrCore`.
  private func candidateRow(
    _ candidate: TranscriptCandidate,
    at index: Int,
    in directory: String
  ) -> some View {
    Button {
      model.choose(candidate.file, in: directory)
      isChoosingFile = false
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.title)
            .font(.callout)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
          Text(candidate.detail)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
        // A chevron, so the row reads as a button.
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(themeAccent)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(candidate.accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("pane.chat.picker.candidate.\(index)")
  }

  /// The exit that needs nothing installed and always works. It shows the captured screen on
  /// the Chat side of the segment.
  private func showScreenButton(isProminent: Bool) -> some View {
    Button { isShowingScreen = true } label: {
      BorderedButtonLabel(TranscriptNotice.showScreenTitle)
    }
      .buttonStyle(.bordered)
      .font(isProminent ? .body : .footnote)
      .accessibilityIdentifier("pane.chat.showScreen")
  }
}

#if DEBUG

  /// The seeded conversation, drawn the way an agent pane opens.
  #Preview("Pane chat") {
    PaneChatView(
      model: PreviewSupport.transcript(),
      agentName: "Claude",
      screen: PreviewSupport.paneScreen()
    )
  }

  /// An agent this build has no reader for. Opens straight onto the captured screen, because
  /// there was never a conversation to fail at reading.
  #Preview("Pane chat — an agent Driverr can't read") {
    PaneChatView(
      model: PreviewSupport.transcript(for: PreviewSupport.unreadableAgentPane),
      agentName: "Gemini",
      screen: PreviewSupport.paneScreen(for: PreviewSupport.unreadableAgentPane)
    )
  }

  /// The refusal: two sessions written seconds apart in one directory. Choose a File swaps it
  /// for the candidate list, inline.
  #Preview("Pane chat — Driverr can't tell which session") {
    PaneChatView(
      model: PreviewSupport.transcript(run: PreviewSupport.ambiguousTranscript),
      agentName: "Claude",
      screen: PreviewSupport.paneScreen()
    )
  }

  /// Three rows of chrome over a conversation, at roughly triple text size.
  #Preview("Pane chat — accessibility text size") {
    PaneChatView(
      model: PreviewSupport.transcript(),
      agentName: "Claude",
      screen: PreviewSupport.paneScreen()
    )
    .environment(\.dynamicTypeSize, .accessibility3)
  }

#endif

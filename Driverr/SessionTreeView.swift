import DriverrCore
import DriverrTerm
import Foundation
import SwiftUI

/// A host's herdr session: workspace, tab, pane.
///
/// The tree arrives assembled and ordered from `DriverrHerdr` and `DriverrCore`, where it
/// is tested. This view renders it.
struct SessionTreeView: View {
  @Environment(\.settingsModel) private var settingsModel
  @Environment(\.colorScheme) private var colorScheme

  /// `@Bindable` because the rename field writes `model.renameDraft`. See
  /// `SessionModel.RenamePrompt` for why the draft is on the model.
  @Bindable var model: SessionModel
  /// This host's transcripts, so a blocked row can quote its question. Optional because a
  /// tree can render without a connection. No cache means no quote, the same as an
  /// unreadable transcript, and neither is an error.
  var transcripts: PaneTranscriptCache?
  /// What to do when a pane is chosen. `nil` makes the rows inert.
  var onSelect: ((Pane) -> Void)?

  /// Answer a pane without opening a terminal on it. The whole Needs-you row does this; a
  /// small icon beside a full-row button was too easy to miss.
  ///
  /// Tree rows keep `onSelect`, because `onReply` raises the keyboard over the pane.
  ///
  /// A callback, not a sheet from here. This view is sections of another screen's `Form`,
  /// and a sheet attached inside a `List` row never presents.
  var onReply: ((Pane) -> Void)?

  /// Start a terminal, on a host that can with nothing open. `nil` offers nothing, which is
  /// what a TUI host gets. A callback, for `onReply`'s reason: the start ends in a presentation.
  var onStartTerminal: (() -> Void)?

  /// Only the rename row is a text input in this tree, so this focus cannot bind to
  /// anything else.
  @FocusState private var isRenameFieldFocused: Bool
  @State private var renameSelection: TextSelection?

  var body: some View {
    Group {
      needsYouSection
      treeSection
    }
    // Animated, because the Needs-you section appearing or vanishing moves every row below
    // it. Visible movement stops a tap landing on the wrong pane.
    .animation(.default, value: model.tree)
  }

  /// Blocked agents, lifted to the top of the sidebar so "is anything waiting on me?" is
  /// answered first. The tree below keeps its shape, so this is a second view of the same
  /// panes.
  @ViewBuilder
  private var needsYouSection: some View {
    let blocked = model.blockedPanesNewestFirst
    if !blocked.isEmpty {
      Section {
        ForEach(blocked) { pane in
          blockedRow(pane)
        }
      } header: {
        // On the header, not the `Section`. The count is spoken as a sentence, because
        // "Needs you, 3" does not say three of what.
        Text(NeedsYouSection.title(count: blocked.count))
          .accessibilityLabel(NeedsYouSection.spokenTitle(count: blocked.count))
          .accessibilityIdentifier("session.needsYou")
      }
    } else if !model.tree.isEmpty, let calm = model.tree.agentStatusCounts.calmSummary {
      // With nothing blocked, the same slot says so in words, from the counts the badge
      // uses, so the two cannot disagree.
      Section {
        Text(calm)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("session.calm")
      }
    }
  }

  /// One blocked pane: what it is, where, how long it has waited, what it asked, and the way
  /// to answer.
  ///
  /// The content is a `BlockedPaneRow`, tested in `swift test`. No quote and no age is the
  /// ordinary case for an unreadable transcript, not an error.
  @ViewBuilder
  private func blockedRow(_ pane: Pane) -> some View {
    let transcript = transcripts?.model(for: pane)
    // From the page, not `lastAssistantMessage`, which returns the stop's own text.
    let stop = transcript?.transcript?.agentStop

    // A limit goes stale a second past its reset without a re-read. The clock is read in
    // the body, for the reason in `AgentStopRow.body`.
    let reset = stop?.resetsAt.map { [$0.addingTimeInterval(1)] } ?? []
    let label = TimelineView(.explicit(reset)) { _ in
      blockedLabel(
        BlockedPaneRow(
          pane: pane,
          location: model.tree.location(of: pane),
          lastMessage: transcript?.lastAssistantMessage,
          quietSince: transcript?.lastActivity,
          blockedSince: model.blockedSince(for: pane),
          stop: stop,
          asOf: Date()
        ),
        pane: pane
      )
    }

    // The row is the reply. It falls back to selection only without a reply handler.
    Group {
      if let open = onReply ?? onSelect {
        Button { open(pane) } label: { label }
          .buttonStyle(.plain)
          // A `.plain` button gets no pointer highlight of its own.
          .hoverEffect(.highlight)
          // A quote-less row can be shorter than a 44 pt target.
          .frame(minHeight: 44)
          .accessibilityIdentifier("session.blockedPane")
      } else {
        label
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("session.blockedPane")
      }
    }
    // Not `.task(id:)`; see `PaneTranscriptModel.currentLoad`. `loadIfNeeded` no-ops after
    // the first call.
    .task { transcript?.loadIfNeeded() }
  }

  /// What a Needs You row draws, above the reply action.
  private func blockedLabel(_ row: BlockedPaneRow, pane: Pane) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let notice = row.stopNotice {
          stopGlyph(notice, label: row.stopGlyphAccessibilityLabel, pane: pane)
        } else {
          PaneBadge(pane: pane)
        }
        Text(row.title)
          // A headline, so it does not read as one more tree row.
          .font(.headline)
          .foregroundStyle(.primary)
        Spacer(minLength: 0)
      }
      Text(row.meta)
        .font(.caption)
        .foregroundStyle(.secondary)
        // The same facts as a sentence, without the title, which speaks for itself above.
        .accessibilityLabel(row.metaAccessibilityLabel)
        .accessibilityIdentifier("session.blockedMeta")
      if let notice = row.stopNotice {
        stopBlock(notice, detail: row.stopDetail, label: row.stopAccessibilityLabel)
      } else if let quote = row.quote {
        quoteBlock(quote, label: row.quoteAccessibilityLabel)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    // SwiftUI aligns the separator to the last `Text`, which here is inside the quote.
    // Pinning it to the leading edge draws the full-width rule.
    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
  }

  /// The stop's glyph in the badge's place. herdr still says blocked, and a red badge would
  /// say "waiting for you" over a row that says the agent stopped.
  ///
  /// Drawn over a hidden `PaneBadge`, so it takes the badge's width and baseline at every
  /// text size.
  private func stopGlyph(_ notice: AgentStopNotice, label: String?, pane: Pane) -> some View {
    PaneBadge(pane: pane)
      .hidden()
      .accessibilityHidden(true)
      .overlay {
        Image(systemName: notice.symbolName)
          .foregroundStyle(notice.isStale ? Color.secondary : Color.orange)
          .accessibilityLabel(label ?? notice.title)
          // Not `status.*`: that family names a herdr status, and herdr says blocked.
          .accessibilityIdentifier("session.blockedStopGlyph")
      }
  }

  /// Why the agent stopped, in place of a quote.
  ///
  /// Driverr's words in its own chrome, not the terminal palette, because quoting the stop
  /// record made a limited pane read as one waiting on its owner. No `lineLimit`, for
  /// `quoteBlock`'s reason.
  private func stopBlock(
    _ notice: AgentStopNotice, detail: QuotedMessage?, label: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(notice.title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(notice.isStale ? Color.secondary : Color.primary)
      if let detail {
        Text(verbatim: detail.text)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? notice.title)
    .accessibilityIdentifier("session.blockedStop")
  }

  /// The agent's last message, in the terminal's colours, so it reads as the agent's words
  /// and not Driverr's chrome.
  ///
  /// `Text(verbatim:)`, because remote output must not be treated as a localisation key or
  /// markdown. `DriverrTranscript` has already stripped escapes via `PaneScreenText.plain`.
  ///
  /// No `lineLimit`. `QuotedMessage` already bounds it, and a display clamp would cut it at
  /// the large text sizes where it matters most.
  private func quoteBlock(_ quote: QuotedMessage, label: String?) -> some View {
    let palette = settingsModel.settings.theme.palette(
      for: colorScheme == .dark ? .dark : .light
    )
    return Text(verbatim: quote.text)
      .font(.system(.footnote, design: .monospaced))
      .foregroundStyle(palette.foreground.swiftUIColor)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(.quaternary, lineWidth: 1)
      }
      .accessibilityLabel(label ?? quote.text)
      .accessibilityIdentifier("session.blockedQuote")
  }

  private var treeSection: some View {
    Section {
      switch model.state {
      // Two cases, because in `case .idle, .loading where …` the `where` binds only to the
      // second pattern.
      case .idle:
        loadingRow
      case .loading where model.tree.isEmpty:
        loadingRow

      case .failed(let error) where model.tree.isEmpty:
        // Only with nothing to show. A failure over a tree keeps the tree and says so in
        // the footer.
        Text(error.errorDescription ?? "herdr could not be reached.")
          .accessibilityIdentifier("session.error")

      default:
        if model.tree.isEmpty {
          // A core has terminals and no workspaces, so the sentence follows who can start one.
          Text(
            onStartTerminal == nil
              ? "herdr is running here, but has no workspaces open."
              : "No terminals are open here."
          )
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("session.empty")
          if let onStartTerminal, model.offersTerminalStart {
            startTerminalRows(onStartTerminal)
          }
        } else {
          ForEach(model.tree.workspaces) { workspace in
            // **Above the row it renames.** After the disclosure group it lands below the
            // expanded contents, and a lazy `Form` does not build a row that far down, so
            // the field never appears. Inside the group fails when collapsed.
            if let prompt = model.pendingRename(for: .workspace(id: workspace.id)) {
              renameRow(prompt, noun: "workspace")
            }
            // An `.inline` tab has no row of its own, so its editor sits by the workspace row.
            if workspace.tabHeaderStyle == .inline, let tab = workspace.tabs.first,
              let prompt = model.pendingRename(for: .tab(id: tab.id))
            {
              renameRow(prompt, noun: "tab")
            }
            workspaceGroup(workspace)
          }
        }
      }
    } header: {
      HStack {
        Text("Session")
        Spacer()
      }
    } footer: {
      // A stale tree says so, or it reads as current.
      if let failure = model.failure, !model.tree.isEmpty {
        Text("Showing the last session read. \(failure.errorDescription ?? "")")
          .accessibilityIdentifier("session.stale")
      } else if model.pollingPaused, !model.tree.isEmpty {
        Text("Connection lost. Showing the last session read.")
          .accessibilityIdentifier("session.stale")
      }
    }
  }

  private var loadingRow: some View {
    HStack {
      ProgressView()
      Text("Reading the session…")
    }
    .accessibilityIdentifier("session.loading")
  }

  /// The empty state's one action, then what became of it. Inline, as `renameRow` is.
  @ViewBuilder
  private func startTerminalRows(_ start: @escaping () -> Void) -> some View {
    if model.terminalStart == .starting {
      // A `Label`, so the words stay on New Terminal's edge and the row does not jump.
      Label {
        Text("Starting a terminal…")
      } icon: {
        ProgressView()
      }
      .accessibilityIdentifier("session.startingTerminal")
    } else {
      Button(action: start) {
        Label("New Terminal", systemImage: "plus.rectangle")
      }
      .accessibilityIdentifier("session.newTerminal")
      if case .failed(let error) = model.terminalStart {
        RowProblemLabel(
          error.errorDescription ?? "The terminal could not be started.",
          systemImage: "xmark.octagon"
        )
        .accessibilityIdentifier("session.newTerminal.error")
      }
    }
  }

  /// Whether this workspace is expanded. Toggling sends nothing to the host, because
  /// browsing on the phone must never move anything on the desk.
  private func isExpanded(_ workspace: Workspace) -> Binding<Bool> {
    Binding(
      get: { model.isWorkspaceExpanded(workspace) },
      set: { model.setWorkspace(workspace, expanded: $0) }
    )
  }

  /// One workspace: a disclosure row, its tab headers, and its panes. Three levels drawn
  /// as three shapes, not three indents.
  private func workspaceGroup(_ workspace: Workspace) -> some View {
    DisclosureGroup(isExpanded: isExpanded(workspace)) {
      let showsHeaders = workspace.tabHeaderStyle == .headers
      ForEach(workspace.tabs) { tab in
        // `Workspace.tabHeaderStyle` decides the tab level, not `tabs.count` here.
        if showsHeaders {
          // Above its header, for the workspace editor's reason. Only `.headers` tabs have
          // a row. `.inline` is renamed from the workspace row's menu. `.none` is not
          // renamable: herdr named it after its position and it has no row.
          if let prompt = model.pendingRename(for: .tab(id: tab.id)) {
            renameRow(prompt, noun: "tab")
          }
          tabHeader(tab)
        }
        // herdr's order, so a status update changes a badge, not the row under a thumb.
        ForEach(tab.panes) { pane in
          paneRow(pane)
        }
      }
    } label: {
      workspaceLabel(workspace)
    }
    // No `swipeActions`: a `DisclosureGroup` row in this `Form` does not respond to a
    // swipe, while the tab header does. Long press is the workspace row's trigger; see
    // `workspaceLabel`.
  }

  /// Rename, as every trigger draws it, so the swipe action and the menu cannot drift. The
  /// identifier is on this leaf button.
  ///
  /// `title` varies because the workspace row's menu can hold two renames at once, for the
  /// workspace and its inline tab. Elsewhere it is the bare word.
  private func renameButton(
    _ target: RenameTarget,
    currentLabel: String,
    title: String = "Rename\u{2026}",
    identifier: String
  ) -> some View {
    Button {
      model.startRenaming(target, currentLabel: currentLabel)
    } label: {
      Label(title, systemImage: "pencil")
    }
    .accessibilityIdentifier(identifier)
  }

  /// The same button as a swipe pill: bare "Rename", no ellipsis, because a pill is not a
  /// menu item.
  ///
  /// `SwipeActionTint.neutral`, not the theme accent, because UIKit draws the pill's label
  /// white whatever the fill. `SwipeActionTint` has the reasons and `ThemeTests` the
  /// ratios.
  private func renameSwipeButton(
    _ target: RenameTarget,
    currentLabel: String,
    identifier: String
  ) -> some View {
    renameButton(target, currentLabel: currentLabel, title: "Rename", identifier: identifier)
      .tint(SwipeActionTint.neutral.swiftUIColor)
  }

  /// The disclosure row itself. The identifier is on this label, not the
  /// `DisclosureGroup`, which would overwrite every tab's and pane's.
  private func workspaceLabel(_ workspace: Workspace) -> some View {
    HStack {
      if !model.isWorkspaceExpanded(workspace), let status = workspace.status {
        AgentStatusBadge(status: status)
      }
      Text(workspace.label)
        .font(.subheadline.weight(.semibold))
      // Only `.inline`: a single user-named tab. See `Workspace.tabHeaderStyle`.
      if workspace.tabHeaderStyle == .inline, let tab = workspace.tabs.first {
        Text("· \(tab.label)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      let paneCount = workspace.tabs.reduce(into: 0) { $0 += $1.panes.count }
      Text("\(paneCount) pane\(paneCount == 1 ? "" : "s")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("session.workspace")
    // On the label, not the group. On the group it would cover every pane inside, and a
    // long press on a pane would offer to rename the workspace.
    .contextMenu {
      // Empty leaves no menu at all, so a core's row does not lift on a long press.
      if model.canRename(.workspace(id: workspace.id)) {
        renameButton(
          .workspace(id: workspace.id),
          currentLabel: workspace.label,
          title: workspace.tabHeaderStyle == .inline
            ? "Rename Workspace\u{2026}" : "Rename\u{2026}",
          identifier: "session.workspace.renameMenu"
        )
      }
      // The only route to an `.inline` tab's rename, since the tab has no row of its own.
      if workspace.tabHeaderStyle == .inline, let tab = workspace.tabs.first,
        model.canRename(.tab(id: tab.id))
      {
        renameButton(
          .tab(id: tab.id),
          currentLabel: tab.label,
          title: "Rename Tab\u{2026}",
          identifier: "session.workspace.renameTabMenu"
        )
      }
    }
  }

  /// A tab: a header, not a row. Secondary and not tappable, because there is nothing to do
  /// to a tab from a phone.
  ///
  /// `.subheadline`, between the workspace row and the panes. At `.caption` it read as a
  /// caption of the row above.
  private func tabHeader(_ tab: DriverrCore.Tab) -> some View {
    HStack(spacing: 6) {
      Text(tab.label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("session.tab")
    // An ordinary row, so both triggers attach here.
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if model.canRename(.tab(id: tab.id)) {
        renameSwipeButton(
          .tab(id: tab.id),
          currentLabel: tab.label,
          identifier: "session.tab.rename"
        )
      }
    }
    .contextMenu {
      if model.canRename(.tab(id: tab.id)) {
        renameButton(
          .tab(id: tab.id), currentLabel: tab.label, identifier: "session.tab.renameMenu")
      }
    }
  }

  /// The rename field, or herdr's refusal, inline in the row. Not a sheet or alert, which
  /// would not present from here (CLAUDE.md, "Never present from inside a presentation").
  @ViewBuilder
  private func renameRow(_ prompt: SessionModel.RenamePrompt, noun: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      switch prompt {
      case .editing:
        // **Buttons above the field.** iOS scrolls only the focused field into view, so
        // below it they sat under the keyboard and Cancel was unreachable.
        HStack(spacing: 8) {
          Text("Rename this \(noun)")
            .font(.footnote)
            .lineLimit(1)
          Spacer(minLength: 8)
          Button { model.cancelRenaming() } label: {
            BorderedButtonLabel("Cancel")
          }
          .accessibilityIdentifier("session.rename.cancel")
          Button { Task { await model.commitRename() } } label: {
            BorderedButtonLabel("Rename")
          }
          .accessibilityIdentifier("session.rename.commit")
          .disabled(model.isRenameInFlight)
        }
        .controlSize(.small)
        // Takes focus itself, and selects the whole draft once focus lands so the first
        // keystroke replaces the name. See `PanePromptBar`.
        TextField(
          "\(noun.capitalized) name",
          text: $model.renameDraft,
          selection: $renameSelection
        )
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($isRenameFieldFocused)
        .submitLabel(.done)
        .onSubmit { Task { await model.commitRename() } }
        .accessibilityIdentifier("session.rename.field")
        .task { isRenameFieldFocused = true }
        .onChange(of: isRenameFieldFocused) { _, focused in
          guard focused else { return }
          renameSelection = TextSelection(
            range: model.renameDraft.startIndex..<model.renameDraft.endIndex)
        }

      case .failed(_, let error):
        Text(error.errorDescription ?? "herdr refused the request.")
          .font(.footnote)
          .accessibilityIdentifier("session.rename.error")
        HStack {
          Spacer()
          Button { model.dismissRenameFailure() } label: {
            BorderedButtonLabel("OK")
          }
          .accessibilityIdentifier("session.rename.dismissError")
        }
      }
    }
    .buttonStyle(.bordered)
    .frame(maxWidth: .infinity, alignment: .leading)
    // No identifier on this container, which would overwrite the field's and buttons'.
  }

  @ViewBuilder
  private func paneRow(_ pane: Pane) -> some View {
    // A button only when there is something to do, because a disabled `Button` dims its
    // label. The tree opens a pane and does not reply to one; see `onReply`.
    if let onSelect {
      Button { onSelect(pane) } label: { paneLabel(pane) }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .frame(minHeight: 44)
        .accessibilityIdentifier("session.pane")
    } else {
      paneLabel(pane)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.pane")
    }
  }

  /// The second line of a pane row: what it is doing, or where it is.
  ///
  /// An agent's is `{agent} · {status}` in herdr's format, so the state is in words and not
  /// only colour. A stopped agent says `Stopped`, not herdr's `Blocked`. A shell shows its
  /// directory, truncated from the head.
  private func subtitle(for pane: Pane, stop: PaneStopBadge?) -> String? {
    if let agent = pane.agent {
      let status = stop?.label ?? agent.status.displayName
      if pane.title.caseInsensitiveCompare(agent.name) == .orderedSame {
        return [status, pane.directory].compactMap { $0 }.joined(separator: " · ")
      }
      return "\(agent.name) · \(status)"
    }
    return pane.directory
  }

  private func paneLabel(_ pane: Pane) -> some View {
    // The same stop the Needs you row reads, for any agent pane, since a limited pane can
    // report idle or working while it waits.
    //
    // **`existingModel`, never `model(for:)`.** `ConnectionModel.apply(_:)` refreshes every
    // existing model whose pane moved, so a model made here would fetch every agent pane on
    // its first status change. An unopened, unblocked pane shows no stop.
    // `SessionTreeTranscriptReadTests` holds this.
    //
    // A blocked pane uses `model(for:)`, because the Needs you row loads it anyway. A lazy
    // `List` promises no row order and the cache is not observable, so looking it up here
    // would miss it if this row came first. Reading `.transcript` subscribes to the load.
    let cached =
      pane.agent?.status == .blocked
      ? transcripts?.model(for: pane) : transcripts?.existingModel(for: pane.id)
    let stop = cached?.transcript?.agentStop
    // Stale at the reset without a re-read; see `blockedRow`.
    let reset = stop?.resetsAt.map { [$0.addingTimeInterval(1)] } ?? []
    return TimelineView(.explicit(reset)) { _ in
      let badge = PaneStopBadge(status: pane.agent?.status, stop: stop, asOf: Date())
      HStack(spacing: 8) {
        PaneBadge(pane: pane, stop: badge)
        VStack(alignment: .leading, spacing: 1) {
          Text(pane.title)
            .foregroundStyle(pane.agent == nil ? .secondary : .primary)
            .lineLimit(1)
          if let subtitle = subtitle(for: pane, stop: badge) {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        Spacer()
      }
    }
    .contentShape(.rect)
  }
}

#if DEBUG

  /// The seeded session: an agent pane, a blocked one, a finished one, and two shells. The
  /// same tree the UI suite and the store tour see.
  #Preview("Session tree") {
    PreviewSessionTree()
  }

  #Preview("Session tree — dark") {
    PreviewSessionTree()
      .preferredColorScheme(.dark)
  }

  /// Two blocked panes, one quoting its question and one with nothing to quote.
  ///
  /// `w1:p2` is Claude with a readable session. `w2:p1` is Gemini, which this build has no
  /// reader for, so it has no quote and no age. That row must not look like an error.
  #Preview("Session tree — blocked, with and without a question") {
    PreviewSessionTree(tree: PreviewSupport.blockedSession)
  }

  #Preview("Session tree — blocked, with and without a question, dark") {
    PreviewSessionTree(tree: PreviewSupport.blockedSession)
      .preferredColorScheme(.dark)
  }

  /// Thirteen panes across four workspaces, for judging what collapsing has to do.
  #Preview("Session tree — crowded") {
    PreviewSessionTree(tree: PreviewSupport.crowdedSession)
  }

  /// The size that breaks layouts. Check the Needs you row here: badge, headline, meta
  /// line and an unclamped quote.
  #Preview("Session tree — accessibility XXXL") {
    PreviewSessionTree()
      .environment(\.dynamicTypeSize, .accessibility3)
  }

  /// Without callbacks, the rows are not buttons. See `paneRow`.
  #Preview("Session tree — read-only rows") {
    PreviewSessionTree(interactive: false)
  }

  /// herdr is running, but nothing is open in it. Its own state, not a failure.
  #Preview("Session tree — empty session") {
    PreviewSessionTree(tree: .empty)
  }

#endif

import DriverrCore
import SwiftUI
import UIKit

/// One row of a conversation.
///
/// **Speaker, order and boundary are typed fields on `TranscriptTurn`**, never inferred from
/// a glyph or indent. Everything drawn here is emphasis on those facts: a tinted agent
/// label, a filled container on the turn being answered, and a bubble on what the person
/// said.
///
/// The speaker label says who spoke; the bubble only marks it. Only the human side gets a
/// bubble, because facing bubbles would assert speaker by shape and waste width on the long
/// agent turns.
struct TranscriptTurnView: View {
  @Environment(\.themeAccent) private var themeAccent

  let turn: TranscriptTurn
  let agentName: String
  /// The last turn in the transcript: never bounded, and the only one with a relative time.
  let isNewest: Bool
  /// The turn before this one, for the time separator. `nil` for the page's first turn.
  let previousTurn: TranscriptTurn?
  /// Whether this is the newest assistant turn while the pane is `blocked`: the message the
  /// reader is here to answer.
  let isFinalBlockedAnswer: Bool
  /// What herdr reports the agent is doing, or `nil` for a pane with no agent.
  ///
  /// A call with no result is a running tool on a `.working` pane and a permission prompt on
  /// a `.blocked` one, and the file cannot tell them apart. `PendingToolCallNotice` needs it.
  let agentStatus: AgentStatus?
  let isOpen: Bool
  let isExpanded: Bool
  let onToggleOpen: () -> Void
  let onToggleExpand: () -> Void
  /// Opens one of this turn's images full size. `nil` where there is no viewer, and the
  /// thumbnails are then not tappable.
  var onOpenImage: ((TranscriptImage) -> Void)?
  /// Opens the sub-agent a spawn line links to, with the line's name. `nil` in a sub-agent's
  /// own chat or with no stack, and the line is then not tappable.
  var onOpenSubagent: ((SubagentLink, String) -> Void)?
  /// The chat's width, read at `PaneChatView`'s outer frame before this row lays out.
  /// `MeasuredTurnBody` seeds its width from it. At `0`, `wrappedLines(of:)` falls back to
  /// source lines, and a bounded turn draws the wrong height for its first frame.
  var estimatedContentWidth: CGFloat = 0
  /// This turn's markdown, parsed when the page settled. `nil` for a preview, which parses
  /// on the spot.
  var render: TranscriptTurnRender?

  /// How many lines of a bounded (not newest, not expanded) turn are drawn before `Show all`.
  /// Compared against measured wrapped lines, not source lines.
  private static let turnLineLimit = 24

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if turn.showsTimeSeparator(after: previousTurn) {
        separator
      }
      row
      // The answered questions, under the run that asked, because at rest the question
      // itself is scrolled off.
      if let answered = turn.toolRun?.answeredQuestions, !answered.isEmpty {
        answeredQuestions(answered)
      }
      // A pending call's chips are a separate `ChatItem.reply` after this turn, drawn by
      // `PaneChatView.replyRow`, because the chat rests at their top.
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private var separator: some View {
    HStack {
      Rectangle().fill(Color(.separator)).frame(height: 0.5)
      if let at = turn.at {
        Text(at, style: .time)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var row: some View {
    switch turn.speech {
    case .human(let text):
      speech(text: text, identifier: "pane.chat.turn.human", isHuman: true)
    case .assistant(let text):
      speech(text: text, identifier: "pane.chat.turn.assistant", isHuman: false)
    case .tools(let run):
      toolRun(run)
    case .agentEvent(let event):
      agentEvent(event)
    }
  }

  // MARK: - One agent talking to another

  /// A teammate's message, idle notice or spawn, as one muted line, the shape Claude Code's
  /// own TUI draws. No bubble, speaker label or `You`; see
  /// `TranscriptTurn.speaker(agentName:)`.
  ///
  /// **The identifier is on the leaf `Text`, and the line is not a `Button`.** A container's
  /// identifier overwrites its children's, and a `Button` merges them, so either would take
  /// `pane.chat.turn.agentEvent` off the words. The tap is a gesture on the row.
  @ViewBuilder
  private func agentEvent(_ event: TranscriptTurn.AgentEvent) -> some View {
    // A spawn line with a link opens that sub-agent's chat. Other lines have nothing to tap.
    let opens = event.link.flatMap { link in onOpenSubagent.map { open in { open(link, event.subagentTitle) } } }
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // One `Text` with two styles, so it publishes one element carrying the whole line.
        agentEventText(event)
          .font(.caption)
          .foregroundStyle(.secondary)
          // Cut to one line only when a tap can open the body.
          .lineLimit(event.hasBody ? 1 : nil)
          .accessibilityIdentifier("pane.chat.turn.agentEvent")
          // A button only when a tap does something.
          .accessibilityAddTraits(event.hasBody || opens != nil ? [.isButton] : [])
          .accessibilityValue(event.hasBody ? openState(isExpanded) : "")
          .accessibilityHint(opens != nil ? TranscriptChatCopy.opensSubagent : "")
        if event.hasBody {
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            // Labelled, not hidden: a symbol's implicit label cannot be removed from the tree.
            .accessibilityLabel(openState(isExpanded))
        }
        Spacer(minLength: 0)
        if let task = event.task {
          taskLabel(task)
            .accessibilityIdentifier("pane.chat.turn.agentEvent.task")
        }
        // A disclosure chevron, where a list row keeps it.
        if opens != nil {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
      // A 44 pt target, while the text stays caption-sized.
      .frame(minHeight: 44, alignment: .leading)
      .onTapGesture {
        if let opens {
          opens()
          return
        }
        guard event.hasBody else { return }
        withAnimation(.snappy) { onToggleExpand() }
      }

      if isExpanded, event.hasBody {
        // **Quoted, with a rule in the gutter.** The body uses the same markdown as an
        // assistant turn and would otherwise read as this pane's agent talking; an indent
        // alone was not enough. The text stays primary, because it can carry code and diffs.
        // The gutter is padding, not a `Color.clear` spacer, which collapsed to zero.
        HStack(alignment: .top, spacing: 10) {
          Rectangle()
            .fill(Color(.separator))
            .frame(width: 2)
            .accessibilityHidden(true)
          AgentEventBody(text: event.body, contentWidth: estimatedContentWidth)
        }
        .padding(.leading, 16)
      }
    }
    // The conversation's 18 pt spacing is cancelled between adjacent event lines, so a run
    // of them sits at the 44 pt tap pitch and reads tighter than the turns around it. Not
    // after a time separator, which is a deliberate gap.
    .padding(.top, isAfterAnotherAgentEvent ? -18 : 0)
  }

  /// Where a spawned agent or background command has got to, at the line's trailing edge:
  /// `Running · 3m`, `Finished · 2m 41s`. `DriverrCore` supplies the words.
  ///
  /// **A running label ticks on its own.** An unchanged session file writes no state, so the
  /// chat does not redraw, and a label computed at draw time would freeze. An ended task's
  /// time is fixed and gets no timer.
  ///
  /// Red only for a failure. A running task is primary so it stands out among ended ones.
  @ViewBuilder
  private func taskLabel(_ task: TaskProgress) -> some View {
    if task.state == .running {
      TimelineView(.periodic(from: .now, by: Self.runningTaskTick)) { context in
        taskText(task, asOf: context.date)
      }
    } else {
      taskText(task, asOf: Date())
    }
  }

  /// A task's state as the accessibility label speaks it. A running task says only that it
  /// is running, because the label is built outside the tick and a time would go stale.
  private func spokenTask(_ task: TaskProgress) -> String {
    task.state == .running ? TranscriptChatCopy.taskRunning : task.label(asOf: Date())
  }

  /// How often a running task's time redraws. The label shows minutes, so thirty seconds is
  /// often enough.
  private static let runningTaskTick: TimeInterval = 30

  private func taskText(_ task: TaskProgress, asOf now: Date) -> some View {
    Text(task.label(asOf: now))
      .font(.caption2.weight(task.state == .running ? .semibold : .regular))
      .monospacedDigit()
      .foregroundStyle(taskStyle(task.state))
      .lineLimit(1)
      .fixedSize()
  }

  private func taskStyle(_ state: TaskProgress.State) -> AnyShapeStyle {
    switch state {
    case .running: AnyShapeStyle(.primary)
    case .failed: AnyShapeStyle(.red)
    case .finished, .idle, .stopped: AnyShapeStyle(.secondary)
    }
  }

  /// Whether the turn before this one was also an inter-agent event, with no time separator
  /// between them.
  private var isAfterAnotherAgentEvent: Bool {
    previousTurn?.agentEvent != nil && !turn.showsTimeSeparator(after: previousTurn)
  }

  /// The collapsed line as one `Text`: the emphasised part semibold, the rest regular.
  ///
  /// **One `AttributedString` with two runs.** `Text` `+` is deprecated and warns, and two
  /// sibling `Text`s would publish two elements. The run's font overrides the ambient
  /// `.caption` for that run only.
  ///
  /// `DriverrCore` decides which words are `emphasised` and which `trailing`.
  private func agentEventText(_ event: TranscriptTurn.AgentEvent) -> Text {
    guard !event.emphasised.isEmpty else { return Text(event.trailing) }
    var emphasised = AttributedString(event.emphasised)
    emphasised.font = .caption.weight(.semibold)
    return Text(emphasised + AttributedString(event.trailing))
  }

  // MARK: - Something somebody said

  /// Something somebody said, with the speaker as a label above the text in both branches.
  /// The bubble is emphasis on that label, never a substitute; see the type's note.
  @ViewBuilder
  private func speech(text: String, identifier: String, isHuman: Bool) -> some View {
    if isHuman {
      // The person's turns are trailing bubbles, so they can be found by shape. The agent's
      // stay full width on the page's ground.
      HStack(spacing: 0) {
        Spacer(minLength: 32)
        speechBody(text: text, identifier: identifier, isHuman: true)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            Color(.secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
      }
    } else {
      speechBody(text: text, identifier: identifier, isHuman: false)
        .padding(isFinalBlockedAnswer ? 12 : 0)
        .background {
          if isFinalBlockedAnswer {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(themeAccent.opacity(0.08))
          }
        }
    }
  }

  @ViewBuilder
  private func speechBody(text: String, identifier: String, isHuman: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let speaker = turn.speaker(agentName: agentName) {
          Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isHuman ? Color.secondary : themeAccent)
            // So VoiceOver's headings rotor lists who spoke.
            .accessibilityAddTraits(.isHeader)
        }
        if turn.isCommand {
          Text("command")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        // No `Spacer` in the bubble, which would stretch it to full width. The agent's turns
        // use one to push the relative time to the trailing edge.
        if !isHuman {
          Spacer(minLength: 0)
          if isNewest, let relative = turn.relativeTime(asOf: Date()) {
            Text(relative)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let bodyText = turn.text, !bodyText.isEmpty {
        // A slash command or `!` line is shown verbatim and monospaced, not as markdown.
        if isHuman || turn.isCommand {
          Text(bodyText)
            .font(turn.isCommand ? .callout.monospaced() : .body)
            .textSelection(.enabled)
            .frame(maxWidth: isHuman ? nil : .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
        } else {
          assistantText(bodyText, identifier: identifier)
        }
      }

      // The thumbnails, then a notice counting only the images that did not draw
      // (`imagesNoticeLabel`, not the total).
      if !turn.images.isEmpty {
        TranscriptImageStrip(images: turn.images, onOpen: onOpenImage)
          // Extra room, because a hard image edge sits closer to the bubble's edge than a
          // text baseline does.
          .padding(.bottom, 4)
      }

      if let imagesLabel = turn.imagesNoticeLabel {
        Label(imagesLabel, systemImage: "photo")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      // The turn's elapsed time, as a foot line, because the header's trailing slot holds
      // the newest turn's relative time. Secondary caption, not the accent: it is about the
      // turn, not part of it. `durationLabel` is already `nil` for non-agent turns.
      if let duration = turn.durationLabel {
        Text(duration)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pane.chat.turn.duration")
      }
    }
  }

  /// The assistant's words as markdown. Never bounded when newest, because the question is
  /// at the message's tail and may still be arriving.
  private func assistantText(_ text: String, identifier: String) -> some View {
    // The `??` parse is the preview's path. A turn from a `PaneTranscriptModel` arrives
    // with its render, so the app never parses per body evaluation.
    MeasuredTurnBody(
      render: render
        ?? TranscriptTurnRender(
          text: text, blocks: TranscriptMarkdown.blocks(from: text)),
      isBounded: !isNewest,
      lineLimit: Self.turnLineLimit,
      isExpanded: isExpanded,
      identifier: identifier,
      initialWidth: estimatedContentWidth,
      onToggleExpand: onToggleExpand
    )
  }

  // MARK: - A run of tool calls

  /// A consecutive run of tool calls, as a quiet row that defers to the turns beside it.
  /// `OpenToolRuns.isOpen(_:)` and `toggle(_:)` own open and closed state;
  /// `ToolRun.closedCalls` and `openedCalls` say which calls are named.
  @ViewBuilder
  private func toolRun(_ run: ToolRun) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggleOpen) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "wrench.and.screwdriver")
            .font(.caption2)
            .foregroundStyle(.secondary)
            // Labelled, not hidden: neither `.ignore` nor `.accessibilityHidden` removes a
            // symbol's implicit label once published.
            .accessibilityLabel("Tool calls")
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(run.summary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              if let failureNote = run.failureNote {
                Text(failureNote)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.red)
              }
            }
            // The tally only when open. Closed, the rows below name the last calls. Open,
            // `earlierCalls` says "same kinds", which points at this line.
            if isOpen {
              Text(run.kindsSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 0 : -90))
            .accessibilityLabel(openState(isOpen))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(isOpen ? run.accessibilityLabel : run.closedAccessibilityLabel)
      .accessibilityValue(openState(isOpen))
      .accessibilityIdentifier("pane.chat.turn.tools")

      // Both states draw call rows and differ only in how many: `ToolRun.closedLimit`
      // closed, more when open.
      callRows(
        isOpen ? run.openedCalls : run.closedCalls,
        runID: turn.id,
        trailing: isOpen ? run.earlierCalls : run.moreCalls,
        trailingName: isOpen ? "earlier" : "more"
      )

      // Names which call is waiting, which a plain shell permission prompt writes nowhere
      // else. `PendingToolCallNotice` decides the words from herdr's status, because the
      // file cannot tell a running tool from a prompt. The chips are drawn outside this
      // row; see `body`.
      if let pending = run.pendingCall {
        let notice = pending.pendingNotice(agentStatus: agentStatus)
        Text(notice.label)
          .font(.caption.weight(.semibold))
          // Orange only for a question. A running tool reads like the other rows.
          .foregroundStyle(notice.isAsking ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .padding(.top, 6)
          .accessibilityIdentifier("pane.chat.turn.pending")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    // A faint inset fill, not ruled dividers, which drew a ladder of lines across a chat with
    // several runs.
    .background(
      Color(.quaternarySystemFill),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
  }

  /// Each answered question as its header, its words and the answer.
  ///
  /// One accessibility element per question, so VoiceOver reads one sentence. The check mark
  /// takes the accent because it marks the reader's choice, as a chosen chip does.
  private func answeredQuestions(_ answered: [AnsweredQuestion]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(answered.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 4) {
          if let header = item.header {
            QuestionHeaderTag(header)
          }
          if !item.question.isEmpty {
            Text(item.question)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(themeAccent)
            Text(item.answer)
              .font(.body.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        // Shared by every answered question; a test counts them or reads their labels.
        .accessibilityIdentifier("pane.chat.turn.answered")
      }
    }
  }

  /// The calls a run names, and a line about the ones it did not.
  ///
  /// One builder for both states, so the row identifiers are the same whether the run is
  /// open or closed.
  private func callRows(
    _ calls: [ToolCall],
    runID: String,
    trailing: String?,
    trailingName: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Divider()
        .padding(.top, 8)
        .padding(.bottom, 3)
      // By position, because a run can repeat a call.
      ForEach(Array(calls.enumerated()), id: \.offset) { index, call in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(call.displayName)
            .font(.caption2.monospaced().weight(.semibold))
          if let target = call.target, !target.isEmpty {
            Text(target)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
          // A background command's state. No tap-through: it has no transcript.
          if let task = call.task {
            taskLabel(task)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          call.task.map { "\(call.accessibilityLabel), \(spokenTask($0))" }
            ?? call.accessibilityLabel)
        // Numbered, so tests can count the rows.
        .accessibilityIdentifier("pane.chat.turn.tools.\(runID).call.\(index)")
      }
      if let trailing {
        Text(trailing)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.top, 1)
          .accessibilityIdentifier("pane.chat.turn.tools.\(runID).\(trailingName)")
      }
    }
  }

  private func openState(_ isOpen: Bool) -> String {
    isOpen ? TranscriptChatCopy.runIsOpen : TranscriptChatCopy.runIsClosed
  }
}

/// The body of an opened inter-agent event.
///
/// Parsed here on open, not with the page: `TranscriptRender` skips these long, numerous
/// bodies. In a `task` keyed on the text, not in `body`, which is re-evaluated on every
/// scroll, poll and keystroke.
///
/// **Keep the placeholder.** A `Group` around the `if let` draws nothing while the render is
/// `nil`, and a `task` on a view that renders nothing never runs, so the body never arrives.
/// A zero-height `Color.clear` is a real leaf.
private struct AgentEventBody: View {
  let text: String
  let contentWidth: CGFloat

  @State private var render: TranscriptTurnRender?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let render {
        TranscriptMarkdownView(render: render, allowances: nil, contentWidth: contentWidth)
          // One element, as for a turn's own text.
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("pane.chat.turn.agentEvent.body")
          .textSelection(.enabled)
      } else {
        Color.clear.frame(height: 0)
      }
    }
    .task(id: text) {
      render = TranscriptTurnRender(text: text, blocks: TranscriptMarkdown.blocks(from: text))
    }
  }
}

/// An assistant turn's blocks, bounded to `lineLimit` lines when not the newest turn, and
/// knowing by measurement whether that cut anything.
///
/// **Do not measure with two `Text`s, a `GeometryReader` and a `PreferenceKey`.** Two layout
/// passes feeding state back into their own layout hung the app with several such turns on
/// screen. `onGeometryChange` reports only the width, which nothing here feeds back into,
/// and each block is then measured with one synchronous `NSString.boundingRect`.
///
/// The budget is shared across blocks by `TranscriptMarkdown.allowances(forLineCounts:budget:)`,
/// tested in `DriverrCore`. Prose is measured in the body font, which can only err slightly
/// conservative. Code and diffs never wrap, so their line count is exact.
///
/// Before the first layout the estimate is the source line count, which can only
/// under-count. The turn is bounded from its first frame and can only grow toward the
/// budget, so its height settles rather than snapping shorter.
private struct MeasuredTurnBody: View {
  @Environment(\.themeAccent) private var themeAccent

  /// The turn's parsed blocks and inline strings, read by both the measurement and the
  /// drawing.
  let render: TranscriptTurnRender
  /// `false` for the newest turn, which is never cut.
  let isBounded: Bool
  let lineLimit: Int
  let isExpanded: Bool
  let identifier: String
  /// Seeds `width` so the first frame is not measured at `0`. See
  /// `TranscriptTurnView.estimatedContentWidth`.
  let initialWidth: CGFloat
  let onToggleExpand: () -> Void

  @State private var width: CGFloat

  init(
    render: TranscriptTurnRender, isBounded: Bool, lineLimit: Int, isExpanded: Bool,
    identifier: String, initialWidth: CGFloat, onToggleExpand: @escaping () -> Void
  ) {
    self.render = render
    self.isBounded = isBounded
    self.lineLimit = lineLimit
    self.isExpanded = isExpanded
    self.identifier = identifier
    self.initialWidth = initialWidth
    self.onToggleExpand = onToggleExpand
    _width = State(initialValue: initialWidth)
  }

  var body: some View {
    let counts = lineCounts
    let allowances =
      isBounded && !isExpanded
      ? TranscriptMarkdown.allowances(forLineCounts: counts, budget: lineLimit) : nil

    VStack(alignment: .leading, spacing: 4) {
      TranscriptMarkdownView(render: render, allowances: allowances, contentWidth: width)
        // **One element for the whole turn.** UI tests count turns, read labels and measure
        // `frame.maxY` by this identifier, and need exactly one element spanning the body.
        // It is also one thing somebody said, for a screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        // Width only; see this type's note.
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .textSelection(.enabled)
      // `isBounded` gates the button too. `isExpanded` survives a turn becoming the newest,
      // which would otherwise show `Show less` on a turn that is never cut.
      if isBounded, isExpanded || (allowances.map { $0 != counts } ?? false) {
        Button(isExpanded ? TranscriptChatCopy.showLess : TranscriptChatCopy.showAll) {
          onToggleExpand()
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(themeAccent)
        // A 44 pt target on a caption-sized label.
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("pane.chat.turn.expand")
      }
    }
  }

  /// How many lines each block takes at the width it is being drawn at.
  private var lineCounts: [Int] {
    render.blocks.map { block in
      switch block {
      // Both measure the resolved text from `render`, not the source, whose markup
      // characters would over-count lines and cut the turn early.
      case .paragraph(let raw):
        wrappedLines(of: render.plain(raw))
      case .heading(let title, _):
        wrappedLines(of: render.plain(title))
      case .list(let items, _):
        // One line per item, not measured: the marker column makes items narrower than the
        // turn, and measuring at the turn's width would be wrong.
        max(1, items.count)
      case .code(let code, _):
        // Scrolls rather than wraps, so its height is its line count.
        code.split(separator: "\n", omittingEmptySubsequences: false).count
      case .diff(let diff):
        diff.body.count + 1  // the card's own file header
      }
    }
  }

  /// The rendered line count of `text` at the measured width, or its source line count
  /// before the first layout has reported one.
  private func wrappedLines(of text: String) -> Int {
    let sourceLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    guard width > 0 else { return max(1, sourceLines) }
    let font = UIFont.preferredFont(forTextStyle: .body)
    let measured = (text as NSString).boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font],
      context: nil
    )
    return max(1, Int((measured.height / font.lineHeight).rounded()))
  }
}

import DriverrCore
import SwiftUI
import UIKit

/// The reply surface, at the bottom of the pane screen.
///
/// An inline bar, not a sheet, so it presents nothing and sits under the question it
/// answers, including under a captured screen with no transcript. `PanePromptBar` has the
/// same shape.
///
/// Idle, it is the field and Send. There are no terminal keys: a pending question is answered
/// by chips under its turn (`ReplyChipRow`), an interrupt is Stop, which shows only while the
/// agent is working, and Escape and the arrows are on the Terminal side. With no accessory
/// row, the keyboard's end frame is the safe area and iOS's own avoidance is correct.
///
/// The words come from `DriverrCore` (`PaneComposerHeader`, `PaneComposerStatus`,
/// `ToolCall.replyChips`), where `swift test` covers them.
struct PaneComposerBar: View {
  @FocusState private var isTextFocused: Bool

  /// Read only to shorten the `/` list at accessibility sizes, where rows are about twice as
  /// tall.
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The theme's accent. Never `Color.accentColor`, which ignores `.tint`.
  @Environment(\.themeAccent) private var themeAccent
  /// Black or white, whichever reads on the accent. The Send glyph sits on the accent fill,
  /// where a fixed white is under 4.5:1 on the default theme.
  @Environment(\.themeAccentForeground) private var themeAccentForeground

  /// The two-step Ctrl-C confirm: a single tap must never send the interrupt. Inline, in
  /// `PanePromptBar`'s shape.
  @State private var isConfirmingInterrupt = false

  /// The typed query the reader last dismissed the `/` list against. Compared with
  /// `model.text`, so the list returns as soon as the query changes.
  @State private var dismissedSuggestionsQuery: String?

  /// Which suggestion row an arrow key has highlighted. The arithmetic is
  /// `DriverrCore.SlashSuggestionSelection`.
  @State private var suggestionSelection = SlashSuggestionSelection()

  /// The field's caret, so the `/` list completes the word the caret is at the end of, not
  /// only a leading one. `nil` until the field reports a caret; see `caretOffset`.
  @State private var textSelection: TextSelection?

  @Bindable var model: PaneComposerModel

  /// The conversation this composer answers, read only for its own command turns for the `/`
  /// list. `nil` for a shell pane.
  var transcript: Transcript?

  /// What the host has installed, the half of the `/` list a fresh session has.
  ///
  /// Fetched and cached by `PaneTranscriptModel`, because this view is rebuilt on every
  /// keystroke. `SlashCommandCatalog.empty` until it arrives, so the list shows recents only.
  var catalog = SlashCommandCatalog.empty

  /// What the pane is doing, built by the screen from the live pane.
  ///
  /// The model is cached per pane for the whole connection, so its own `Pane` can be stale,
  /// while the status arrives on each poll. For a pane that is not blocked, this sentence is
  /// the only thing that changes.
  let header: PaneComposerHeader

  /// Whether the composer has been asked for, as from Reply.
  ///
  /// A closure because the request is consumed: the field takes the keyboard once on the way
  /// in and never again by itself. Otherwise every opened conversation would raise the
  /// keyboard.
  var takeFocusRequest: (() -> Bool)?

  /// Whether a request for the keyboard may be acted on yet. `.wait` holds it until the chat
  /// has read the session. `.decline` uses it up with the keyboard down, because the keyboard
  /// would cover the chips that answer the pane's question. See `ComposerFocusGate`.
  var focusGate: ComposerFocusGate = .allow

  /// What the focus task is keyed on: the pane, and whether its request may be acted on.
  private struct FocusKey: Hashable {
    let pane: String
    let gate: ComposerFocusGate
  }

  /// Reported up so the chat can return to the newest turn when the keyboard appears. See
  /// `PaneChatView.isComposerFocused`.
  var onFocusChange: ((Bool) -> Void)?

  /// This bar's frame in window coordinates, for `debug.keyboardMetrics` and hosted tests.
  /// Nothing lays out from it: the bar is a `safeAreaBar`, so the safe area owns the inset.
  ///
  /// `nil` in shipping builds, and then no probe is attached. `TerminalScreen` passes a closure
  /// only under `-uiTestingKeyboardMetrics`. Never feed it back into this bar's own padding;
  /// that loop hangs the app (see `MeasuredTurnBody`).
  /// `PaneComposerSlashSuggestionsLayoutTests` also reads it to check the `/` list is part of
  /// the bar's layout.
  var onLayoutProbe: ((CGRect) -> Void)?

  /// One line, one row: the collapsed shape for a landscape phone with the keyboard up.
  ///
  /// That state leaves about 100 pt between the navigation bar and the keys. The
  /// `Chat | Terminal` band takes 43 and the ordinary bar wants 115, so both cannot fit.
  /// Collapsed, the bar is one row about 54 pt tall: the field clamped to one line beside
  /// Send, with 3 pt card padding instead of 8. The 44 pt tap targets do not change; only the
  /// drawn circle shrinks. Every other state keeps the five-line field.
  var isCollapsed = false

  /// Asked for an image.
  ///
  /// A closure, not a `PhotosPicker` here; see `ComposerPhotosPicker`. `nil` hides the button.
  var onAttach: (() -> Void)?

  var body: some View {
    withSlashKeyHandling(barContent)
  }

  private var barContent: some View {
    // 4 pt spacing while collapsed, 8 otherwise. The collapsed landscape bar has about 100 pt,
    // and with 8 the stack overflowed at the top and the scene clipped the attachment row's
    // border. The row is a rigid 36 pt (see `attachmentRow`), and this pays for it.
    VStack(alignment: .leading, spacing: isCollapsed ? 4 : 8) {
      // Above the card, inside this bar's own stack. Not a popover or sheet, and not positioned
      // against the window or keyboard, so it stays directly over the composer wherever the
      // composer goes.
      if isConfirmingInterrupt {
        interruptConfirm
      } else if !slashSuggestions.isEmpty {
        slashSuggestionsList
      }
      // Above the card, like the `/` list and for the same reasons. Unlike the list, it is shown
      // while collapsed: it is one short row, and hiding it would leave an upload running with
      // nothing on screen.
      if model.attachment.isAttached {
        attachmentRow
      }
      card
    }
    // The same column as the conversation (`ChatColumn`), so no conversation text ever sits
    // beside the card and gets cut square at its edge. The cap also keeps the composer from
    // spanning a 13-inch iPad like a form.
    //
    // The cap is here, so the caller must not apply a second one. These lines cap at
    // `ChatColumn.width` and then pad `ChatColumn.inset` on each side, so the bar asks for the
    // measure plus both insets. `TerminalScreen` passes
    // `readableColumn(route, outsetBy: ChatColumn.inset * 2)` for that reason.
    //
    // The probe is an overlay, never a child of the stack, so it adds nothing to the layout;
    // as a child it pushed the collapsed bar over its landscape budget.
    .overlay(alignment: .topLeading) { uploadProbeReadout }
    .frame(maxWidth: ChatColumn.width, alignment: .leading)
    .padding(.horizontal, ChatColumn.inset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, isCollapsed ? 0 : 6)
    // 8 pt, and nothing else. The bar is in the safe area, so it rises with the keyboard.
    //
    // A home-indicator correction was removed here once and came back on hardware, where the
    // simulator had shown none. If the card runs under the keys on a device again, add the
    // correction here, as padding on this bar, and nowhere else. `debug.keyboardMetrics`
    // publishes `keyboardTop` and `composerBottom` so the gap can be read off a phone.
    .padding(.bottom, Self.cardBottomInset)
    // No material band and no divider: the card carries all of the composer's chrome, on the
    // same background as the transcript.
    //
    // No identifier on this stack. It would overwrite the field's, Send's and Stop's.
    .task(id: model.id) {
      // A dismissal belongs to the pane it was made on. This view survives a pane switch, so
      // without this a `/` dismissed on one pane stays dismissed on the next.
      dismissedSuggestionsQuery = nil
      // The same for the highlight: row 2 of one pane's list is a different command on another.
      suggestionSelection.reset()
    }
    // Its own task, keyed on the gate as well as the pane, so a request held by `.wait` is
    // acted on when the chat's read finishes. A request is used up once, so a later change
    // of the gate finds nothing to act on.
    .task(id: FocusKey(pane: model.id, gate: focusGate)) {
      switch focusGate {
      case .wait:
        break
      case .decline:
        _ = takeFocusRequest?()
      case .allow:
        if takeFocusRequest?() == true { isTextFocused = true }
      }
    }
    .onChange(of: isTextFocused) { _, focused in onFocusChange?(focused) }
    // Retire the dismissal as soon as the query moves off it. Otherwise dismissing on `/`,
    // typing `c` and deleting it would keep the list hidden. `.task(id:)` above fires only on
    // a pane switch.
    .onChange(of: model.text) { _, text in
      if text != dismissedSuggestionsQuery { dismissedSuggestionsQuery = nil }
      // A keystroke starts a fresh highlight, because the list recomputes on every one. The
      // model also refuses a stale index; this keeps the highlight from appearing to survive.
      suggestionSelection.reset()
    }
    // A caret moved by a tap or a selection can point at another `/word`, or none, so the
    // highlight starts again for the same reason as a keystroke.
    .onChange(of: textSelection) { suggestionSelection.reset() }
    // Reports the bar's own frame for `debug.keyboardMetrics`. Nothing lays out from it; see
    // `onLayoutProbe`.
    .modifier(ComposerLayoutProbe(report: onLayoutProbe))
    // No background on the bar: the card floats on the page.
    //
    // Announced on phase transitions, not on the status string, which ages itself ("Sent 40s
    // ago") and would re-announce on every tick.
    .onChange(of: model.state.phase) { _, phase in
      switch phase {
      case .sent, .failed:
        if let message = model.status?.message {
          UIAccessibility.post(notification: .announcement, argument: message)
        }
      case .editing, .sending:
        break
      }
    }
  }

  // MARK: - Slash command autocomplete

  /// The commands worth offering right now, most recently used first.
  ///
  /// `SlashCommandMatcher` in `DriverrCore` does the work, called fresh on every render; the
  /// matching is cheap.
  ///
  /// Nothing is offered while collapsed. The bar is already one row, and a list would cover
  /// the turn being answered. It uses the same condition as the composer
  /// (`TerminalScreen.isComposerCollapsed`), so the two agree about what fits.
  ///
  /// The query is the `/word` at the caret (`slashToken`), so it can follow prose. Built-ins
  /// are offered only for a word that opens the message, because Claude Code sends one
  /// mid-sentence as prose (`SlashCommandMatcher.withoutBuiltIns`).
  private var slashSuggestions: [SlashCommand] {
    guard !isCollapsed, model.text != dismissedSuggestionsQuery, let token = slashToken else {
      return []
    }
    // No transcript is needed: recents need one, but the catalogue does not, so a pane whose
    // conversation has not arrived still offers what the host has installed. Only agent panes
    // get a composer.
    let recents = transcript.map(SlashCommandMatcher.recentCommands(in:)) ?? []
    let offered = SlashCommandMatcher.offerings(recents: recents, catalog: catalog)
    let runnable =
      token.opensTheMessage ? offered : SlashCommandMatcher.withoutBuiltIns(offered, catalog: catalog)
    return SlashCommandMatcher.matches(runnable, typed: token.typed, limit: suggestionLimit)
  }

  /// The `/word` the caret is at the end of, or `nil`.
  private var slashToken: SlashToken? {
    SlashCommandMatcher.activeToken(in: model.text, caret: caretOffset)
  }

  /// The caret as a `Character` offset into `model.text`.
  ///
  /// The end of the text when the field has reported nothing, or when the selection is
  /// stale: a send clears the text and leaves the old selection past its end. A range
  /// selection uses its end, so selecting a typed `/co` keeps the list.
  private var caretOffset: Int {
    let text = model.text
    let index: String.Index?
    switch textSelection?.indices {
    case .selection(let range): index = range.upperBound
    case .multiSelection(let ranges): index = ranges.ranges.last?.upperBound
    case nil: index = nil
    @unknown default: index = nil
    }
    guard let index, index <= text.endIndex else { return text.count }
    return text.distance(from: text.startIndex, to: index)
  }

  /// Whether a suggestion row carries its description. Dropped at accessibility sizes, where
  /// the cap is two rows and a second line per row would cover the conversation.
  private var showsDescriptions: Bool {
    dynamicTypeSize < .accessibility1
  }

  /// How many rows to offer at the current text size. Chosen here because `DriverrCore`
  /// cannot read a SwiftUI environment; both numbers are its constants.
  private var suggestionLimit: Int {
    dynamicTypeSize >= .accessibility1
      ? SlashCommandMatcher.maximumSuggestionsAtAccessibilitySizes
      : SlashCommandMatcher.maximumSuggestions
  }

  /// The list itself: a floating card in the composer's shape, not a band.
  private var slashSuggestionsList: some View {
    VStack(alignment: .leading, spacing: 0) {
      suggestionsHeader
      ForEach(Array(slashSuggestions.enumerated()), id: \.element.id) { index, command in
        Button {
          choose(command)
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(command.name)
              .font(.callout.monospaced())
              // Shrink rather than truncate: a list that exists to spell a command must not show
              // part of one. The floor keeps it legible.
              .lineLimit(1)
              .minimumScaleFactor(0.5)

            if showsDescriptions, let description = command.description {
              // One line, truncated, not shrunk: a description only has to say roughly what the
              // command does, and more lines would take the panel over the conversation.
              Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          .padding(.horizontal, 12)
          // Padding and a floor: `minHeight` alone left no room between rows at large sizes.
          .padding(.vertical, 8)
          // 44 pt is the tap target minimum. A row without a description would otherwise be
          // about 34 pt beside 48 pt described rows.
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(
          SuggestionRowButtonStyle(
            isHighlighted: index == suggestionSelection.index, accent: themeAccent)
        )
        // The trait, not only the tint, so VoiceOver and Full Keyboard Access report the
        // highlight.
        .accessibilityAddTraits(index == suggestionSelection.index ? [.isSelected] : [])
        // The label stays the command and the description is the value. VoiceOver reads both,
        // and a test still reads a bare `/run-tests` from `label`.
        .accessibilityLabel(command.name)
        .accessibilityValue(command.description ?? "")
        // On the row, never the `VStack`, whose identifier would overwrite the row's.
        .accessibilityIdentifier("composer.suggestions.row.\(index)")
      }
    }
    .padding(.bottom, 4)
    // Clips the highlight to the card's shape. SwiftUI currently rounds a row background
    // enough to stay inside the 22 pt corner, and the two edges touch without crossing. That
    // rounding is undocumented, so the clip makes the containment this file's property.
    .clipShape(Self.cardShape)
    .background(.regularMaterial, in: Self.cardShape)
    .overlay {
      Self.cardShape
        .strokeBorder(Color(.opaqueSeparator), lineWidth: 1)
    }
  }

  /// The list's title row, with the dismiss control at its end.
  ///
  /// A row of its own, not an overlay on the first suggestion: the top row is the most likely
  /// tap, and a 44 pt dismiss target over it would catch those taps. The caption also says
  /// what the list is.
  private var suggestionsHeader: some View {
    HStack(spacing: 0) {
      Text(PaneComposerCopy.suggestionsLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.leading, 12)
        .accessibilityAddTraits(.isHeader)

      Spacer(minLength: 8)

      // Dismissable without choosing, by an explicit control: a bar with no chrome has no
      // obvious place for a tap outside.
      Button {
        dismissedSuggestionsQuery = model.text
      } label: {
        // Unfilled `xmark`: in dark the filled disc outweighed the suggestions. `.font(.body)`
        // so the glyph grows with the text. The frame is a minimum: 44 pt is a floor, not a
        // ceiling.
        Image(systemName: "xmark")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(PaneComposerCopy.dismissSuggestions)
      .accessibilityIdentifier("composer.suggestions.dismiss")
    }
  }

  /// A suggestion row's press state and keyboard highlight.
  ///
  /// `.plain` on a bare `Text` gives no press feedback, so a press draws `Color(.systemFill)`,
  /// as a held system row does. The keyboard highlight is the accent, because an arrow key
  /// leaves a row chosen until Return, like a standing selection. A row both highlighted and
  /// pressed shows the press, the more transient state.
  private struct SuggestionRowButtonStyle: ButtonStyle {
    var isHighlighted = false
    /// Passed in, because a `ButtonStyle` is not a view and has no environment.
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .background(background(isPressed: configuration.isPressed))
        .contentShape(Rectangle())
    }

    private func background(isPressed: Bool) -> Color {
      if isPressed { return Color(.systemFill) }
      return isHighlighted ? accent.opacity(0.18) : Color.clear
    }
  }

  /// Completes `command` into the field in place of the `/word` at the caret, never with a
  /// guessed argument. The rest of the text is kept, and the caret goes after the trailing
  /// space, where an argument would go.
  private func choose(_ command: SlashCommand) {
    guard let token = slashToken else { return }
    let completion = SlashCommandMatcher.complete(model.text, token: token, with: command)
    model.text = completion.text
    textSelection = TextSelection(
      insertionPoint: completion.text.index(
        completion.text.startIndex, offsetBy: completion.caret))
    suggestionSelection.reset()
  }

  /// A hardware keyboard drives the same choice a tap does: Up and Down move the highlight,
  /// Return commits it, Escape puts the list away.
  ///
  /// On the outer stack, not on `slashSuggestionsList`: `onKeyPress` follows the focused
  /// responder's ancestors, and the focused field is in `card`, a sibling of the list.
  ///
  /// Every handler returns `.ignored` unless the list is up, so typing is unchanged otherwise.
  /// Return is also ignored with no row highlighted, so `/pi` then Return reaches the field.
  /// The gate is inside each handler because `onKeyPress` has no `isEnabled:` overload.
  ///
  /// Up and Down are verified under XCUITest. Return and Escape are not: XCUITest delivers them
  /// to no handler at all, including Send's shipped ⌘↩. `PaneComposerUITests` records the probe.
  ///
  /// The list can be up over wrapped text, because the `/word` can follow prose. Up and Down
  /// still reach these handlers there, not the field's caret: measured under XCUITest by
  /// `testArrowKeysMoveTheHighlightWhenTheFieldHasWrapped`.
  private func withSlashKeyHandling(_ content: some View) -> some View {
    content
      .onKeyPress(.downArrow) {
        guard !slashSuggestions.isEmpty else { return .ignored }
        suggestionSelection.moveDown(count: slashSuggestions.count)
        return .handled
      }
      .onKeyPress(.upArrow) {
        guard !slashSuggestions.isEmpty else { return .ignored }
        suggestionSelection.moveUp(count: slashSuggestions.count)
        return .handled
      }
      .onKeyPress(.return) {
        guard !slashSuggestions.isEmpty,
          let command = suggestionSelection.highlighted(in: slashSuggestions)
        else { return .ignored }
        choose(command)
        return .handled
      }
      .onKeyPress(.escape) {
        guard !slashSuggestions.isEmpty else { return .ignored }
        dismissedSuggestionsQuery = model.text
        suggestionSelection.reset()
        return .handled
      }
  }

  // MARK: - The card

  /// The strip of page between the card's bottom edge and the bottom of this bar, which is
  /// also the bottom of the safe area. `static` because tests measure against it.
  ///
  /// 8 pt in both shapes. In landscape Send's 44 pt target extends below the drawn circle and
  /// nearly reached the keys at 4 pt. More inset buys less clearance than it adds, because
  /// the target overflows the card's bottom edge by more as the inset grows; measure, do not
  /// derive. It is the card's own padding, not a guess at the keyboard's geometry.
  static let cardBottomInset: CGFloat = 8

  /// One rounded card holding the field and, beneath it, the controls that act on it,
  /// floating on the conversation's background.
  private var card: some View {
    cardLayout {
      field
      controlRow
    }
    .padding(.horizontal, 8)
    // 3 pt collapsed: the field is beside Send, so the card is exactly the 44 pt target tall.
    .padding(.vertical, isCollapsed ? 3 : 8)
    // `.regularMaterial` with an `opaqueSeparator` border, both semantic. At rest the card's
    // backdrop is the page itself, so a thin material would vanish into it; the lift has to
    // come from the panel. The material still blurs turns that scroll behind the card.
    .background(.regularMaterial, in: Self.cardShape)
    .background { cardFrameProbe }
    .overlay {
      Self.cardShape
        .strokeBorder(Color(.opaqueSeparator), lineWidth: 1)
    }
    // The whole card is the field's target, so a tap beside a short draft does not miss.
    .contentShape(Self.cardShape)
    .onTapGesture { isTextFocused = true }
  }

  /// The card's frame, published to XCUITest.
  ///
  /// The card cannot carry an identifier without overwriting those inside it, and the field
  /// starts 14 pt below the card's top, so "above the composer" assertions need the card's
  /// own frame. A `Color.clear` leaf in a `background` has the card's frame and no identified
  /// descendants.
  ///
  /// Behind plain `-uiTesting`, not its own flag, because most of `PaneChatUITests` measures
  /// against it. It has no label and is not hit-testable, so VoiceOver skips it and the card
  /// keeps every tap. `PaneChatUITests.composerTop(in:)` fails if it goes missing.
  @ViewBuilder private var cardFrameProbe: some View {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
      Color.clear
        .accessibilityElement()
        .accessibilityIdentifier("composer.card")
        .allowsHitTesting(false)
    }
    #endif
  }

  /// The card's layout: the field above the controls, or beside Send when collapsed.
  ///
  /// `AnyLayout`, not `if isCollapsed { HStack } else { VStack }`. Two containers give the
  /// `TextField` two identities, so collapsing rebuilds the field, which resigns first
  /// responder, which drops the keyboard, which un-collapses the bar. It then looks normal,
  /// with no keyboard. `AnyLayout` changes the layout and keeps the children's identity.
  private var cardLayout: AnyLayout {
    isCollapsed
      ? AnyLayout(HStackLayout(alignment: .center, spacing: 6))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
  }

  /// One line when collapsed, up to five otherwise. Keep `axis: .vertical` either way and let
  /// `lineLimit` do it; swapping the initialiser would change the field's identity and drop
  /// the keyboard.
  private var field: some View {
    TextField(PaneComposerCopy.field, text: $model.text, selection: $textSelection, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(isCollapsed ? 1...1 : 1...5)
      // A terminal reply is not prose: an autocapitalised "Yes" or autocorrected flag is a
      // wrong answer.
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($isTextFocused)
      .padding(.horizontal, 6)
      .padding(.top, isCollapsed ? 0 : 6)
      .accessibilityIdentifier("composer.text")
  }

  private static let cardRadius: CGFloat = 22

  /// The one shape for background, stroke, tap target and the suggestion clip. One constant,
  /// because the clip only works while it matches the stroke exactly.
  private static let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)

  /// Under the field, inside the card: controls only. Status and Retry are `ChatActivity`, at
  /// the foot of the transcript.
  private var controlRow: some View {
    HStack(alignment: .center, spacing: 8) {
      if onAttach != nil { attachButton }
      // No spacer while collapsed, or it would strand Attach in the middle of the card. The
      // controls hug the trailing edge in both shapes.
      if !isCollapsed { Spacer(minLength: 0) }
      // Stop exists only while something is running.
      if header.isWorking && !isConfirmingInterrupt {
        stopButton
      }
      sendButton
    }
  }

  private var stopButton: some View {
    Button(role: .destructive) {
      isConfirmingInterrupt = true
    } label: {
      // The system's destructive style: the word and glyph are red on a neutral pill, like the
      // confirm buttons. A bare `Label`, because `BorderedButtonLabel` forces `Color.primary`
      // and would erase the role.
      //
      // The label frame sets Stop's drawn height to match the 40 pt Send circle beside it.
      // `.bordered` sizes its own chrome, so Stop's drawn size is its tap target, and without
      // the frame it was about 24 pt. `.controlSize(.small)` adds about 10 pt, so 30 lands on
      // 40, verified from a capture.
      Label("Stop", systemImage: "stop.fill")
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .frame(minHeight: 30)
    }
    .buttonStyle(.bordered)
    // See `interruptConfirm`: under the root accent tint, `.bordered` colours from the tint
    // and the role never reaches the label. Do not remove.
    .tint(Color?.none)
    .controlSize(.small)
    .disabled(model.isSending)
    .accessibilityIdentifier("composer.stop")
  }


  // MARK: - Upload readout for UI tests

  /// Where the paced fake upload stopped, for a test that cannot see inside it. See
  /// `UploadProbe`.
  ///
  /// On the bar, not the row, because after Remove there is no row. Only under
  /// `-uiTestingPickedImage`, so other UI classes do not carry the element.
  @ViewBuilder
  private var uploadProbeReadout: some View {
    #if DEBUG
    if Self.isReportingUpload {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityIdentifier("debug.upload")
        .accessibilityLabel(UploadProbe.shared.note)
    }
    #endif
  }

  #if DEBUG
  /// Whether this launch carries the seeded pick, the only launch that can cancel a fake
  /// upload. Decided once, like `TerminalScreen.isReportingKeyboardMetrics`, because a branch
  /// that flips at run time changes view identity.
  static let isReportingUpload =
    ProcessInfo.processInfo.arguments.contains("-uiTestingPickedImage")
  #endif

  // MARK: - The pending image

  /// The way into Photos, at the leading edge.
  ///
  /// Away from Send, so the two controls that send stay together. The target stays 44 pt and
  /// only the glyph shrinks when collapsed, which a button style cannot do, so this is
  /// `.plain`.
  private var attachButton: some View {
    Button {
      onAttach?()
    } label: {
      Image(systemName: "photo.on.rectangle")
        .font(.system(size: isCollapsed ? 15 : 17, weight: .medium))
        .foregroundStyle(themeAccent)
        .frame(width: isCollapsed ? 32 : 40, height: isCollapsed ? 32 : 40)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The glyph has no words, so the label is all VoiceOver has.
    .accessibilityLabel(PaneAttachmentCopy.attachButton)
    .accessibilityIdentifier("composer.attach")
  }

  /// The staged image: what it is, how far it has got, and a way to remove it.
  ///
  /// One line, because the collapsed landscape region has no room for two. No identifier on
  /// the stack; each child carries its own.
  private var attachmentRow: some View {
    HStack(spacing: 10) {
      attachmentThumbnail
      attachmentStatus
      Spacer(minLength: 8)
      Button {
        model.attachment.remove()
      } label: {
        // 44 x 32 while collapsed, accepted: a 44 pt height does not fit in a 36 pt row. The
        // full 44 is kept horizontally. The ordinary shape is 44 x 44.
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: isCollapsed ? 16 : 18))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: 44, height: isCollapsed ? 32 : 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(PaneAttachmentCopy.removeButton)
      .accessibilityIdentifier("composer.attachment.remove")
    }
    .padding(.leading, 10)
    // A fixed height while collapsed, not a minimum. `minHeight` bounds what the view asks
    // for, not what it gets, and the row was squeezed and clipped. A rigid row makes something
    // else give. Two frames because `frame` has no overload taking both `maxWidth` and
    // `height`, and the height must resolve first.
    .frame(height: isCollapsed ? 36 : nil)
    .frame(maxWidth: .infinity, minHeight: isCollapsed ? nil : 48, alignment: .leading)
    // The same material, shape and border as the `/` list, so both read as one family.
    .clipShape(Self.cardShape)
    .background(.regularMaterial, in: Self.cardShape)
    .overlay {
      Self.cardShape
        .strokeBorder(Color(.opaqueSeparator), lineWidth: 1)
    }
  }

  /// A picture of the prepared PNG, so it shows exactly what will be sent. A glyph stands in
  /// during the downscale.
  @ViewBuilder
  private var attachmentThumbnail: some View {
    let side: CGFloat = isCollapsed ? 24 : 32
    Group {
      if let image = model.attachment.thumbnail {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.system(size: isCollapsed ? 12 : 14))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(.tertiarySystemFill))
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    // Labelled, because the sentence beside it says everything about the image.
    .accessibilityLabel(PaneAttachmentCopy.imageLabel)
    .accessibilityIdentifier("composer.attachment.row")
  }

  /// What the row says: preparing, a size, bytes sent, done, or the failure.
  ///
  /// A failure renders inline, never as a sheet. It has its own identifier, so a test reading
  /// the progress identifier cannot pass on a row that shows a failure instead.
  @ViewBuilder
  private var attachmentStatus: some View {
    switch model.attachment.phase {
    case .failed(let sentence):
      Text(sentence)
        .font(.caption)
        .foregroundStyle(Color(.systemRed))
        // Two lines normally, one when collapsed.
        .lineLimit(isCollapsed ? 1 : 2)
        .accessibilityIdentifier("composer.attachment.failure")
    case .some(let phase):
      Text(Self.statusText(phase, byteCount: model.attachment.byteCount))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityIdentifier("composer.attachment.progress")
    case .none:
      EmptyView()
    }
  }

  /// The row's sentence for every phase but the failure. The strings are
  /// `DriverrCore.PaneAttachmentCopy`'s.
  private static func statusText(_ phase: PaneAttachmentPhase, byteCount: Int) -> String {
    switch phase {
    case .preparing:
      return PaneAttachmentCopy.preparing
    case .ready:
      return PaneAttachmentCopy.size(byteCount)
    case .uploading(let progress):
      return PaneAttachmentCopy.progress(progress)
    case .uploaded:
      return PaneAttachmentCopy.uploaded
    case .handedOver:
      return PaneAttachmentCopy.handedOver
    case .failed(let sentence):
      return sentence
    }
  }

  // MARK: - The reply

  /// Send, on the card's control row beside the field.
  private var sendButton: some View {
    Button {
      Task { await model.send() }
    } label: {
      // A `Label` so the button has a title for the system's shortcut list beside ⌘↩.
      // `.iconOnly` below draws only the icon.
      Label {
        Text(PaneComposerCopy.send)
      } icon: {
        sendIcon
      }
      .labelStyle(.iconOnly)
    }
    .buttonStyle(.plain)
    .disabled(!model.canSend)
    // ⌘↩ for chat-app muscle memory.
    .keyboardShortcut(KeyCommand.send.shortcut)
    .accessibilityLabel(PaneComposerCopy.send)
    .accessibilityIdentifier("composer.send")
  }

  /// The send button's drawn face.
  private var sendIcon: some View {
    // The circle is drawn here, not by a button style. A style sizes its chrome around the
    // label, so a 44 pt label became a 58 pt circle. Drawing it separates the two numbers:
    // a 40 pt circle in a 44 pt target. The frame belongs on the label, not the button.
    // Collapsed, only the circle shrinks, to 32; the 44 pt target stays.
    Image(systemName: "arrow.up")
      .font(.system(size: isCollapsed ? 15 : 17, weight: .semibold))
      .foregroundStyle(model.canSend ? themeAccentForeground : Color.secondary)
      .frame(width: isCollapsed ? 32 : 40, height: isCollapsed ? 32 : 40)
      .background(
        model.canSend ? themeAccent : Color(.tertiarySystemFill),
        in: Circle()
      )
      .frame(width: 44, height: 44)
      .contentShape(Circle())
  }

  // MARK: - Stop, in two steps

  /// The interrupt confirmation. Danger is carried by the sentence and the destructive role,
  /// not only by the system's red.
  private var interruptConfirm: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(PaneComposerCopy.interruptPrompt)
        .font(.footnote)
      // An alert's action row: both labels take `maxWidth: .infinity` and split the row.
      HStack(spacing: 12) {
        Button {
          isConfirmingInterrupt = false
        } label: {
          // Width only, never `minHeight`: a 44 pt floor inside `.bordered` gets padded again
          // into a 58 pt button. `.controlSize(.large)` sets the height.
          BorderedButtonLabel {
            Text(PaneComposerCopy.cancel).fontWeight(.semibold).frame(maxWidth: .infinity)
          }
        }
        .accessibilityIdentifier("composer.stop.cancel")
        Button(role: .destructive) {
          isConfirmingInterrupt = false
          Task { await model.send(.interrupt) }
        } label: {
          // Bare `Text`, not `BorderedButtonLabel`, which would force `Color.primary` and
          // erase the destructive red.
          Text(PaneComposerCopy.interruptConfirm).fontWeight(.semibold).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("composer.stop.confirm")
      }
      // Contrast: the destructive label is 5.22:1 in dark but 3.42:1 in light, under the 4.5:1
      // text floor. Accepted: the red is the system's destructive colour on the system's
      // `.bordered` fill, and the rule is that where contrast fails the foreground changes,
      // and here the red is the foreground. The semibold weight does not qualify it as large
      // text. It matches Cancel, and `.fontWeight` leaves Dynamic Type alone.
      //
      // `.tint(Color?.none)` lets `role: .destructive` draw. Under the root accent tint,
      // `.bordered` colours from the tint, and the confirm looked the same as Cancel.
      //
      // Other styles fail: `.glass` and `.glassProminent` ignore the role, and `.borderless`
      // drops the pill, putting the red on the bar's material under the text floor.
      .buttonStyle(.bordered)
      .controlSize(.large)
      .buttonBorderShape(.capsule)
      .tint(Color?.none)
      // Capped on iPad, where the row would be about 624 pt wide. Two frames: the first caps
      // the width, the second puts the capped row at the trailing edge.
      .frame(maxWidth: 420)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    // Its own surface, in the card's material and shape. The chat draws behind the composer,
    // so without a background a reader scrolled back saw transcript text through this bar.
    // The padding is what makes it a panel. The bar is a `safeAreaBar`, so its extra height
    // moves the chat's bottom inset in the same layout pass.
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: Self.cardShape)
    .overlay {
      Self.cardShape
        .strokeBorder(Color(.opaqueSeparator), lineWidth: 1)
    }
  }
}

#if DEBUG

  /// The bar's four states stacked, to see that a failure is no taller than a success.
  #Preview("Composer bar") {
    VStack(spacing: 24) {
      ForEach(PaneComposerBarPreview.Kind.allCases, id: \.self) { kind in
        PaneComposerBarPreview(kind: kind)
      }
    }
    .padding(.vertical)
    .background(Color(.systemBackground))
  }

  /// A pane that is not blocked: the composer stays, and only the sentence above it changes.
  #Preview("Composer bar — the agent has not asked anything") {
    PaneComposerBarPreview(kind: .working)
  }

  /// A large text size: the field wraps upward, and the controls stay 44 pt.
  #Preview("Composer bar — accessibility text size") {
    PaneComposerBarPreview(kind: .failed)
      .environment(\.dynamicTypeSize, .accessibility3)
  }

  private struct PaneComposerBarPreview: View {
    enum Kind: CaseIterable {
      case editing
      case sending
      case sent
      case failed
      case working
    }

    let kind: Kind

    var body: some View {
      PaneComposerBar(
        model: PreviewSupport.composer(for: pane, in: state),
        header: PaneComposerHeader(pane: pane)
      )
    }

    /// The blocked pane, except in the preview about a pane that has not asked anything.
    private var pane: DriverrCore.Pane {
      guard kind == .working else { return PreviewSupport.agentPane }
      return DriverrCore.Pane(
        id: "w1:p2",
        tabID: "w1:t1",
        workspaceID: "w1",
        title: "needs a decision",
        agent: Agent(name: "Claude", kind: "claude", status: .working)
      )
    }

    /// Driven through the real transitions, so no preview shows an impossible state.
    private var state: PaneComposerState {
      var state = PaneComposerState()
      switch kind {
      case .editing, .working:
        state.text = "yes, go ahead"
      case .sending:
        state.text = "yes, go ahead"
        _ = state.beginSending()
      case .sent:
        state.text = "y"
        _ = state.beginSending()
        state.succeeded()
      case .failed:
        state.text = "yes, go ahead"
        _ = state.beginSending()
        state.failed(.herdrCommandFailed(reason: "no such pane"))
      }
      return state
    }
  }

#endif

/// Reports the composer bar's frame, and attaches nothing when nobody asked.
///
/// `onGeometryChange` has a cost on every layout pass, so a shipping build, where
/// `PaneComposerBar.onLayoutProbe` is `nil`, gets its content back untouched.
private struct ComposerLayoutProbe: ViewModifier {
  var report: ((CGRect) -> Void)?

  func body(content: Content) -> some View {
    if let report {
      content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
    } else {
      content
    }
  }
}

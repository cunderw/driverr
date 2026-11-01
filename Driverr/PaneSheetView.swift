import DriverrCore
import DriverrHerdr
import DriverrTerm
import SwiftUI

/// The pane switcher: every pane on the host as a tile, with a picture of what it is doing.
/// It is the only place a session is listed and the current pane is named.
///
/// Workspaces are sections with a header, shown only when there is more than one
/// (`PaneStripModel.showsWorkspaceHeaders`, tested in `swift test`).
///
/// **The order is `PaneStripModel.chips`, not this view's**, minus the two entries that are
/// not places. A second ordering here would drift from the model.
///
/// Identifiers are on the tiles, never on the grid. Every pane tile shares
/// `terminal.sheet.pane`, and a test names one by its label.
struct PaneSheetView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.themeAccent) private var themeAccent

  let hostName: String
  let model: PaneStripModel
  let settings: TerminalSettings
  let thumbnails: PaneThumbnailModel
  let onSelect: (TerminalTarget) -> Void
  /// Splits the current pane. `nil` when the scene is on its plain shell, which is not a
  /// herdr pane.
  var onNewPane: (() -> Void)?
  /// Closes the sheet without going anywhere.
  var onDone: () -> Void = {}
  /// Every other connected host's panes. Empty with one host, and the sheet is then
  /// single-host. `CrossHostPanes` owns the order and which hosts appear.
  var otherHosts = CrossHostPanes(currentHostID: nil, hosts: [])
  /// Goes to a pane on one of `otherHosts`. `TerminalPresenter.present(hostID:paneID:)`
  /// resolves the two ids.
  var onSelectOnAnotherHost: (DriverrCore.Host.ID, String) -> Void = { _, _ in }
  /// Which shape of sheet this is. See `body`.
  ///
  /// **Passed in, not read from the environment here.** Inside the sheet,
  /// `horizontalSizeClass` describes the sheet, and an iPad form sheet reports compact.
  /// `TerminalScreen` is full screen, so its size class describes the device.
  var isRegularWidth: Bool = false
  /// The stop a pane's transcript ends on, for the tile's badge. The host is `nil` for this
  /// sheet's own host. Read only from transcripts already loaded, so the sheet starts no
  /// read on any host.
  var agentStop: (DriverrCore.Host.ID?, Pane) -> AgentStop? = { _, _ in nil }

  /// Page-sized on regular width, detents on compact.
  ///
  /// At the medium detent an iPad form sheet is narrow enough for `columns(for:)` to give
  /// two columns, with the last row clipped. On a phone the detents are right, because a
  /// full-height sheet would hide the terminal. The two are branched because neither
  /// modifier has a "none" value.
  @ViewBuilder
  var body: some View {
    if isRegularWidth {
      sheet.presentationSizing(.page)
    } else {
      sheet
        .presentationDetents([.medium, .large])
        // Only with the detents. On the page-sized sheet a grabber would promise a resize
        // that does not happen.
        .presentationDragIndicator(.visible)
    }
  }

  private var sheet: some View {
    NavigationStack {
      GeometryReader { geometry in
        let across = columns(for: geometry.size.width)
        ScrollView {
          // **Rows of `HStack`s, not a `LazyVGrid`.** A lazy grid does not build tiles below
          // the medium detent, so the last row and New pane would not exist for a test until
          // a scroll. The grid is small enough not to need laziness.
          VStack(alignment: .leading, spacing: 24) {
            readFailureNotice
            // Draws nothing with one host, where the title names it.
            hostHeader(hostName, isCurrent: true)
            // Sections only when there are headers to name them. An unnamed gap would read
            // as a boundary with no label, so without headers every place is one flat grid.
            if model.showsWorkspaceHeaders {
              ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                  header(of: group)
                  grid(of: group.chips.compactMap(place(for:)).map(Cell.place), across: across)
                }
              }
            } else {
              grid(of: places.map(Cell.place), across: across)
            }
            // Outside every section, because it splits the current pane and belongs to no
            // workspace. Padded so it does not read as a tile wrapped into the last section.
            grid(of: [.newPane], across: across)
              .padding(.top, 8)
            // Other hosts last, because the likeliest pick is another pane on this host.
            ForEach(otherHosts.sections) { section in
              VStack(alignment: .leading, spacing: 8) {
                hostHeader(section.name)
                grid(
                  of: section.panes.map { Cell.otherPane(hostID: section.id, pane: $0) },
                  across: across
                )
              }
            }
          }
          .padding(16)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDone)
            // Toolbar text takes `Color.primary`. See CLAUDE.md, Style.
            .tint(Color.primary)
            .accessibilityIdentifier("terminal.sheet.done")
        }
      }
    }
  }

  /// "Panes on workbox" with one host, since pane titles look alike across machines. With
  /// other hosts listed, each grid gets a `hostHeader` instead.
  private var title: String {
    otherHosts.isEmpty ? "Panes on \(hostName)" : "Panes"
  }

  /// Which machine the grid below is on. Nothing while there is only one.
  ///
  /// It uses the Settings section-header style (small, secondary, uppercased, tracked), so it
  /// differs from a workspace header in size, weight, colour and case. A single weight step
  /// read as one flat list.
  ///
  /// The extra 24 pt above it is per header, so workspace groups keep their spacing. A
  /// smaller gap is not enough, because the footnote's short ascent hides most of it.
  ///
  /// The identifier is on the name `Text`, not the `HStack`. The label is set explicitly
  /// because `.textCase(.uppercase)` also changes the accessibility label.
  @ViewBuilder
  private func hostHeader(_ name: String, isCurrent: Bool = false) -> some View {
    if !otherHosts.isEmpty {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(name)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .tracking(0.5)
          .lineLimit(1)
          .accessibilityIdentifier("terminal.sheet.host")
          .accessibilityLabel(isCurrent ? "\(name), current host" : name)
          .accessibilityAddTraits(.isHeader)
        // Being listed first stops saying "current" once the section scrolls away. Mixed
        // case and regular weight, so it reads as a tag. Hidden from accessibility because
        // the name's label already says "current host".
        if isCurrent {
          Text("Current")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
        Spacer(minLength: 0)
      }
      // 24 from the stack plus 24 here. See the doc comment above.
      .padding(.top, 24)
    }
  }

  /// Why the tiles have stopped updating, after a run of read failures.
  /// `PaneThumbnailModel.readFailure` decides when. Inline, not an alert, because this sheet
  /// is already a presentation.
  @ViewBuilder
  private var readFailureNotice: some View {
    if let failure = thumbnails.readFailure {
      Label(failure, systemImage: "exclamationmark.triangle")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("terminal.sheet.readFailure")
    }
  }

  // MARK: - Layout

  /// Two to four across, from the width rather than the size class, which cannot tell a
  /// landscape phone from a portrait one. A tile is legible at 170 pt because its text is
  /// pinned at 8 pt, and 170 gives a page-sized iPad sheet three or four columns.
  private func columns(for width: CGFloat) -> Int {
    min(4, max(2, Int(max(width - 32, 1) / 170)))
  }

  /// One cell of the grid: somewhere to go, or the one cell that makes a new somewhere.
  private enum Cell: Identifiable {
    case place(Place)
    case newPane
    /// A pane on another connected host.
    case otherPane(hostID: DriverrCore.Host.ID, pane: Pane)

    var id: String {
      switch self {
      case .place(let place): place.id
      case .newPane: "newPane"
      // Namespaced by host. herdr pane ids are per host (`w1:p1` exists everywhere), and a
      // duplicate id in a `ForEach` is undefined.
      case .otherPane(let hostID, let pane): "\(hostID.uuidString).\(pane.id)"
      }
    }
  }

  /// A section's cells, laid out `across` to a row.
  private func grid(of cells: [Cell], across: Int) -> some View {
    VStack(spacing: 12) {
      ForEach(Array(rows(cells, across: across).enumerated()), id: \.offset) { _, row in
        HStack(alignment: .top, spacing: 12) {
          ForEach(row) { cell in
            switch cell {
            case .place(let place): tile(place)
            case .newPane: newPaneCell
            case .otherPane(let hostID, let pane): otherTile(hostID: hostID, pane: pane)
            }
          }
          // Fillers keep a short last row's tiles the same width as the others. Not a
          // `Spacer`: the tiles also ask for `maxWidth: .infinity` and the `HStack` serves
          // them first, so they stretch. `maxHeight: 0` keeps the filler out of the height.
          if row.count < across {
            ForEach(0..<(across - row.count), id: \.self) { _ in
              Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
          }
        }
      }
    }
  }

  private func rows(_ cells: [Cell], across: Int) -> [[Cell]] {
    stride(from: 0, to: cells.count, by: across).map { start in
      Array(cells[start..<min(start + across, cells.count)])
    }
  }

  /// Which workspace the tiles below belong to. Absent for the shell group, and when
  /// `PaneStripModel.showsWorkspaceHeaders` is false. The identifier is on the `Text`, not
  /// the section, and a test names a header by its label.
  @ViewBuilder
  private func header(of group: PaneGroup) -> some View {
    if model.showsWorkspaceHeaders, let title = group.title {
      Text(title)
        .font(.subheadline.weight(.semibold))
        // `.primary`, not `.secondary`: a header lighter than the tile titles under it
        // inverts the hierarchy.
        .foregroundStyle(.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("terminal.sheet.workspace")
        .accessibilityAddTraits(.isHeader)
    }
  }

  // MARK: - Tiles

  /// One place the sheet can send you, in `PaneStripModel`'s order.
  private struct Place: Identifiable {
    let id: String
    let target: TerminalTarget
    let title: String
    let pane: Pane?
    let isCurrent: Bool
  }

  /// The model's entries, minus the two that are not places.
  private var places: [Place] {
    model.chips.compactMap(place(for:))
  }

  /// One entry as somewhere to go, or `nil` for Needs you (a jump within this list) and the
  /// grid entry (which opened this sheet).
  private func place(for chip: PaneStripChip) -> Place? {
    switch chip {
    case .needsYou, .grid:
      return nil
    case .shell(let isCurrent):
      return Place(id: "shell", target: .shell, title: "Shell", pane: nil, isCurrent: isCurrent)
    case .pane(let pane, let isCurrent):
      return Place(
        id: "pane.\(pane.id)",
        target: .pane(id: pane.id),
        title: pane.title,
        pane: pane,
        isCurrent: isCurrent
      )
    }
  }

  /// A tile, with the pane's stop in its badge's place when it has one.
  private func tile(_ place: Place) -> some View {
    stopTimeline(place.pane.flatMap { agentStop(nil, $0) }, pane: place.pane) { stop in
      tile(place, stop: stop)
    }
  }

  @ViewBuilder
  private func tile(_ place: Place, stop: PaneStopBadge?) -> some View {
    let button = Button {
      onSelect(place.target)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          // The header scales with Dynamic Type. The thumbnail below is a picture and does
          // not.
          if let pane = place.pane {
            PaneBadge(pane: pane, stop: stop)
          } else {
            Image(systemName: "terminal").foregroundStyle(.secondary)
          }
          Text(place.title)
            .font(.subheadline)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        thumbnail(of: place.target)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        // A ring on the current pane, drawn on every tile and coloured on one, so no tile
        // changes size.
        //
        // **Two tones.** The accent against `.fill.tertiary` falls under the 3:1 a non-text
        // mark needs on half the theme and appearance pairs. The inner 1 pt `Color.primary`
        // clears it on every theme, and the accent keeps the outer stroke undimmed. Radius
        // 10 inside 12 with a 2 pt inset keeps them concentric.
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(place.isCurrent ? themeAccent : Color.clear, lineWidth: 2)
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(place.isCurrent ? Color.primary : Color.clear, lineWidth: 1)
            .padding(2)
        }
      }
    }
    .buttonStyle(.plain)
    // A `.plain` button gets no pointer highlight of its own.
    .hoverEffect(.highlight)
    .accessibilityIdentifier("terminal.sheet.pane")
    // The state in words, since colour alone cannot carry it. "<title>, <state>", so a test
    // can pick one tile by its prefix.
    .accessibilityLabel(
      place.pane.map { "\($0.title), \(Self.state(of: $0, stop: stop))" } ?? place.title
    )
    // The ring is invisible to VoiceOver and to tests, so the current tile says so.
    .accessibilityValue(place.isCurrent ? "Current pane" : "")

    // Removed explicitly: `PaneBadge` draws `checkmark.circle` for a finished agent, and that
    // symbol carries an implicit `Selected` trait.
    if place.isCurrent {
      button.accessibilityAddTraits(.isSelected)
    } else {
      button.accessibilityRemoveTraits(.isSelected)
    }
  }

  /// A pane on another connected host, with no thumbnail.
  ///
  /// Thumbnails would add a `pane read` per tick on every listed host. And
  /// `PaneThumbnailModel.cold` is keyed by bare pane id, which is per host, so asking it for
  /// another host's `w1:p1` would return this host's picture. The tile states the pane's
  /// status in words instead.
  private func otherTile(hostID: DriverrCore.Host.ID, pane: Pane) -> some View {
    stopTimeline(agentStop(hostID, pane), pane: pane) { stop in
      otherTile(hostID: hostID, pane: pane, stop: stop)
    }
  }

  private func otherTile(
    hostID: DriverrCore.Host.ID, pane: Pane, stop: PaneStopBadge?
  ) -> some View {
    Button {
      onSelectOnAnotherHost(hostID, pane.id)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          PaneBadge(pane: pane, stop: stop)
          Text(pane.title)
            .font(.subheadline)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        // The status in words, since colour alone cannot carry it and there is no picture.
        Text(stop?.label ?? pane.agent?.status.displayName ?? "Shell")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Floored so a row is even. Deliberately shorter than a thumbnail tile, because it
      // leads somewhere else.
      .frame(minHeight: 64, alignment: .topLeading)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .hoverEffect(.highlight)
    // Its own identifier, so a test naming one names the cross-host route.
    .accessibilityIdentifier("terminal.sheet.otherPane")
    .accessibilityLabel("\(pane.title), \(Self.state(of: pane, stop: stop))")
    // Never the current pane. Removed for the reason in `tile(_:stop:)`.
    .accessibilityRemoveTraits(.isSelected)
  }

  /// What a tile says a pane is doing: its stop's label, or herdr's status as the badge
  /// speaks it.
  private static func state(of pane: Pane, stop: PaneStopBadge?) -> String {
    stop?.label ?? pane.agent?.status.accessibleName ?? "Shell"
  }

  /// Hands `content` the pane's stop badge, redrawn a second past a limit's reset so it goes
  /// stale without a re-read. The clock is read in the body, not off the context's date, for
  /// the reason in `AgentStopRow.body`.
  private func stopTimeline<Content: View>(
    _ stop: AgentStop?, pane: Pane?, @ViewBuilder content: @escaping (PaneStopBadge?) -> Content
  ) -> some View {
    let reset = stop?.resetsAt.map { [$0.addingTimeInterval(1)] } ?? []
    return TimelineView(.explicit(reset)) { _ in
      content(PaneStopBadge(status: pane?.agent?.status, stop: stop, asOf: Date()))
    }
  }

  /// The last six lines of a pane, in the terminal's colours.
  ///
  /// A picture, not text to read, so it is pinned at 8 pt and `.dynamicTypeSize(.large)`.
  /// The header above carries the words. Always six rows, so the grid stays even.
  private func thumbnail(of target: TerminalTarget) -> some View {
    let lines = thumbnails.lines(for: target)
    // Redacted until the first batch answers, because an empty tile looks like an empty
    // pane. The filler rows give the redaction a shape.
    let isPending = lines.isEmpty && !thumbnails.hasRead
    let shown = isPending ? Self.pendingLines : lines
    let palette = settings.theme.palette(for: colorScheme == .dark ? .dark : .light)
    return VStack(alignment: .leading, spacing: 1) {
      ForEach(0..<PaneThumbnailModel.lineCount, id: \.self) { row in
        Text(row < shown.count ? shown[row] : " ")
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(thumbnailFont)
    .dynamicTypeSize(.large)
    .foregroundStyle(palette.foreground.swiftUIColor)
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 6))
    .redacted(reason: isPending ? .placeholder : [])
  }

  /// Filler rows of varied length for the redaction to draw as bars.
  private static let pendingLines = [
    String(repeating: "M", count: 26),
    String(repeating: "M", count: 18),
    String(repeating: "M", count: 22),
    String(repeating: "M", count: 12),
    String(repeating: "M", count: 20),
    String(repeating: "M", count: 8),
  ]

  /// The user's terminal face at a fixed 8 pt. The face follows the setting so the tile looks
  /// like their terminal. The size does not, or six lines would fill the screen.
  private var thumbnailFont: Font {
    guard let name = settings.font.systemFontName else {
      return .system(size: Self.thumbnailFontSize, design: .monospaced)
    }
    return .custom(name, fixedSize: Self.thumbnailFontSize)
  }

  private static let thumbnailFontSize: CGFloat = 8

  /// Splits the current pane, or on a core starts a terminal beside it. Disabled on the plain
  /// shell, because both need a herdr pane and Driverr's own pty is not one.
  private var newPaneCell: some View {
    Button {
      onNewPane?()
    } label: {
      VStack(spacing: 6) {
        Image(systemName: "plus.rectangle.on.rectangle")
          .font(.title2)
        // Names the pane it splits, so the effect is predictable.
        Text(newPaneTitle)
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .lineLimit(2)
        // When disabled, says why.
        if onNewPane == nil {
          Text("A shell isn't a pane herdr can split.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("terminal.sheet.newPane.reason")
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity)
      .frame(minHeight: 92)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .hoverEffect(.highlight)
    .disabled(onNewPane == nil)
    .accessibilityIdentifier("terminal.sheet.newPane")
    .accessibilityLabel(newPaneTitle)
    .accessibilityHint(onNewPane == nil ? "A shell isn't a pane herdr can split." : "")
  }

  /// `Split "index rebuild"`, or the bare verb when the scene is on its plain shell and
  /// there is no pane to name.
  ///
  /// On a core, `New terminal`, with no name: it opens its own terminal and divides nothing.
  private var newPaneTitle: String {
    guard let current = places.first(where: \.isCurrent), let pane = current.pane else {
      return "Split pane"
    }
    if CorePaneID.isCore(pane.id) { return "New terminal" }
    return "Split \u{201C}\(current.title)\u{201D}"
  }
}

#if DEBUG

  /// The seeded session, from the pane the UI suite attaches to. Thumbnails come from the
  /// fake's own fixture, so this preview shows what the tiles really draw.
  #Preview("Pane sheet") {
    PaneSheetPreview(current: .pane(id: "w1:p2"), openedAsShell: false)
  }

  /// Opened as a shell, with the shell current, so New pane is disabled.
  #Preview("Pane sheet — shell scene") {
    PaneSheetPreview(current: .shell, openedAsShell: true)
  }

  /// Two hosts connected. The other host's tiles have no thumbnail; see `otherTile`.
  #Preview("Pane sheet — two hosts") {
    PaneSheetPreview(
      current: .pane(id: "w1:p2"),
      openedAsShell: false,
      otherHosts: CrossHostPanes(
        currentHostID: PreviewSupport.host.id,
        hosts: [
          PaneSwitcherHost(
            id: DriverrCore.Host.uiTestSecondSeed.id,
            name: "beta",
            isConnected: true,
            tree: PreviewSupport.crowdedSession
          )
        ]
      )
    )
  }

  /// A crowded session.
  #Preview("Pane sheet — crowded session") {
    PaneSheetPreview(
      tree: PreviewSupport.crowdedSession,
      current: .pane(id: "c1:p2"),
      openedAsShell: false
    )
  }

  /// A sheet wired to the fake control, so the tiles have real fixture content in them.
  private struct PaneSheetPreview: View {
    var tree: SessionTree = PreviewSupport.seededSession
    let current: TerminalTarget
    let openedAsShell: Bool
    var otherHosts = CrossHostPanes(currentHostID: nil, hosts: [])

    var body: some View {
      let strip = PaneStripModel(tree: tree, current: current, openedAsShell: openedAsShell)
      let thumbnails = PreviewSupport.thumbnails(
        tree,
        showing: (openedAsShell ? [TerminalTarget.shell] : [])
          + tree.allPanes.map { .pane(id: $0.id) }
      )
      PaneSheetView(
        hostName: "workbox",
        model: strip,
        settings: .default,
        thumbnails: thumbnails,
        onSelect: { _ in },
        onNewPane: current == .shell ? nil : {},
        otherHosts: otherHosts
      )
      .task { thumbnails.open() }
    }
  }

#endif

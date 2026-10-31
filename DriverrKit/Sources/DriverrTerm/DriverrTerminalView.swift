#if canImport(UIKit) && !os(watchOS)
  import DriverrCore
  import SwiftTerm
  import SwiftUI
  import UIKit
  import os

  /// A terminal, rendered from a `TerminalSession` and a `TerminalSettings`.
  ///
  /// No singleton, no shared emulator and no knowledge of SSH, so several can be alive at
  /// once. Appearance arrives as one value, so a settings change is applied in one
  /// `updateUIView`.
  public struct DriverrTerminalView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    private let session: TerminalSession
    private let settings: TerminalSettings
    private let focusRequest: Int
    private let wantsKeyboardFocus: Bool
    private let keyboardNotice: KeyboardNoticeModel
    private let copyNotice: TerminalCopyNotice
    private let showsAccessoryRow: Bool
    private let accessibilityIdentifier: String

    /// - Parameters:
    ///   - focusRequest: bump this to make the terminal take the keyboard back, for example
    ///     after a sheet closes. A counter, because a `Bool` already `true` cannot ask twice.
    ///   - wantsKeyboardFocus: whether this terminal may take the keyboard. `false` for a
    ///     warm pane that is alive but not on screen. See
    ///     `DriverrTerminalUIView.wantsKeyboardFocus`.
    ///   - keyboardNotice: receives first-responder and keyboard-frame changes. One instance
    ///     can be shared across a scene's warm entries, because only the current one becomes
    ///     first responder.
    ///   - copyNotice: told when the edit menu's Copy put text on the pasteboard. Shared like
    ///     `keyboardNotice`.
    ///   - showsAccessoryRow: whether to carry the key row above the keyboard. See
    ///     `KeyboardNoticeModel.showsAccessoryRow`. Passed in, not read here, so the caller's
    ///     body depends on it and plugging in a keyboard redraws this view.
    public init(
      session: TerminalSession,
      settings: TerminalSettings = .default,
      focusRequest: Int = 0,
      wantsKeyboardFocus: Bool = true,
      keyboardNotice: KeyboardNoticeModel = KeyboardNoticeModel(),
      copyNotice: TerminalCopyNotice = TerminalCopyNotice(),
      showsAccessoryRow: Bool = true,
      accessibilityIdentifier: String = "terminal.view"
    ) {
      self.session = session
      self.settings = settings
      self.focusRequest = focusRequest
      self.wantsKeyboardFocus = wantsKeyboardFocus
      self.keyboardNotice = keyboardNotice
      self.copyNotice = copyNotice
      self.showsAccessoryRow = showsAccessoryRow
      self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// The bundled face at the chosen size, or the system monospaced font if it fails to
    /// load. A proportional fallback would break the grid.
    private var uiFont: UIFont {
      let size = CGFloat(settings.fontSize)
      if let name = settings.font.systemFontName, let font = UIFont(name: name, size: size) {
        return font
      }
      return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// A steady caret, not a setting. See the steady-caret rule in `CLAUDE.md`.
    private static let terminalOptions = TerminalOptions(cursorStyle: .steadyBlock)

    public func makeCoordinator() -> Coordinator {
      Coordinator(session: session)
    }

    public func makeUIView(context: Context) -> DriverrTerminalUIView {
      let view = DriverrTerminalUIView(
        frame: .zero,
        font: uiFont,
        options: Self.terminalOptions
      )
      view.terminalDelegate = context.coordinator
      // Before the view enters a window, because `didMoveToWindow` reads it. A warm pane
      // must not take the keyboard from the pane being typed into.
      view.wantsKeyboardFocus = wantsKeyboardFocus
      view.keyboardNotice = keyboardNotice
      view.copyNotice = copyNotice
      view.focusChanged = { [session] in session.focus($0) }
      view.firstLayout = { [coordinator = context.coordinator] in coordinator.firstLayout(of: $0) }

      // A pane's history lives in herdr, so a drag becomes `terminal.scroll` and the scroll
      // view is turned off for good. On a feed with no `scroll`, a drag is the scroll view's
      // while the emulator has scrollback, and this pan's while the program owns the history.
      // See `DriverrTerminalUIView.applyDragRoute()`.
      let pan = UIPanGestureRecognizer(
        target: context.coordinator,
        action: #selector(Coordinator.handleDrag(_:))
      )
      // Trackpad and mouse wheel too. A pan takes no indirect scroll by default, and with the
      // scroll view off this is the only pan.
      pan.allowedScrollTypesMask = .all
      view.addGestureRecognizer(pan)
      view.dragPan = pan
      context.coordinator.draggedView = view
      if session.scrollsRemotely {
        view.isScrollEnabled = false
      } else {
        view.followsDragRoute = true
        view.applyDragRoute()
      }
      // A tap is also a click, for a program that asked for mouse reports. It targets
      // SwiftTerm's own single-tap recogniser, because a second one would need its own
      // double-tap failure requirement and would interact with selection.
      view.singleTapRecognizer?.addTarget(
        context.coordinator,
        action: #selector(Coordinator.handleTap(_:))
      )
      context.coordinator.tappedView = view
      view.accessibilityIdentifier = accessibilityIdentifier
      // Our row replaces the one SwiftTerm installed in init. When no row is wanted it is
      // `nil`, not SwiftTerm's.
      applyAccessoryRow(to: view, force: true)
      apply(palette: palette, to: view)

      // Attach before start, so bytes buffered at open time reach the emulator in order.
      session.attach(
        { [weak view] bytes in view?.feed(byteArray: bytes) },
        // The pane sheet reads a warm pane's thumbnail from this view's grid.
        visibleText: { [weak view] in view?.visibleText() ?? "" }
      )
      session.start()

      // The view takes focus itself, in `didMoveToWindow`.
      return view
    }

    public func updateUIView(_ view: DriverrTerminalUIView, context: Context) {
      // Guarded, because assigning `font` relays out the grid and sends a resize. Every
      // SwiftUI update would otherwise send a SIGWINCH.
      let font = uiFont
      if view.font != font { view.font = font }
      apply(palette: palette, to: view)
      // Re-applied on every update. The caller uses it to mark the terminal on screen,
      // and the `Chat | Terminal` segment makes an existing view current.
      view.accessibilityIdentifier = accessibilityIdentifier
      // Before the focus check, so a pane that just became current can answer the bump.
      view.wantsKeyboardFocus = wantsKeyboardFocus
      view.copyNotice = copyNotice
      applyAccessoryRow(to: view)

      if focusRequest != context.coordinator.lastFocusRequest {
        context.coordinator.lastFocusRequest = focusRequest
        // Next run-loop turn: a closing sheet is still first responder now, and the
        // request would be refused.
        DispatchQueue.main.async { view.takeKeyboardFocus() }
      }
    }

    /// Puts the key row on this terminal, or takes it off.
    ///
    /// It compares first, because `reloadInputViews()` on a first responder rebuilds the
    /// keyboard, and doing that on every update would flash it. A new row is built each
    /// time, because a row detached mid-repeat still holds a repeat timer.
    ///
    /// `force` is for `makeUIView`. The comparison reads "ours or none", so without it a
    /// terminal built with no row would keep SwiftTerm's.
    private func applyAccessoryRow(to view: DriverrTerminalUIView, force: Bool = false) {
      let installed = view.inputAccessoryView is DriverrKeyboardAccessory
      guard force || installed != showsAccessoryRow else { return }
      view.inputAccessoryView =
        showsAccessoryRow ? DriverrKeyboardAccessory(terminalView: view) : nil
      // Reloading on a view that is not first responder makes it steal the keyboard.
      if view.isFirstResponder { view.reloadInputViews() }
    }

    /// Takes exactly the space offered. The scroll view's content size is the grid, which
    /// depends on the view's size, so inferring a size from content is circular.
    public func sizeThatFits(
      _ proposal: ProposedViewSize,
      uiView: DriverrTerminalUIView,
      context: Context
    ) -> CGSize? {
      CGSize(
        width: proposal.width ?? uiView.bounds.width,
        height: proposal.height ?? uiView.bounds.height
      )
    }

    public static func dismantleUIView(_ view: DriverrTerminalUIView, coordinator: Coordinator) {
      // Detach, don't close. A navigation pop or a reflow is not the shell exiting.
      coordinator.session.detach()
    }

    private var palette: TerminalPalette {
      settings.theme.palette(for: colorScheme == .dark ? .dark : .light)
    }

    private func apply(palette: TerminalPalette, to view: DriverrTerminalUIView) {
      view.nativeForegroundColor = UIColor(palette.foreground)
      view.nativeBackgroundColor = UIColor(palette.background)
      view.backgroundColor = UIColor(palette.background)
      view.caretColor = UIColor(palette.cursor)
      view.installColors(palette.swiftTermANSI)
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
      let session: TerminalSession
      var lastFocusRequest = 0
      /// The view a drag is measured against.
      weak var draggedView: DriverrTerminalUIView?
      /// The view whose single tap `handleTap` turns into a click.
      weak var tappedView: DriverrTerminalUIView?
      /// Vertical drag not yet spent on a whole row.
      private var accumulator = RemoteScrollAccumulator()
      /// Whether the gesture under way is a trackpad or a mouse wheel rather than a touch.
      private var gestureIsIndirect = false

      init(session: TerminalSession) {
        self.session = session
      }

      /// Turns a drag into `terminal.scroll`, or into what `TerminalDragRoute` says the
      /// program takes, in rows at the drawn cell height, because both move by lines. Gesture
      /// actions run on the main thread, so `@MainActor` adds no hop.
      @MainActor
      @objc func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let view = draggedView else { return }
        let rows = max(view.getTerminal().rows, 1)
        let cellHeight = max(view.bounds.height / CGFloat(rows), 1)
        let lines: Int
        switch gesture.state {
        case .began:
          // Read at `.began`. At `.ended` a touch has lifted and would read as indirect.
          gestureIsIndirect = gesture.numberOfTouches == 0
          accumulator.begin()
          return
        case .changed:
          lines = accumulator.add(takeTranslation(of: gesture, in: view), cellHeight: cellHeight)
        case .ended:
          // A trackpad or wheel rounds its remainder up to a line, and a touch drops it.
          // A wheel notch may end the gesture before it has moved one line.
          lines = accumulator.end(
            takeTranslation(of: gesture, in: view),
            cellHeight: cellHeight,
            indirect: gestureIsIndirect
          )
        default:
          accumulator.cancel()
          return
        }
        guard lines != 0 else { return }
        deliverDrag(lines: lines, from: gesture, in: view)
      }

      /// Hands whole rows of a drag to whoever takes them. Positive is down the screen, which
      /// reveals older output, as in a scroll view. Synchronous, so rows keep the order the
      /// finger made them. `internal` so a hosted test can reach it: a pan reports no
      /// translation without real touches.
      @MainActor
      func deliverDrag(
        lines: Int,
        from gesture: UIGestureRecognizer,
        in view: DriverrTerminalUIView
      ) {
        let direction: ScrollDirection = lines > 0 ? .up : .down
        if session.scrollsRemotely {
          session.scroll(direction, lines: abs(lines))
        } else if let at = view.position(of: gesture, clampsAbove: true) {
          TerminalDragRoute.send(
            direction,
            lines: abs(lines),
            at: at.cell,
            pixelX: at.pixelX,
            pixelY: at.pixelY,
            to: view.getTerminal()
          )
        }
      }

      /// Sends a single tap to the far side as a left click.
      ///
      /// A pane's click goes to herdr, which reports it only if the program asked for mouse
      /// events. A pty's click is encoded here against the emulator's mouse mode.
      ///
      /// It runs after SwiftTerm's own action on the same recogniser.
      /// `DriverrTerminalUIView.takeClick(from:)` stops a tap that took the keyboard, ended
      /// a selection or closed the menu from also clicking.
      @MainActor
      @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view = tappedView,
          let click = view.takeClick(from: gesture)
        else { return }
        if session.clicksRemotely {
          session.click(column: click.cell.column, row: click.cell.row)
        } else if TerminalMouseClick.send(
          at: click.cell,
          pixelX: click.pixelX,
          pixelY: click.pixelY,
          to: view.getTerminal()
        ) {
          // The program took the tap as a click, so hide the Paste menu SwiftTerm showed.
          // A pane cannot know herdr's mouse mode, so it keeps the menu.
          (EditMenu.self as any EditMenuProbe.Type).hide()
        }
      }

      /// The vertical translation since the last call, reset so the next call reads a delta.
      @MainActor
      private func takeTranslation(of gesture: UIPanGestureRecognizer, in view: UIView) -> CGFloat {
        let translation = gesture.translation(in: view).y
        gesture.setTranslation(.zero, in: view)
        return translation
      }

      // SwiftTerm's delegate is not main-actor annotated, but UIKit calls it on the main
      // thread. `assumeIsolated` avoids a `Task` hop, which could reorder input against
      // output. Each method captures the `Sendable` session instead of `self`.
      public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let session = session
        MainActor.assumeIsolated { session.send(data) }
      }

      public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let session = session
        MainActor.assumeIsolated {
          session.resize(to: Self.size(of: source, columns: newCols, rows: newRows))
        }
      }

      @MainActor
      func firstLayout(of view: TerminalView) {
        let grid = view.getTerminal()
        session.firstGridMeasured(Self.size(of: view, columns: grid.cols, rows: grid.rows))
      }

      /// Pixels as well as cells: image protocols such as sixel and kitty size from the pixel
      /// pair, and 0 means "unspecified".
      @MainActor
      private static func size(of view: TerminalView, columns: Int, rows: Int) -> TerminalSize {
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        return TerminalSize(
          columns: columns,
          rows: rows,
          pixelWidth: Int((view.bounds.width * scale).rounded()),
          pixelHeight: Int((view.bounds.height * scale).rounded())
        )
      }

      public func setTerminalTitle(source: TerminalView, title: String) {
        let session = session
        MainActor.assumeIsolated { session.setTitle(title) }
      }

      public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
      public func scrolled(source: TerminalView, position: Double) {}
      public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
      public func bell(source: TerminalView) {}
      public func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
      }
      public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
      public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
  }

  /// SwiftTerm's `TerminalView` with Driverr's keyboard, selection and click behaviour.
  ///
  /// SwiftTerm leaves `accessibilityValue` empty. This view computes it on demand from
  /// the visible rows, for VoiceOver and the UI suite.
  public final class DriverrTerminalUIView: TerminalView {
    fileprivate static let logger = Logger(subsystem: "com.cunderw.driverr", category: "keyboard")

    /// Bounded, cancellable, and tested one tier down. See `FocusRetryPolicy`.
    private let focusRetry = FocusRetryPolicy()

    /// The drag recogniser installed by `DriverrTerminalView.makeUIView`. Kept so
    /// `gestureRecognizerShouldBegin` can tell it from SwiftTerm's selection pan.
    weak var dragPan: UIPanGestureRecognizer?

    /// Whether a drag depends on what the program is doing. False for a pane, whose drag is
    /// always `terminal.scroll`. Set before any byte is fed, in `makeUIView`.
    var followsDragRoute = false

    /// Gives the drag to the scroll view or to `dragPan`, as `TerminalDragRoute` says.
    ///
    /// **Only from `makeUIView`, `mouseModeChanged` and `bufferActivated`, and only on a
    /// change.** Touching `isScrollEnabled` from inside a gesture cancels the gesture.
    func applyDragRoute() {
      guard followsDragRoute, let dragPan else { return }
      let isLocal = TerminalDragRoute.route(for: getTerminal()) == .localScrollback
      if isScrollEnabled != isLocal { isScrollEnabled = isLocal }
      if dragPan.isEnabled == isLocal { dragPan.isEnabled = !isLocal }
    }

    /// Selection belongs to the phone, whatever mouse mode the far side asks for.
    ///
    /// With `allowMouseReporting` on, SwiftTerm hands taps and selection to the remote once
    /// it enables a mouse mode, and herdr always enables one. Set in `init` so it holds
    /// before any byte is fed. Clicks go through `Coordinator.handleTap` instead.
    override public init(frame: CGRect, font: UIFont?, options: TerminalOptions) {
      super.init(frame: frame, font: font, options: options)
      allowMouseReporting = false
    }

    public required init?(coder: NSCoder) {
      super.init(coder: coder)
      allowMouseReporting = false
    }

    /// Adds no mouse pan, whatever mouse mode the far side sets.
    ///
    /// SwiftTerm's version adds a pan whenever the mouse mode is not `.off`, and ignores
    /// `allowMouseReporting`. That pan takes the drag and sends it as motion reports, so a
    /// PTY on a host running herdr would not scroll. A drag goes by `applyDragRoute()`.
    override public func mouseModeChanged(source: Terminal) {
      applyDragRoute()
    }

    /// The alternate screen came or went, and with it the emulator's scrollback.
    override public func bufferActivated(source: Terminal) {
      super.bufferActivated(source: source)
      applyDragRoute()
    }

    /// Refuses SwiftTerm's selection pan while there is no selection.
    ///
    /// With no selection, a drag on that pan is sent to the far side as cursor keys.
    /// SwiftTerm removes the pan one main-queue hop after a selection ends, which is too
    /// late.
    ///
    /// It also judges a single tap for a click. SwiftTerm's own tap action runs before
    /// `Coordinator.handleTap` and clears the selection and the menu, so they must be read
    /// here.
    override public func gestureRecognizerShouldBegin(
      _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      if isSelectionPan(gestureRecognizer), !selection.active { return false }
      if gestureRecognizer === singleTapRecognizer {
        // Not while a resign is pending. See `wantsKeyboardFocus`.
        tapMayClick =
          isFirstResponder && !resignPending && !selection.active
          && !(EditMenu.self as any EditMenuProbe.Type).isVisible
      }
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// SwiftTerm's single-tap recogniser: on this view, one tap, one finger.
    ///
    /// Found by search, because SwiftTerm does not expose it. `TerminalMouseReportingTests`
    /// fails if SwiftTerm stops installing exactly one.
    var singleTapRecognizer: UITapGestureRecognizer? {
      for case let tap as UITapGestureRecognizer in gestureRecognizers ?? []
      where tap.view === self && tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1 {
        return tap
      }
      return nil
    }

    /// Whether the single tap now ending may click, set in `gestureRecognizerShouldBegin`.
    /// A tap that ends a selection or closes the edit menu sends nothing. Nor does a tap
    /// that takes the keyboard, which matches SwiftTerm's own mouse path.
    private var tapMayClick = false

    /// Where a tap landed, in this view's coordinates. A seam for a hosted test, since no
    /// in-process API creates a touch for `location(in:)` to read.
    var tapLocation: (UIGestureRecognizer, UIView) -> CGPoint = { $0.location(in: $1) }

    /// The cell and device-pixel position a tap should click, or `nil` when it should not.
    ///
    /// Uses the judgement made in `gestureRecognizerShouldBegin`. The cell size comes from
    /// `getOptimalFrameSize()`, because the view is usually wider than the grid.
    ///
    /// **The row is counted from the live screen, not the viewport.** The live screen is the
    /// last `rows` buffer lines. A tap on scrollback above it clicks nothing, because the
    /// program's row at that height is not the one the user sees. A tap below the last row
    /// clamps to it.
    func takeClick(from gesture: UIGestureRecognizer) -> (
      cell: TerminalCell, pixelX: Int, pixelY: Int
    )? {
      defer { tapMayClick = false }
      guard tapMayClick else { return nil }
      return position(of: gesture)
    }

    /// The cell and device-pixel position under a gesture, or `nil` above the live screen.
    ///
    /// - Parameter clampsAbove: take the top row instead of `nil`. A pan keeps tracking past
    ///   the view's edge, and a long swipe over a short terminal must not stop partway. A tap
    ///   up there is on scrollback, so it keeps the `nil`.
    func position(of gesture: UIGestureRecognizer, clampsAbove: Bool = false) -> (
      cell: TerminalCell, pixelX: Int, pixelY: Int
    )? {
      let terminal = getTerminal()
      let grid = getOptimalFrameSize()
      let cellHeight = Double(grid.height) / Double(max(terminal.rows, 1))
      guard cellHeight > 0 else { return nil }
      // `contentSize` is every buffer line, one cell each. It is the only public way to
      // find where the live screen starts.
      let bufferLines = Int((Double(contentSize.height) / cellHeight).rounded())
      let liveScreenTop = Double(max(0, bufferLines - terminal.rows)) * cellHeight
      // Content coordinates, as `location(in: self)` gives on a scroll view.
      let location = tapLocation(gesture, self)
      let x = Double(location.x - bounds.minX)
      let y = Double(location.y) - liveScreenTop
      guard y >= 0 || clampsAbove,
        let cell = TerminalCell.at(
          x: x,
          y: y,
          cellWidth: Double(grid.width) / Double(max(terminal.cols, 1)),
          cellHeight: cellHeight,
          columns: terminal.cols,
          rows: terminal.rows
        )
      else { return nil }
      let scale = Double(window?.screen.scale ?? traitCollection.displayScale)
      // Clamped to the grid, like the cell, so the two agree.
      let pixelX = min(max(0, x), Double(grid.width) - 1) * scale
      let pixelY = min(y, Double(grid.height) - 1) * scale
      return (cell, Int(max(0, pixelX)), Int(max(0, pixelY)))
    }

    /// Cancels a selection drag already in flight when the selection ends under it.
    ///
    /// A drag that began during a selection keeps delivering `.changed`, which SwiftTerm
    /// turns into cursor keys once the selection is gone. Toggling `isEnabled` cancels it.
    override public func selectionChanged(source: Terminal) {
      super.selectionChanged(source: source)
      guard !selection.active else { return }
      for recognizer in gestureRecognizers ?? [] where isSelectionPan(recognizer) {
        guard recognizer.isEnabled else { continue }
        recognizer.isEnabled = false
        recognizer.isEnabled = true
      }
    }

    private func isSelectionPan(_ recognizer: UIGestureRecognizer) -> Bool {
      recognizer is UIPanGestureRecognizer && recognizer.view === self
        && recognizer !== panGestureRecognizer && recognizer !== dragPan
    }

    /// Receives first-responder and keyboard-frame changes. `DriverrTerminalView.makeUIView`
    /// replaces this default right after construction.
    public var keyboardNotice = KeyboardNoticeModel()

    /// Told when the edit menu's Copy put text on the pasteboard. Assigned like
    /// `keyboardNotice`.
    public var copyNotice = TerminalCopyNotice()

    /// The edit menu's Copy, followed by a notice that it happened.
    ///
    /// SwiftTerm clears the selection on copy, which looks the same as a dismissed menu.
    /// The text is read before `super` clears it. Blank text and OSC 52 copies from the far
    /// side (`Coordinator.clipboardCopy`) show no notice.
    override public func copy(_ sender: Any?) {
      let text = selection.getSelectedText()
      super.copy(sender)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      copyNotice.copied()
      // Queued, because the closing menu moves VoiceOver focus and can cut off an
      // immediate announcement.
      UIAccessibility.post(
        notification: .announcement,
        argument: NSAttributedString(
          string: TerminalCopyNotice.text,
          attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
      )
    }

    /// Registers the keyboard observers once, because `didMoveToWindow` fires on every
    /// entry into a window.
    private var didObserveKeyboardFrame = false

    /// Takes focus on every entry into a window.
    ///
    /// `becomeFirstResponder()` is refused silently outside a window, and this is the
    /// moment that changes. A terminal back on screen is one the user is about to type
    /// into. `wantsKeyboardFocus` stops warm panes from taking it.
    override public func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else {
        // Leaving the window is not a refusal. Call off any retry still in flight.
        focusRetry.cancel()
        return
      }
      observeKeyboardFrameIfNeeded()
      takeKeyboardFocus()
    }

    /// Registers once for the keyboard notifications `KeyboardNoticeModel` needs. Selector
    /// based, because the block API needs a `@Sendable` closure.
    ///
    /// `keyboardDidShow` does not fire again for a rotation with the keyboard up, so
    /// `keyboardDidChangeFrame` covers that. `keyboardDidHide` resets the obstruction.
    /// Every warm view registers, and only the first responder forwards.
    private func observeKeyboardFrameIfNeeded() {
      guard !didObserveKeyboardFrame else { return }
      didObserveKeyboardFrame = true
      for name in [
        UIResponder.keyboardDidShowNotification,
        UIResponder.keyboardDidChangeFrameNotification,
      ] {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(keyboardFrameNotificationFired(_:)),
          name: name,
          object: nil
        )
      }
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(keyboardHidden),
        name: UIResponder.keyboardDidHideNotification,
        object: nil
      )
    }

    /// Forwarded only while this view holds the keyboard, because the notification is
    /// global and another field's keyboard would overwrite this view's frame height.
    @objc private func keyboardFrameNotificationFired(_ notification: Notification) {
      guard isFirstResponder else { return }
      let frame =
        (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
        .cgRectValue ?? .zero
      keyboardNotice.keyboardFrameChanged(height: Double(frame.height))
      reportAccessoryRowPosition()
    }

    /// The accessory row has gone with the keyboard, so the grid gets its rows back.
    ///
    /// No `isFirstResponder` guard: by now this view is usually not first responder, and a
    /// hidden row covers nothing.
    @objc private func keyboardHidden() {
      keyboardNotice.accessoryRowTopChanged(nil)
    }

    /// Reports the accessory row's position on every layout as well as on keyboard
    /// notifications. During rotation the notification fires before the row moves, and a
    /// keyboard can appear without a layout. Unchanged values are dropped.
    override public func layoutSubviews() {
      super.layoutSubviews()
      reportAccessoryRowPosition()
      if let firstLayout, !bounds.isEmpty {
        self.firstLayout = nil
        firstLayout(self)
      }
    }

    /// Reports the accessory row's top edge in the app window's coordinates, the space of
    /// SwiftUI's `.global` frames.
    ///
    /// The row lives in UIKit's input window. Converting into this view's window keeps the
    /// answer right when the app does not fill the screen. Only the first responder
    /// reports, or warm panes would report "no row".
    private func reportAccessoryRowPosition() {
      guard isFirstResponder else { return }
      guard let accessory = inputAccessoryView, accessory.window != nil, let window else {
        keyboardNotice.accessoryRowTopChanged(nil)
        return
      }
      let top = window.convert(accessory.bounds, from: accessory).minY
      keyboardNotice.accessoryRowTopChanged(Double(top))
    }

    /// Whether this view may hold the keyboard. The container sets it `false` on warm panes
    /// that are alive but not on screen.
    ///
    /// Turning it off also gives the keyboard back. Otherwise a terminal left by the
    /// `Chat | Terminal` segment keeps its accessory row up and the composer lays out under
    /// the keyboard.
    ///
    /// **The resign waits one run-loop turn.** This is set from `updateUIView`, inside
    /// SwiftUI's render. Resigning there relays out the window and re-enters the render,
    /// and the main thread hangs until the watchdog kills the app.
    public var wantsKeyboardFocus = true {
      didSet {
        guard !wantsKeyboardFocus, isFirstResponder else { return }
        resignPending = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          resignPending = false
          guard !wantsKeyboardFocus, isFirstResponder else { return }
          _ = resignFirstResponder()
        }
      }
    }

    /// Told when this view gains or loses the keyboard. `TerminalFeed.focus` is what wants it.
    var focusChanged: ((Bool) -> Void)?

    /// Told once, after the first layout that gave this view a size. See
    /// `TerminalSession.firstGridMeasured(_:)`.
    var firstLayout: ((DriverrTerminalUIView) -> Void)?

    /// Set between `wantsKeyboardFocus` turning off and the resign it schedules, so a tap in
    /// that gap does not click.
    private(set) var resignPending = false

    /// Ask for the keyboard, and keep asking for a moment if the first ask is refused.
    ///
    /// The one entry point for focus. A container with several terminals calls it on the
    /// one on screen.
    public func takeKeyboardFocus() {
      guard wantsKeyboardFocus else { return }
      focusRetry.begin(
        attempt: { [weak self] in
          // A deallocated view refused nothing. Report success so no failure is logged.
          guard let self else { return true }
          // Nor has a view told it may not have the keyboard, or its retry would take the
          // keyboard from a chat tapped in the meantime.
          guard wantsKeyboardFocus else { return true }
          return becomeFirstResponder()
        },
        onExhausted: { attempts in
          // Log the refusal, or a terminal that cannot take the keyboard fails silently.
          Self.logger.error(
            """
            The terminal was refused the keyboard \(attempts, privacy: .public) times and \
            has given up; it will not accept typing. If focus was in fact granted and there \
            is still no keyboard on screen, look for an attached hardware keyboard instead.
            """
          )
        }
      )
    }

    /// Reports refusals as well as grants. The notice must stay silent until focus is known,
    /// rather than read the hardware-keyboard flag alone.
    override public func becomeFirstResponder() -> Bool {
      let granted = super.becomeFirstResponder()
      keyboardNotice.firstResponderChanged(granted)
      if granted { focusChanged?(true) }
      return granted
    }

    override public func resignFirstResponder() -> Bool {
      // A retry still in flight would take the keyboard straight back after the
      // hide-keyboard key.
      focusRetry.cancel()
      // The accessory row goes with the keyboard, and a held key never gets its touch-up.
      // Its repeat would keep sending into the next pane.
      (inputAccessoryView as? DriverrKeyboardAccessory)?.stopKeyRepeat()
      // A noted Shift-Return must not outlive the keyboard.
      shiftReturnPending = false
      let resigned = super.resignFirstResponder()
      // A refused resign changed nothing, so do not report it as dismissed.
      if resigned {
        keyboardNotice.firstResponderChanged(false)
        focusChanged?(false)
      }
      return resigned
    }

    /// Treats a cancelled press as an ended one.
    ///
    /// SwiftTerm's key-repeat timer stops only in `pressesEnded` and
    /// `resignFirstResponder`. Backgrounding mid-hold cancels the press, and the repeat
    /// would go on, for example erasing a line with `Ctrl-U`. The timer is internal to
    /// SwiftTerm, so forwarding to `pressesEnded` is the only way to stop it. Nothing above
    /// the terminal handles presses, so passing them up as ended costs nothing.
    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      shiftReturnPending = false
      super.pressesEnded(presses, with: event)
    }

    /// A hardware Shift-Return is on its way to `insertText`.
    ///
    /// UIKit delivers Return as `insertText("\n")` with no modifier, so Shift is read in
    /// `pressesBegan`. `insertText` does not clear it, because a held Shift-Return repeats
    /// through `insertText` alone. `internal` so a hosted test can set it.
    var shiftReturnPending = false

    /// Whether a hardware keyboard is attached. A seam, because the simulator always has
    /// one.
    var isHardwareKeyboardConnected: () -> Bool = { HardwareKeyboardMonitor.isCurrentlyConnected }

    /// Notes a hardware Shift-Return, then lets SwiftTerm and UIKit handle the press as usual.
    ///
    /// Assigned on every press, because SwiftTerm's `pressesEnded` is not `open` and cannot
    /// clear it. Cmd-Shift-Return stays a shortcut. Under the kitty keyboard protocol
    /// SwiftTerm encodes Shift-Return itself.
    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      shiftReturnPending =
        getTerminal().keyboardEnhancementFlags.isEmpty
        && presses.contains(where: Self.isShiftReturn)
      super.pressesBegan(presses, with: event)
    }

    private static func isShiftReturn(_ press: UIPress) -> Bool {
      guard let key = press.key else { return false }
      return [.keyboardReturnOrEnter, .keypadEnter].contains(key.keyCode)
        && key.modifierFlags.contains(.shift) && !key.modifierFlags.contains(.command)
    }

    /// Return with Shift or an armed Ctrl sends a line feed. See `ReturnKeyBytes`.
    ///
    /// SwiftTerm's Control path sends no bytes for "\n", and its Return method is private.
    /// So Ctrl is disarmed, which also resets the row's Ctrl key, and `returnByteSequence`
    /// is swapped for one call. Under the kitty protocol Ctrl is left to SwiftTerm, which
    /// reports Ctrl-Enter as a key event.
    override public func insertText(_ text: String) {
      let control = controlModifier && getTerminal().keyboardEnhancementFlags.isEmpty
      // Software-keyboard taps never reach `pressesBegan` to clear the flag.
      let shift = shiftReturnPending && isHardwareKeyboardConnected()
      guard text == "\n", shift || control else {
        super.insertText(text)
        return
      }
      let bytes = ReturnKeyBytes.bytes(shift: shift, control: control)
      controlModifier = false
      let saved = returnByteSequence
      returnByteSequence = bytes
      defer { returnByteSequence = saved }
      super.insertText(text)
    }

    override public var accessibilityValue: String? {
      get { visibleText() }
      set { super.accessibilityValue = newValue }
    }

    /// The on-screen rows, newline-separated, with trailing blanks removed.
    public func visibleText() -> String {
      let terminal = getTerminal()
      return (0..<terminal.rows)
        .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// Whether SwiftTerm's edit menu is on screen, and a way to put it away.
  ///
  /// SwiftTerm uses the deprecated `UIMenuController`. The calls are marked deprecated and
  /// reached through a protocol, so they warn nowhere. Replace this when SwiftTerm moves
  /// to `UIEditMenuInteraction`.
  ///
  /// Internal so a hosted test can hide the menu between taps, because one menu per
  /// process left up blocks every later tap.
  @MainActor
  protocol EditMenuProbe {
    static var isVisible: Bool { get }
    static func hide()
  }

  @MainActor
  enum EditMenu: EditMenuProbe {
    @available(iOS, deprecated: 16.0, message: "SwiftTerm's menu is a UIMenuController")
    static var isVisible: Bool { UIMenuController.shared.isMenuVisible }

    @available(iOS, deprecated: 16.0, message: "SwiftTerm's menu is a UIMenuController")
    static func hide() { UIMenuController.shared.hideMenu() }
  }

  extension UIColor {
    fileprivate convenience init(_ color: DriverrCore.TerminalColor) {
      self.init(
        red: CGFloat(color.red) / 255,
        green: CGFloat(color.green) / 255,
        blue: CGFloat(color.blue) / 255,
        alpha: 1
      )
    }
  }
#endif

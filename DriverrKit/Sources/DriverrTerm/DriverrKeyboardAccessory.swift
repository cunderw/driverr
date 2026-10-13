#if canImport(UIKit) && !os(watchOS)
  import DriverrCore
  import SwiftTerm
  import UIKit

  /// The row above the software keyboard: the keys a terminal needs and a phone keyboard
  /// does not have.
  ///
  /// It replaces SwiftTerm's row, which has more keys than fit and untitled symbol buttons
  /// a UI test cannot find. These keys carry stable identifiers.
  ///
  /// **The row holds eight keys. Adding one means removing one.** Each slot costs 47 pt
  /// (44 pt key, 3 pt gap) plus 12 pt of row margin, so `n` keys keep the 44 pt floor only
  /// where the screen is at least `47n + 9` wide. On a 402 pt phone a ninth key is 40.7 pt,
  /// and `TerminalKeyboardUITests.testAccessoryRowIsPresentOnArrival` fails.
  ///
  /// Escape, Tab, Control and dismiss cannot be displaced, because nothing else reaches
  /// what they do. Only the arrows are displaceable.
  ///
  /// Control is sticky, like the system keyboard's shift key: it arms the next key and
  /// clears itself afterwards.
  final class DriverrKeyboardAccessory: UIInputView {
    weak var terminalView: TerminalView?

    private let controlButton = UIButton(type: .system)

    /// Hold-to-repeat for the cursor keys. Its cadence and every way it stops are tested in
    /// `DriverrTermTests`, because a simulator cannot hold a finger on a button.
    private let keyRepeat = KeyRepeatPolicy()

    /// **Sized so each key is 44 pt, not so the row is.** 48 − 2 × 2 = 44 pt tall. On a
    /// 402 pt phone each key is (402 − 2 × 6 − 7 × 3) ÷ 8 ≈ 46.1 pt wide.
    ///
    /// On a 375 pt phone the keys are 42.75 pt wide, under the floor. That is accepted,
    /// rather than dropping a key there. The numbers live in
    /// `PaneKey.AccessoryRowMetrics`, where `swift test` checks them.
    private static let rowHeight = CGFloat(PaneKey.AccessoryRowMetrics.rowHeight)
    private static let verticalInset = CGFloat(PaneKey.AccessoryRowMetrics.verticalInset)
    private static let horizontalMargin = CGFloat(PaneKey.AccessoryRowMetrics.horizontalMargin)
    private static let keySpacing = CGFloat(PaneKey.AccessoryRowMetrics.keySpacing)

    /// The colour behind the keys, or `nil` where the row draws none.
    ///
    /// **An iPad gets one opaque backing and a phone gets none.** The system sizes the row to
    /// the keyboard, so on an iPad it spans the split view. With no backing the gaps show
    /// the sidebar on one side and the terminal on the other, and the translucent keys take
    /// two tones.
    ///
    /// On a phone the row sits over the terminal alone and its gaps show the theme's
    /// surface. A backing there would replace it, so the phone keeps none.
    ///
    /// **Two system colours, one per appearance, because no single one sits near the
    /// keyboard's own band in both.** `systemGray5` is 12 lighter than the band in dark and
    /// `secondarySystemBackground` is 16 lighter in light, and each shows as a stripe.
    /// Semantic colours, not theme colours: the row belongs to the keyboard.
    ///
    /// The backing stops at the row's bounds. Below it the keyboard's rounded top corners
    /// still show the app, as they do on a phone.
    static func backing(for idiom: UIUserInterfaceIdiom) -> UIColor? {
      guard idiom == .pad else { return nil }
      return UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemGray5
      }
    }

    /// `idiom` is a parameter so `DriverrTests` can build the iPad row on a phone simulator.
    init(
      terminalView: TerminalView,
      idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) {
      self.terminalView = terminalView
      super.init(
        frame: CGRect(x: 0, y: 0, width: 0, height: Self.rowHeight),
        inputViewStyle: .keyboard
      )
      allowsSelfSizing = true
      translatesAutoresizingMaskIntoConstraints = false
      if let backing = Self.backing(for: idiom) {
        backgroundColor = backing
      }
      build()

      // SwiftTerm clears `controlModifier` after the armed key and posts this. Without it
      // the button stays lit over a modifier that is no longer armed.
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(controlWasReset),
        name: Notification.Name("SwiftTerm.TerminalView.controlModifierReset"),
        object: nil
      )

      // A touch down when the app leaves the screen may never get a touch-up, and the key
      // would keep repeating. `willResignActive` also covers the app switcher, alerts and
      // calls.
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(stopKeyRepeat),
        name: UIApplication.willResignActiveNotification,
        object: nil
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
      controlButton.accessibilityIdentifier = "terminal.key.ctrl"
      // VoiceOver would read "ctrl" as a word.
      controlButton.accessibilityLabel = "Control"
      controlButton.addTarget(self, action: #selector(toggleControl), for: .touchUpInside)
      style(controlButton, title: "Ctrl")

      let stack = UIStackView(arrangedSubviews: [
        key(
          PaneKey.esc.label,
          identifier: "terminal.key.esc",
          spoken: PaneKey.esc.accessibleName,
          action: #selector(sendEscape)
        ),
        key(
          PaneKey.tab.label,
          identifier: "terminal.key.tab",
          spoken: PaneKey.tab.accessibleName,
          action: #selector(sendTab)
        ),
        controlButton,
        arrowKey(PaneKey.left, identifier: "terminal.key.left", cursor: "D"),
        arrowKey(PaneKey.down, identifier: "terminal.key.down", cursor: "B"),
        arrowKey(PaneKey.up, identifier: "terminal.key.up", cursor: "A"),
        arrowKey(PaneKey.right, identifier: "terminal.key.right", cursor: "C"),
        dismissButton(),
      ])
      stack.axis = .horizontal
      stack.distribution = .fillEqually
      stack.spacing = Self.keySpacing
      stack.translatesAutoresizingMaskIntoConstraints = false
      addSubview(stack)
      // Against `self`, not `layoutMarginsGuide`, whose 8 pt margins would take the keys
      // under 44 pt. See `rowHeight`.
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(
          equalTo: leadingAnchor, constant: Self.horizontalMargin),
        stack.trailingAnchor.constraint(
          equalTo: trailingAnchor, constant: -Self.horizontalMargin),
        stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
        heightAnchor.constraint(equalToConstant: Self.rowHeight),
      ])
    }

    /// Puts the keyboard away without leaving the terminal. The keyboard covers about 40%
    /// of a phone, and a UIKit view gets no `.scrollDismissesKeyboard`.
    ///
    /// The only glyph on the row, because it is a system action rather than a terminal key.
    /// The explicit label stops VoiceOver reading the symbol name, which
    /// `AccessibilityUITests` rejects.
    private func dismissButton() -> UIButton {
      let button = UIButton(type: .system)
      button.accessibilityIdentifier = "terminal.key.dismiss"
      button.accessibilityLabel = "Hide keyboard"
      button.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
      style(button, title: "")
      button.setImage(
        UIImage(systemName: "keyboard.chevron.compact.down"),
        for: .normal
      )
      return button
    }

    /// Resigns the terminal, which is the first responder. Resigning this view does
    /// nothing.
    @objc private func dismissKeyboard() {
      _ = terminalView?.resignFirstResponder()
    }

    private func key(
      _ title: String,
      identifier: String,
      spoken: String,
      action: Selector
    ) -> UIButton {
      let button = UIButton(type: .system)
      button.accessibilityIdentifier = identifier
      button.accessibilityLabel = spoken
      button.addTarget(self, action: action, for: .touchUpInside)
      style(button, title: title)
      return button
    }

    /// A cursor key that repeats while held. Escape, Tab and Control do not repeat: a
    /// repeated Tab floods completions, and Control sends nothing.
    ///
    /// It sends on `.touchDown`, so a hold starts at once and a tap still sends once.
    /// Four events stop it: a lift inside or outside, a drag off the key, and a cancel.
    /// Backgrounding and the keyboard going away are handled in `init` and
    /// `didMoveToWindow`.
    ///
    /// A hold means "repeat" here, so an arrow key cannot also host a long-press variant.
    private func arrowKey(
      _ key: PaneKey,
      identifier: String,
      cursor: Character
    ) -> UIButton {
      let button = UIButton(type: .system)
      button.accessibilityIdentifier = identifier
      // Otherwise VoiceOver reads "←" as "leftwards arrow".
      button.accessibilityLabel = key.accessibleName
      button.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          keyRepeat.begin { [weak self] in self?.sendCursor(cursor) }
        },
        for: .touchDown
      )
      for ending: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel] {
        button.addAction(
          UIAction { [weak self] _ in self?.stopKeyRepeat() },
          for: ending
        )
      }
      style(button, title: key.accessoryGlyph)
      return button
    }

    /// Every route out of a held key ends here. `internal` because
    /// `DriverrTerminalUIView` calls it on resign, which delivers no touch-up.
    @objc func stopKeyRepeat() {
      keyRepeat.stop()
    }

    /// Stops the repeat when the row leaves the window, even if the terminal view is torn
    /// out without resigning.
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { stopKeyRepeat() }
    }

    private func style(_ button: UIButton, title: String) {
      button.setTitle(title, for: .normal)
      button.titleLabel?.font = .systemFont(
        ofSize: CGFloat(PaneKey.AccessoryRowMetrics.fontSize),
        weight: .medium
      )
      button.backgroundColor = .tertiarySystemFill
      button.layer.cornerRadius = CGFloat(PaneKey.AccessoryRowMetrics.cornerRadius)
      // Semantic colours only. Only the terminal itself is themed.
      button.tintColor = .label
    }

    // MARK: - Keys

    /// `0x1B`, which a software keyboard cannot type.
    @objc private func sendEscape() { send([0x1B]) }
    @objc private func sendTab() { send([0x09]) }

    // A program that set DECCKM expects `ESC O A`, a shell expects `ESC [ A`. The mode is
    // read on every repeat, because it can change during a hold.
    private func sendCursor(_ final: Character) {
      let applicationMode = terminalView?.getTerminal().applicationCursor ?? false
      let introducer: [UInt8] = applicationMode ? [0x1B, 0x4F] : [0x1B, 0x5B]
      send(introducer + Array(String(final).utf8))
    }

    @objc private func toggleControl() {
      guard let terminalView else { return }
      terminalView.controlModifier.toggle()
      reflectControl(terminalView.controlModifier)
    }

    @objc private func controlWasReset() {
      reflectControl(false)
    }

    /// Armed Control inverts, as the system shift key does, so it is visible in dark mode.
    ///
    /// VoiceOver gets the `.selected` trait. The "on"/"off" value stays because
    /// `TerminalKeyboardUITests` reads it.
    private func reflectControl(_ armed: Bool) {
      controlButton.isSelected = armed
      controlButton.backgroundColor = armed ? .label : .tertiarySystemFill
      controlButton.tintColor = armed ? .systemBackground : .label
      controlButton.accessibilityValue = armed ? "on" : "off"
      if armed {
        controlButton.accessibilityTraits.insert(.selected)
      } else {
        controlButton.accessibilityTraits.remove(.selected)
      }
    }

    private func send(_ bytes: [UInt8]) {
      terminalView?.send(bytes)
    }
  }
#endif

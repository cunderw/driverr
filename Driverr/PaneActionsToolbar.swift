import DriverrCore
import SwiftUI

/// The … menu, which renders for every target. A plain shell has no `PaneActionsModel`, and
/// without the menu it would have no way to change its font.
struct PaneActionsMenu: View {
  let model: PaneActionsModel?

  /// The host's Start/Stop Live Activity item, or `nil` while the global switch is off.
  ///
  /// Hidden, not disabled, because a menu cannot explain a disabled item and the explanation
  /// is on the Settings screen. Passed in because this menu has no host; `TerminalScreen` has
  /// both the host and the preferences model.
  let liveActivity: LiveActivityMenuItem?

  /// Continue in Background for this pane's host, or `nil` when the link is down or another
  /// host holds the run.
  ///
  /// Not gated on the Live Activities switch, because it keeps the connection and the poll
  /// alive, not only the card. Hidden rather than dimmed while another host holds the run,
  /// because a `Menu` cannot say why. The host screen dims it and explains in a footer. See
  /// `BackgroundWatch.isInMenu`.
  let backgroundWatch: BackgroundWatchMenuItem?

  let onSettings: () -> Void

  var body: some View {
    Menu {
      if let model { PaneActionItems(model: model) }
      // One divider here and none below. The groups are {Rename} {Close Pane}
      // {Live Activity, Continue in Background, Settings}: the destructive item alone, and the
      // three that are not pane actions together.
      Divider()
      if let liveActivity {
        // Directly in the `Menu`, never in a `Section`: a `Button` in a `Section` in this menu
        // loses its `accessibilityIdentifier`.
        Button {
          liveActivity.toggle()
        } label: {
          Label(
            LiveActivityCopy.hostButtonTitle(isStarted: liveActivity.isStarted),
            systemImage: liveActivity.isStarted ? "bolt.slash" : "bolt")
        }
        .accessibilityIdentifier("pane.liveActivity")
      }
      if let backgroundWatch {
        // Directly in the `Menu`, in the same group, for the same reasons as the item above.
        Button {
          backgroundWatch.toggle()
        } label: {
          Label(
            BackgroundWatchCopy.buttonTitle(isRunning: backgroundWatch.isRunning),
            systemImage: BackgroundWatchCopy.systemImage(isRunning: backgroundWatch.isRunning))
        }
        .accessibilityIdentifier("pane.continueInBackground")
      }
      Button {
        onSettings()
      } label: {
        Label("Settings", systemImage: "textformat.size")
      }
      .accessibilityIdentifier("terminal.settings")
    } label: {
      // Show progress while herdr answers, so the tap does not look ignored. `model?`
      // because a shell has no model and is never busy.
      if model?.isBusy == true {
        ProgressView()
          .accessibilityLabel("Working on the pane")
      } else {
        Label("Pane Actions", systemImage: "ellipsis.circle")
      }
    }
    .accessibilityIdentifier("pane.actions")
  }
}

/// One host's Start/Stop Live Activity, for both surfaces that offer it.
///
/// A `Button` that retitles itself, not a `Toggle`: a `Menu` cannot hold a `Toggle`, and a
/// button is the one shape the pane menu and the host screen can share, so they word it the
/// same way.
struct LiveActivityMenuItem {
  let isStarted: Bool
  let toggle: () -> Void
}

/// Continue in Background for one host, for both surfaces that offer it.
///
/// A retitling `Button`, like `LiveActivityMenuItem`. `isRunning` comes from
/// `BackgroundWatchRunner`, so a run shows on both surfaces at once.
struct BackgroundWatchMenuItem {
  let isRunning: Bool
  let toggle: () -> Void
}

/// The items that need a live model. Split out because `@Bindable` cannot hold an
/// optional. Splitting a pane is on the switcher's New pane cell, not here.
private struct PaneActionItems: View {
  @Bindable var model: PaneActionsModel

  var body: some View {
    // Disabled on the pane actions, not the whole menu, so Settings stays reachable on a
    // busy pane. `PaneActionsModel.perform` also drops a second request in flight.
    Group {
      Button {
        model.startRenaming()
      } label: {
        Label("Rename…", systemImage: "pencil")
      }
      .accessibilityIdentifier("pane.rename")

      // `Divider()`, not `Section`: a `Button` inside a `Section` in this `Menu` loses its
      // `accessibilityIdentifier`, while one declared directly in the `Menu` keeps it.
      Divider()

      Button(role: .destructive) {
        Task { await model.request(.close) }
      } label: {
        // The ellipsis says it will ask first. `xmark.square`, because a bare × in a menu
        // reads as dismissing the menu.
        Label("Close Pane…", systemImage: "xmark.square")
      }
      // `.tint(.red)` colours the icon; `role: .destructive` colours only the title. SwiftUI
      // resolves a menu item's image against the ambient tint, which is the theme accent, so
      // without this the icon draws blue beside a red word. A colour on the `Label`'s own
      // icon does not reach it, and neither does `.renderingMode(.template)`, because UIKit
      // renders the image from the tint.
      .tint(.red)
      .accessibilityIdentifier("pane.close")
    }
    .disabled(model.isBusy)
  }
}

/// The confirmation, the rename field and the failure notice, inline rather than modal.
///
/// On a phone a two-button bar is no worse than a modal, and it keeps the pane's title
/// beside the question. See CLAUDE.md, "Never present from inside a presentation", which also
/// warns that a pane scene that would not dismiss was a wrong `TerminalPresenter`, not an alert.
struct PanePromptBar: View {
  @Bindable var model: PaneActionsModel

  /// Only the rename field is a text input, so this has one thing to bind to.
  @FocusState private var isRenameFieldFocused: Bool
  @State private var renameSelection: TextSelection?

  var body: some View {
    if let prompt = model.prompt {
      VStack(alignment: .leading, spacing: 8) {
        switch prompt {
        case .confirm(let action):
          // Named, because the whole risk here is closing the wrong one.
          Text("Close \u{201C}\(model.pane.title)\u{201D}? Whatever is running in it will end.")
            .font(.footnote)
          // The same action row as `PaneComposerBar`'s `interruptConfirm`, because both bars
          // ask the same kind of question. That type's comments hold the reasons; only the
          // differences are noted here.
          HStack(spacing: 12) {
            Button { model.cancelConfirmation() } label: {
              BorderedButtonLabel {
                Text("Cancel").fontWeight(.semibold).frame(maxWidth: .infinity)
              }
            }
            .accessibilityIdentifier("pane.close.cancel")
            // Bare `Text`: `BorderedButtonLabel` would force `Color.primary` and erase the
            // destructive role this button exists to show.
            Button(role: .destructive) {
              Task { await model.confirm(action) }
            } label: {
              Text("Close Pane").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("pane.close.confirm")
          }
          // Semibold on both labels, as in `interruptConfirm`, where the light-mode contrast
          // is discussed.
          // `.buttonStyle(.bordered)` is restated although the container sets it, so a change
          // made there for the other rows cannot change this one. `.tint(Color?.none)` matters
          // most: under the root accent tint, `.bordered` colours from the tint instead of the
          // role, and the confirm draws the same as Cancel.
          .buttonStyle(.bordered)
          .controlSize(.large)
          .buttonBorderShape(.capsule)
          .tint(Color?.none)
          .frame(maxWidth: 420)
          .frame(maxWidth: .infinity, alignment: .trailing)

        case .rename:
          Text("Rename this pane")
            .font(.footnote)
          // Nothing else raises the keyboard for an inline bar. The whole draft is selected,
          // so the first keystroke replaces the name.
          TextField("Pane name", text: $model.draftLabel, selection: $renameSelection)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isRenameFieldFocused)
            // Return commits, as in any one-field form, and the key reads "done".
            .submitLabel(.done)
            .onSubmit { Task { await model.commitRename() } }
            .accessibilityIdentifier("pane.rename.field")
            .task { isRenameFieldFocused = true }
            // Becoming first responder resets the selection, so select all only after
            // `@FocusState` reports that focus has landed.
            .onChange(of: isRenameFieldFocused) { _, focused in
              guard focused else { return }
              renameSelection = TextSelection(
                range: model.draftLabel.startIndex..<model.draftLabel.endIndex)
            }
          HStack {
            Button { model.dismissPrompt() } label: {
              BorderedButtonLabel("Cancel")
            }
            .accessibilityIdentifier("pane.rename.cancel")
            Spacer()
            Button { Task { await model.commitRename() } } label: {
              BorderedButtonLabel("Rename")
            }
            .accessibilityIdentifier("pane.rename.commit")
          }

        case .failed(let error):
          Text(error.errorDescription ?? "herdr refused the request.")
            .font(.footnote)
          HStack {
            Spacer()
            Button { model.clearFailure() } label: {
              BorderedButtonLabel("OK")
            }
            .accessibilityIdentifier("pane.error.dismiss")
          }
        }
      }
      .buttonStyle(.bordered)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      // No identifier on this container. See CLAUDE.md, "Test traps": it would rename every
      // button in the bar to "pane.prompt".
      .background(.thinMaterial)
    }
  }
}

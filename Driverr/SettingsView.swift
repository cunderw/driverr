import DriverrCore
import DriverrTerm
import SwiftUI
import UIKit

/// The complete global settings screen: theme, font, font size, whether a captured pane
/// screen wraps its long lines, and whether Driverr draws Live Activities.
///
/// That is the whole surface (CLAUDE.md, "Not a config surface"). There is no "Advanced"
/// section for another setting to hide in.
struct SettingsView: View {
  @Environment(\.settingsModel) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.appEnvironment) private var appEnvironment
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  /// What the system says about notifications, or `nil` until the first read comes back.
  /// See `NotificationsOffNotice`.
  @State private var notifications: NotificationAuthorization?

  var body: some View {
    NavigationStack {
      Form {
        // A notice, not a setting. Shown only when notifications are denied, to explain
        // why a blocked pane does not alert. First, because it is a problem, not a choice.
        if NotificationsOffNotice.isVisible(
          status: notifications,
          isStoreTour: AppEnvironment.isDemoTranscript
        ) {
          Section {
            notificationsOffRow
          }
        }

        // At the top, so a theme or size change below lands on something already on
        // screen. Drawn with the terminal's own palette.
        Section("Preview") {
          preview
        }

        Section {
          ForEach(Theme.bundled) { theme in
            Button {
              model.select(theme: theme)
            } label: {
              row(theme.name, selected: theme.id == model.settings.themeID) {
                swatch(theme)
              }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.theme.\(theme.id)")
          }
        } header: {
          Text("Theme")
        } footer: {
          Text("Themes follow the system's light and dark appearance.")
        }

        Section("Font") {
          ForEach(TerminalFont.bundled) { font in
            Button {
              model.select(font: font)
            } label: {
              row(font.name, selected: font.id == model.settings.fontID, font: rowFont(font))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.font.\(font.id)")
          }
        }

        Section("Font Size") {
          // Not `Stepper`: its ranged initialiser clamps the value but never disables its
          // buttons at the bounds. These buttons read `canShrinkFont` and `canGrowFont`.
          HStack {
            Text("\(Int(model.settings.fontSize)) pt")
              .accessibilityIdentifier("settings.fontsize.value")
            Spacer()
            // On the pill, not the row, so it does not overwrite "settings.fontsize.value".
            fontSizeControl
              .accessibilityIdentifier("settings.fontsize")
          }
        }

        // The identifier is on the `Toggle`, not the `Section`, because `setSwitch` drives
        // `app.switches[id]`.
        Section {
          Toggle(
            PaneScreenCopy.wrapTitle,
            isOn: Binding(
              get: { model.settings.wrapsScreenLines },
              set: { model.setWrapsScreenLines($0) }
            )
          )
          .accessibilityIdentifier("settings.wraplines")
        } header: {
          Text("Pane Screen")
        } footer: {
          Text(PaneScreenCopy.wrapFooter)
        }

        // A Live Activity is drawn outside the app, so this is the only way to refuse one.
        // The identifier is on the `Toggle`, as above.
        Section {
          Toggle(
            LiveActivityCopy.title,
            isOn: Binding(
              get: { model.settings.liveActivities },
              set: { model.setLiveActivities($0) }
            )
          )
          .accessibilityIdentifier("settings.liveactivities")
        } header: {
          Text("Live Activities")
        } footer: {
          Text(LiveActivityCopy.footer)
        }

        // Which build is running. Installing over a running app does not swap its code, so
        // a bug report needs this. Development builds share a version, so the build time
        // is what tells them apart.
        Section("Build") {
          LabeledContent("Version", value: buildStamp.versionSummary)
            .accessibilityIdentifier("settings.build.version")
          LabeledContent("Built", value: buildStamp.builtSummary())
            .accessibilityIdentifier("settings.build.date")
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            // Toolbar text takes `Color.primary`. See CLAUDE.md, Style.
            .tint(Color.primary)
            .accessibilityIdentifier("settings.done")
        }
      }
    }
    .task {
      await model.load()
      await readNotificationAuthorization()
    }
    // Read again on return from iOS Settings, where the notice sends people, so the notice
    // goes once notifications are allowed.
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await readNotificationAuthorization() }
    }
  }

  private func readNotificationAuthorization() async {
    notifications = await appEnvironment.notifications.authorizationStatus()
  }

  /// The notifications-off row. The identifier is on the `Button`, not a container.
  private var notificationsOffRow: some View {
    Button {
      // Opens Driverr's own notification page, not the top of Settings.
      guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
      openURL(url)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(NotificationsOffNotice.title)
            .foregroundStyle(.primary)
          Text(NotificationsOffNotice.message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("settings.notifications.off")
  }

  /// Read once, not per redraw, because `attributesOfItem` is a file-system call.
  private let buildStamp = AppBuildStamp()

  private var palette: TerminalPalette {
    model.settings.theme.palette(for: colorScheme == .dark ? .dark : .light)
  }

  /// A minus/plus pair drawn as one pill, like a `Stepper`.
  private var fontSizeControl: some View {
    HStack(spacing: 0) {
      Button {
        model.shrinkFont()
      } label: {
        Image(systemName: "minus")
          .frame(width: 47, height: 32)
      }
      .disabled(!model.settings.canShrinkFont)

      Divider()
        .frame(height: 20)

      Button {
        model.growFont()
      } label: {
        Image(systemName: "plus")
          .frame(width: 47, height: 32)
      }
      .disabled(!model.settings.canGrowFont)
    }
    .buttonStyle(.plain)
    .background(.quaternary, in: .capsule)
    // Without `.contain`, iOS merges the two plain buttons into one element and XCUITest
    // finds no buttons.
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func row(
    _ title: String,
    selected: Bool,
    font: Font? = nil,
    @ViewBuilder accessory: () -> some View = { EmptyView() }
  ) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.primary)
        .font(font)
      Spacer()
      accessory()
      // Always laid out, so the swatch column does not shift when a row is selected.
      Image(systemName: "checkmark")
        .foregroundStyle(.tint)
        .opacity(selected ? 1 : 0)
        .accessibilityHidden(true)
    }
    .contentShape(.rect)
    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
  }

  /// A font's name in its own face.
  private func rowFont(_ font: TerminalFont) -> Font {
    if let name = font.systemFontName {
      return .custom(name, size: 17, relativeTo: .body)
    }
    return .system(size: 17, design: .monospaced)
  }

  private func swatch(_ theme: Theme) -> some View {
    let palette = theme.palette(for: colorScheme == .dark ? .dark : .light)
    return HStack(spacing: 2) {
      // Red, green, blue and the surface: enough to tell themes apart.
      ForEach([1, 2, 4], id: \.self) { slot in
        RoundedRectangle(cornerRadius: 2).fill(palette.ansi[slot].swiftUIColor)
      }
      RoundedRectangle(cornerRadius: 2)
        .fill(palette.background.swiftUIColor)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.quaternary))
    }
    .frame(width: 64, height: 16)
  }

  /// A neutral `$` prompt whose sample touches all six chromatic ANSI slots and the cursor,
  /// so themes that share a red or a blue still look different.
  ///
  /// Multi-coloured lines interpolate styled `Text` values. `Text` concatenation with `+` is
  /// deprecated, because a fixed order can misorder right-to-left text.
  private var preview: some View {
    let dir = Text("src/ ").foregroundStyle(palette.ansi[4].swiftUIColor)
    let exe = Text("run.sh* ").foregroundStyle(palette.ansi[2].swiftUIColor)
    let link = Text("data@ ").foregroundStyle(palette.ansi[6].swiftUIColor)
    let image = Text("logo.png").foregroundStyle(palette.ansi[5].swiftUIColor)
    let modifiedMark = Text("M ").foregroundStyle(palette.ansi[3].swiftUIColor)
    let modifiedFile = Text("configs.yml").foregroundStyle(palette.foreground.swiftUIColor)
    let deletedMark = Text("D ").foregroundStyle(palette.ansi[1].swiftUIColor)
    let deletedFile = Text("legacy.rb").foregroundStyle(palette.foreground.swiftUIColor)
    let cursorPrompt = Text("$ ").foregroundStyle(palette.foreground.swiftUIColor)
    let cursorBlock = Text("█").foregroundStyle(palette.cursor.swiftUIColor)

    return VStack(alignment: .leading, spacing: 2) {
      Text("$ ls")
        .foregroundStyle(palette.foreground.swiftUIColor)
      Text("\(dir)\(exe)\(link)\(image)")
      Text("$ git status -s")
        .foregroundStyle(palette.foreground.swiftUIColor)
      Text("\(modifiedMark)\(modifiedFile)")
      Text("\(deletedMark)\(deletedFile)")
      Text("\(cursorPrompt)\(cursorBlock)")
    }
    .font(previewFont)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(palette.background.swiftUIColor, in: .rect(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("settings.preview")
  }

  private var previewFont: Font {
    let size = model.settings.fontSize
    if let name = model.settings.font.systemFontName {
      return .custom(name, fixedSize: size)
    }
    return .system(size: size, design: .monospaced)
  }
}

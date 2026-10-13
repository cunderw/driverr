import DriverrCore
import Observation
import SwiftUI

/// One install sheet's state: what the host has, and what the install did.
///
/// Nothing here keeps or logs the settings file. `HookInstaller` reads, edits and writes it
/// in one call and returns only a status or a failure.
@MainActor
@Observable
final class HookInstallModel {
  enum Phase: Equatable {
    case checking
    /// No link to the host, so nothing can be read or written.
    case notConnected
    case checked(AgentIntegrationStatus)
    case checkFailed(String)
    case installing
    case finished(HookInstallOutcome)
    case failed(message: String, isRetryable: Bool)
  }

  let hostID: DriverrCore.Host.ID
  let hostName: String
  let integration: AgentIntegration
  private(set) var phase: Phase = .checking

  /// Resolved per call, so an install after a reconnect uses the link that is up now.
  @ObservationIgnored private let runners: @MainActor () -> HookInstallRunners?
  @ObservationIgnored private let store: any HookOfferStore

  init(
    hostID: DriverrCore.Host.ID,
    hostName: String,
    integration: AgentIntegration,
    store: any HookOfferStore,
    runners: @escaping @MainActor () -> HookInstallRunners?
  ) {
    self.hostID = hostID
    self.hostName = hostName
    self.integration = integration
    self.store = store
    self.runners = runners
  }

  /// Reads where the host stands, for the sheet's first line.
  func check() async {
    guard let runners = runners() else {
      phase = .notConnected
      return
    }
    phase = .checking
    switch await HookInstaller.status(of: integration, run: runners.run) {
    case .success(let status): phase = .checked(status)
    case .failure(let error): phase = .checkFailed(error.message(for: integration))
    }
  }

  /// Reads the file again, adds the hooks and writes it back. Try Again is this same call.
  func install() async {
    guard let runners = runners() else {
      phase = .notConnected
      return
    }
    phase = .installing
    switch await HookInstaller.install(integration, run: runners.run, write: runners.write) {
    case .success(let outcome):
      await store.setState(.installed(version: integration.version), forHost: hostID, agent: integration.agent)
      phase = .finished(outcome)
    case .failure(let error):
      phase = .failed(message: error.message(for: integration), isRetryable: error.isRetryable)
    }
  }

  /// Not Now on the connect-time offer: that host is not asked again on connect.
  func decline() async {
    await store.setState(.declined, forHost: hostID, agent: integration.agent)
  }

  var isBusy: Bool { phase == .checking || phase == .installing }

  /// Nothing is left to do: installed, already there, or no link. The sheet offers Done.
  var isSettled: Bool {
    switch phase {
    case .finished, .checked(.installed), .notConnected: true
    default: false
    }
  }

  /// Whether Install is the next thing to do.
  var canInstall: Bool {
    switch phase {
    case .checked(let status): status != .installed
    case .checkFailed: true
    default: false
    }
  }
}

/// How the sheet was opened, which decides whether leaving it records a decline.
enum HookInstallSource {
  /// Offered on connect. Not Now records a decline.
  case offer
  /// Install Driverr Hooks from a menu. Leaving records nothing.
  case menu
}

/// The overview of what Driverr's hooks do, the way to the full command, and the install.
///
/// Presented by `ContentView`'s root for both entry points. The connect-time offer belongs
/// to a connection, and the menu item sits on a host row and the iPad's detail column,
/// neither of which may present.
struct HookInstallSheet: View {
  @State var model: HookInstallModel
  let source: HookInstallSource
  var isRegularWidth = false

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          statusRow
        }
        Section {
          ForEach(model.integration.hooks) { hook in
            VStack(alignment: .leading, spacing: 4) {
              Text(hook.title)
                .font(.headline)
              Text(hook.purpose)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hooks.hook")
          }
        } header: {
          Text("What Driverr adds")
        } footer: {
          Text(
            "Driverr adds this to \(model.integration.displayPath) on \(model.hostName). The rest of the file stays as it is."
          )
        }
        Section {
          NavigationLink {
            HookCommandView(display: HookInstallCommands.display(for: model.integration))
          } label: {
            Label("View Full Command", systemImage: "terminal")
          }
          .accessibilityIdentifier("hooks.viewCommand")
        }
        actionSection
      }
      .fittedSheetHeight(isEnabled: isRegularWidth)
      .navigationTitle("Driverr Hooks")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
      .task { await model.check() }
    }
    // A decline is a button, never a swipe: a swipe records the offer as asked, so this
    // version is not offered again on connect, and the menu still works. Blocked only while
    // a write is out.
    .interactiveDismissDisabled(model.phase == .installing)
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if model.isSettled {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
          // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
          .tint(Color.primary)
          .accessibilityIdentifier("hooks.done")
      }
    } else {
      ToolbarItem(placement: .cancellationAction) {
        switch source {
        case .offer:
          Button("Not Now") {
            Task {
              await model.decline()
              dismiss()
            }
          }
          .disabled(model.phase == .installing)
          .tint(Color.primary)
          .accessibilityIdentifier("hooks.notNow")
        case .menu:
          Button("Cancel") { dismiss() }
            .disabled(model.phase == .installing)
            .tint(Color.primary)
            .accessibilityIdentifier("hooks.cancel")
        }
      }
    }
  }

  @ViewBuilder
  private var actionSection: some View {
    switch model.phase {
    case .failed(_, let isRetryable) where isRetryable:
      Section {
        installButton("Try Again")
      }
    case .failed, .checkFailed:
      Section {
        installButton("Install")
      }
    default:
      if model.canInstall || model.phase == .installing {
        Section {
          installButton("Install")
        }
      }
    }
  }

  private func installButton(_ title: String) -> some View {
    Button {
      Task { await model.install() }
    } label: {
      HStack {
        Spacer()
        if model.phase == .installing {
          ProgressView()
        } else {
          ProminentButtonLabel(title)
        }
        Spacer()
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(model.isBusy)
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .accessibilityIdentifier("hooks.install")
  }

  /// One line that says where the host stands, or what the install did.
  @ViewBuilder
  private var statusRow: some View {
    let host = model.hostName
    let name = model.integration.displayName
    switch model.phase {
    case .checking:
      Label {
        Text("Checking \(host)…")
      } icon: {
        ProgressView()
      }
      .accessibilityIdentifier("hooks.checking")
    case .installing:
      Label {
        Text("Installing on \(host)…")
      } icon: {
        ProgressView()
      }
      .accessibilityIdentifier("hooks.installing")
    case .notConnected:
      statusLabel(
        "Connect to \(host) to install the hooks.", systemImage: "bolt.horizontal.circle",
        identifier: "hooks.notConnected")
    case .checked(.absent):
      statusLabel(
        "\(host) does not have Driverr’s hooks for \(name).", systemImage: "info.circle",
        identifier: "hooks.absent")
    case .checked(.outdated):
      statusLabel(
        "\(host) has an older version of Driverr’s hooks for \(name). Install replaces it.",
        systemImage: "arrow.up.circle", identifier: "hooks.outdated")
    case .checked(.installed):
      statusLabel(
        "Driverr’s hooks for \(name) are installed on \(host).", systemImage: "checkmark.circle",
        identifier: "hooks.installed")
    case .finished(.installed):
      let path = model.integration.displayPath
      statusLabel(
        "Installed on \(host). If \(path) existed before, that version is saved as \(path).driverr-backup.",
        systemImage: "checkmark.circle", identifier: "hooks.result")
    case .finished(.alreadyInstalled):
      statusLabel(
        "Driverr’s hooks for \(name) were already installed on \(host). Nothing was changed.",
        systemImage: "checkmark.circle", identifier: "hooks.result")
    case .checkFailed(let message), .failed(let message, _):
      statusLabel(
        message, systemImage: "exclamationmark.triangle", identifier: "hooks.failure", iconStyle: .orange)
    }
  }

  /// `iconStyle` `nil` keeps the ambient tint, the theme accent.
  private func statusLabel(
    _ text: String, systemImage: String, identifier: String, iconStyle: Color? = nil
  ) -> some View {
    Label {
      Text(text)
    } icon: {
      if let iconStyle {
        Image(systemName: systemImage).foregroundStyle(iconStyle)
      } else {
        Image(systemName: systemImage)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }
}

/// "View Full Command": the shell steps and the JSON added, never the user's file.
///
/// Built from `HookInstallCommands.display(for:)`, which takes no file, so no value from the
/// host's settings can reach this screen.
struct HookCommandView: View {
  let display: HookCommandDisplay

  var body: some View {
    List {
      Section {
        code(display.readCommand, identifier: "hooks.command.read")
      } header: {
        Text("1. Read the settings file and its checksum")
      }
      Section {
        code(display.addedJSON, identifier: "hooks.command.added")
      } header: {
        Text("2. Driverr adds this entry on your device")
      } footer: {
        Text(display.note)
      }
      Section {
        code(display.writeCommand, identifier: "hooks.command.write")
      } header: {
        Text("3. Write it back")
      } footer: {
        Text(display.writeNote)
      }
    }
    .navigationTitle("Full Command")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// **Never soft-wrapped.** A line break is a command separator in `sh`, so a wrapped line
  /// shows a different script from the one that runs. Long lines scroll sideways instead.
  private func code(_ text: String, identifier: String) -> some View {
    HookCodeBlock(text: text, identifier: identifier)
  }
}

/// One block of the command view, scrolling sideways, with a fade at the trailing edge
/// while more of it is off screen.
///
/// The fade is needed: a line cut at a word boundary can look complete while the part off
/// screen is what a reader checks. It shows only while content lies past the trailing edge.
private struct HookCodeBlock: View {
  let text: String
  let identifier: String
  @State private var isClippedAtTrailingEdge = false

  /// About the width of two monospaced footnote characters.
  private static let fadeWidth: CGFloat = 24

  var body: some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(.footnote.monospaced())
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
        .accessibilityIdentifier(identifier)
    }
    .scrollIndicatorsFlash(onAppear: true)
    .onScrollGeometryChange(for: Bool.self) { geometry in
      geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
    } action: { _, clipped in
      isClippedAtTrailingEdge = clipped
    }
    .mask {
      HStack(spacing: 0) {
        Rectangle()
        LinearGradient(
          colors: [.black, isClippedAtTrailingEdge ? .clear : .black],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: Self.fadeWidth)
      }
    }
  }
}

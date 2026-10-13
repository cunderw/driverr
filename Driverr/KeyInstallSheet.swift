import DriverrCore
import DriverrSSH
import Observation
import SwiftUI

/// One key install sheet's state: which key, what the install did, whether the key logs in,
/// and whether the host now uses it.
///
/// The key is tested before it is offered. A 0 exit proves the line is in
/// `~/.ssh/authorized_keys`, not that sshd reads that file: `AuthorizedKeysFile` can point
/// elsewhere, and `StrictModes` refuses a file with loose modes. So a second connection logs
/// in with the key, and Use This Key is offered only if that worked.
@MainActor
@Observable
final class KeyInstallModel {
  enum Phase: Equatable {
    /// Choosing a key, before the install.
    case choosing
    /// No link to the host, so nothing can be written.
    case notConnected
    case installing
    /// The key is on the host, and a second connection is logging in with it.
    case checkingLogin(KeyInstallOutcome)
    /// The key is on the host and logs in. Use This Key is offered.
    case loginWorked(KeyInstallOutcome)
    /// The key is on the host and did not log in. The host keeps its password.
    case loginFailed(KeyInstallOutcome, message: String)
    /// The install did not happen.
    case failed(String)
    case switching
    /// The host now uses the key. `passwordDeleted` says whether a saved password was
    /// removed, and `warning` is set when one could not be.
    case switched(passwordDeleted: Bool, warning: String?)
    case switchFailed(String)
  }

  let hostID: DriverrCore.Host.ID
  let hostName: String
  private(set) var phase: Phase = .choosing
  private(set) var identities: [SSHIdentity] = []
  var selectedID: SSHIdentity.ID?
  /// Why loading or generating a key failed, shown under the key list.
  private(set) var keyError: String?
  private(set) var isGenerating = false

  @ObservationIgnored private let identityStore: any IdentityStore
  /// Resolved per call, so an install after a reconnect uses the link that is up now.
  @ObservationIgnored private let runner: @MainActor () -> CommandRunner?
  /// Logs in to the host with the key on a connection of its own. `nil` means it worked.
  @ObservationIgnored private let checkLogin: @MainActor (SSHIdentity) async -> AppError?
  @ObservationIgnored private let hosts: HostListModel
  @ObservationIgnored private let credentials: PasswordCredentials

  init(
    hostID: DriverrCore.Host.ID,
    hostName: String,
    identityStore: any IdentityStore,
    hosts: HostListModel,
    credentials: PasswordCredentials,
    runner: @escaping @MainActor () -> CommandRunner?,
    checkLogin: @escaping @MainActor (SSHIdentity) async -> AppError?
  ) {
    self.hostID = hostID
    self.hostName = hostName
    self.identityStore = identityStore
    self.hosts = hosts
    self.credentials = credentials
    self.runner = runner
    self.checkLogin = checkLogin
  }

  var selectedIdentity: SSHIdentity? {
    identities.first { $0.id == selectedID }
  }

  /// Loads the keys and picks the newest, unless one is already picked.
  func load() async {
    do {
      identities = try await identityStore.identities()
      keyError = nil
    } catch {
      keyError = (error as? AppError)?.errorDescription ?? "Driverr could not read its keys."
    }
    if selectedIdentity == nil { selectedID = identities.first?.id }
  }

  /// Makes a new Ed25519 key, as the Keys screen does, and picks it.
  func generate() async {
    isGenerating = true
    defer { isGenerating = false }
    let generated = SSHKeyGenerator.generateEd25519(name: IdentityListModel.defaultKeyName())
    do {
      try await identityStore.add(generated.identity, privateKey: generated.privateKey)
    } catch {
      keyError = (error as? AppError)?.errorDescription ?? "Driverr could not make a key."
      return
    }
    await load()
    selectedID = generated.identity.id
  }

  /// Adds the chosen key to the host, then logs in with it. Try Again is this same call.
  func install() async {
    guard let identity = selectedIdentity else { return }
    guard let run = runner() else {
      phase = .notConnected
      return
    }
    phase = .installing
    switch await AuthorizedKeyInstaller.install(identity, run: run) {
    case .failure(let error):
      phase = .failed(error.message)
    case .success(let outcome):
      phase = .checkingLogin(outcome)
      if let error = await checkLogin(identity) {
        phase = .loginFailed(outcome, message: Self.loginFailure(error))
      } else {
        phase = .loginWorked(outcome)
      }
    }
  }

  /// Use This Key: the host logs in with the key from now on, and its saved password is
  /// deleted.
  ///
  /// The host is saved first. A password that cannot be deleted after that is a warning,
  /// because the host has already switched.
  func useKey() async {
    // `.switchFailed` offers the same button again, as a retry.
    guard let identity = selectedIdentity, offersUseKey else { return }
    phase = .switching
    await hosts.load()
    guard var host = hosts.hosts.first(where: { $0.id == hostID }) else {
      phase = .switchFailed("\(hostName) is no longer in the host list.")
      return
    }
    host.authMethod = .identity(identity.id)
    await hosts.save(host)
    guard hosts.hosts.first(where: { $0.id == hostID })?.authMethod == .identity(identity.id) else {
      phase = .switchFailed(hosts.errorMessage ?? "Driverr could not save \(hostName).")
      return
    }
    let hadPassword = ((try? await credentials.saved(for: hostID)) ?? nil) != nil
    do {
      try await credentials.forget(for: hostID)
      phase = .switched(passwordDeleted: hadPassword, warning: nil)
    } catch {
      phase = .switched(
        passwordDeleted: false,
        warning: "Driverr could not delete the saved password for \(hostName). It is still on this device.")
    }
  }

  /// Why the test login failed. A refused key gets its likely causes instead of the connect
  /// screen's "Check the username and credentials", which is wrong advice here.
  static func loginFailure(_ error: AppError) -> String {
    if case .authenticationFailed = error {
      return "The host refused the key. Its sshd may read keys from another file than ~/.ssh/authorized_keys, or refuse the file because of its permissions."
    }
    return error.errorDescription ?? "The login was refused."
  }

  var isBusy: Bool {
    switch phase {
    case .installing, .checkingLogin, .switching: true
    default: false
    }
  }

  /// Whether the key list and Install are on screen.
  var isChoosing: Bool {
    switch phase {
    case .choosing, .failed: true
    default: false
    }
  }

  /// Whether the install has done its work, so the sheet offers Done instead of Cancel.
  var isSettled: Bool {
    switch phase {
    case .loginWorked, .loginFailed, .switched, .switchFailed, .notConnected: true
    default: false
    }
  }
}

/// The second connection that tests an installed key.
///
/// Uses its own transport and coordinator, never the host's `ConnectionModel`: a connect
/// through the model retires the link the install used.
enum KeyLoginCheck {
  static func run(
    host: DriverrCore.Host,
    identity: SSHIdentity,
    environment: AppEnvironment
  ) async -> AppError? {
    let key: SSHPrivateKey
    do {
      key = try await environment.identityStore.privateKey(for: identity.id)
    } catch {
      return error as? AppError ?? .keyImportFailed(reason: "That key is no longer available.")
    }
    let coordinator = ConnectionCoordinator(transport: environment.makeTransport())
    let validator = TOFUHostKeyValidator(store: environment.knownHostsStore, prompt: RefusingHostKeyPrompt())
    do {
      try await coordinator.connect(to: host, validator: validator, credential: .privateKey(key))
      await coordinator.disconnect()
      return nil
    } catch {
      await coordinator.disconnect()
      return error as? AppError
        ?? .connectionFailed(host: host.hostname, reason: "The connection could not be established.")
    }
  }
}

/// The key check's host key prompt, which never trusts a key. The host's key is already
/// trusted, so an unknown one is not something to ask about mid-check.
private struct RefusingHostKeyPrompt: HostKeyPrompt {
  func askToTrust(_ key: SSHHostKey, for host: DriverrCore.Host) async -> Bool { false }
}

/// Install a Key: puts one of Driverr's public keys in the host's `authorized_keys`, tests
/// it, and offers to switch the host to it.
///
/// Presented by `ContentView`'s root, because its entry is on the host screen, which is the
/// iPad's detail column, where nothing may present.
struct KeyInstallSheet: View {
  @State var model: KeyInstallModel
  var isRegularWidth = false

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themeAccent) private var themeAccent

  var body: some View {
    NavigationStack {
      List {
        Section {
          statusRow
        }
        if !model.isChoosing, let identity = model.selectedIdentity {
          // Which key the result is about, once the list has gone. It also keeps the iPad's
          // fitted card above `SheetContentHeight.minimum`; a lone status row falls under it
          // and the card reverts to full height.
          Section {
            keyLabel(identity)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("keyInstall.chosenKey")
          } header: {
            Text("Key")
          }
        }
        if model.isChoosing {
          keySection
          Section {
            actionButton(model.phase == .choosing ? "Install" : "Try Again", identifier: "keyInstall.install") {
              await model.install()
            }
            .disabled(model.selectedIdentity == nil || model.isGenerating)
          }
        }
        if model.phase == .installing || model.isCheckingLogin {
          Section {
            actionButton("Install", identifier: "keyInstall.install") {}
              .disabled(true)
          }
        }
        if model.offersUseKey {
          useKeySection
        }
        if model.phase == .switching {
          Section {
            actionButton("Use This Key", identifier: "keyInstall.useKey") {}
              .disabled(true)
          }
        }
      }
      .fittedSheetHeight(isEnabled: isRegularWidth)
      .navigationTitle("Install a Key")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbar }
      .task { await model.load() }
    }
    .interactiveDismissDisabled(model.isBusy)
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if model.offersUseKey {
      // Not Now, never Done, while Use This Key is offered: Done in the confirming slot reads
      // as accepting the offer.
      ToolbarItem(placement: .cancellationAction) {
        Button("Not Now") { dismiss() }
          .tint(Color.primary)
          .accessibilityIdentifier("keyInstall.notNow")
      }
    } else if model.isSettled {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
          // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
          .tint(Color.primary)
          .accessibilityIdentifier("keyInstall.done")
      }
    } else {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .disabled(model.isBusy)
          .tint(Color.primary)
          .accessibilityIdentifier("keyInstall.cancel")
      }
    }
  }

  /// The keys to choose from, and a way to make one.
  @ViewBuilder
  private var keySection: some View {
    Section {
      ForEach(model.identities) { identity in
        Button {
          model.selectedID = identity.id
        } label: {
          HStack {
            keyLabel(identity)
            Spacer()
            if identity.id == model.selectedID {
              Image(systemName: "checkmark")
                .foregroundStyle(themeAccent)
                .fontWeight(.semibold)
            }
          }
        }
        .accessibilityAddTraits(identity.id == model.selectedID ? .isSelected : [])
        .accessibilityIdentifier("keyInstall.key")
      }
      Button {
        Task { await model.generate() }
      } label: {
        Label("Generate a New Key", systemImage: "plus.circle")
      }
      .disabled(model.isGenerating)
      .accessibilityIdentifier("keyInstall.generate")
    } header: {
      Text("Key")
    } footer: {
      VStack(alignment: .leading, spacing: 8) {
        if let error = model.keyError {
          Text(error)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("keyInstall.keyError")
        }
        Text(
          "Driverr adds the public key to ~/.ssh/authorized_keys on \(model.hostName). The rest of the file stays as it is."
        )
      }
    }
  }

  private func keyLabel(_ identity: SSHIdentity) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(identity.name)
        .foregroundStyle(Color.primary)
      Text(identity.fingerprint)
        .font(.caption.monospaced())
        // `Color.secondary`, not `.secondary`: inside a `Button` the hierarchical style is
        // taken from the tint, and the fingerprint drew in the accent.
        .foregroundStyle(Color.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var useKeySection: some View {
    Section {
      actionButton("Use This Key", identifier: "keyInstall.useKey") {
        await model.useKey()
      }
    } footer: {
      Text(
        "\(model.hostName) will log in with \(model.selectedIdentity?.name ?? "this key") from now on, and Driverr deletes any password it saved for \(model.hostName). The connection that is up now keeps going."
      )
    }
  }

  private func actionButton(
    _ title: String, identifier: String, action: @escaping @MainActor () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      HStack {
        Spacer()
        if model.isBusy {
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
    .accessibilityIdentifier(identifier)
  }

  /// One line that says what the sheet is about to do, or what it did.
  @ViewBuilder
  private var statusRow: some View {
    let host = model.hostName
    switch model.phase {
    case .choosing:
      statusLabel(
        "Install one of Driverr’s keys on \(host), so Driverr can log in without the password.",
        systemImage: "key", identifier: "keyInstall.intro")
    case .notConnected:
      statusLabel(
        "Connect to \(host) to install a key.", systemImage: "bolt.horizontal.circle",
        identifier: "keyInstall.notConnected")
    case .installing:
      progressLabel("Installing on \(host)…", identifier: "keyInstall.installing")
    case .checkingLogin:
      progressLabel("Logging in to \(host) with the key…", identifier: "keyInstall.checking")
    case .loginWorked(.installed):
      statusLabel(
        "Installed on \(host). A test login with the key worked.",
        systemImage: "checkmark.circle", identifier: "keyInstall.result")
    case .loginWorked(.alreadyInstalled):
      statusLabel(
        "The key was already on \(host), so nothing was changed. A test login with it worked.",
        systemImage: "checkmark.circle", identifier: "keyInstall.result")
    case .loginFailed(let outcome, let message):
      statusLabel(
        (outcome == .installed ? "Installed on \(host), but" : "The key is on \(host), but")
          + " a test login with it failed. \(host) keeps using the password. \(message)",
        systemImage: "exclamationmark.triangle", identifier: "keyInstall.loginFailed", iconStyle: .orange)
    case .failed(let message), .switchFailed(let message):
      statusLabel(
        message, systemImage: "exclamationmark.triangle", identifier: "keyInstall.failure", iconStyle: .orange)
    case .switching:
      progressLabel("Switching \(host) to the key…", identifier: "keyInstall.switching")
    case .switched(let passwordDeleted, let warning):
      let name = model.selectedIdentity?.name ?? "the key"
      if let warning {
        statusLabel(
          "\(host) now logs in with \(name). \(warning)", systemImage: "exclamationmark.triangle",
          identifier: "keyInstall.switched", iconStyle: .orange)
      } else {
        statusLabel(
          "\(host) now logs in with \(name)."
            + (passwordDeleted ? " Driverr deleted the password it saved for \(host)." : ""),
          systemImage: "checkmark.circle", identifier: "keyInstall.switched")
      }
    }
  }

  private func progressLabel(_ text: String, identifier: String) -> some View {
    Label {
      Text(text)
    } icon: {
      ProgressView()
    }
    .accessibilityIdentifier(identifier)
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

extension KeyInstallModel {
  /// Whether Use This Key is on screen: after a login that worked, and again after a switch
  /// that failed.
  var offersUseKey: Bool {
    switch phase {
    case .loginWorked, .switchFailed: true
    default: false
    }
  }

  var isCheckingLogin: Bool {
    if case .checkingLogin = phase { return true }
    return false
  }
}

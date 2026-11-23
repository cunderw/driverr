import DriverrCore
import DriverrSSH
import SwiftUI

/// Add or edit a host.
struct AddHostView: View {
  @Environment(\.appEnvironment) private var environment
  @Environment(\.dismiss) private var dismiss

  let existing: DriverrCore.Host?
  /// Whether this sheet has room to be a form sheet.
  ///
  /// Passed in by `ContentView`, not read here: an iPad form sheet's own
  /// `horizontalSizeClass` reads compact, so a branch taken inside this view would pick the
  /// phone layout. `PaneSheetView.isRegularWidth` does the same.
  var isRegularWidth = false
  let onSave: (DriverrCore.Host) -> Void

  @State private var name = ""
  @State private var hostname = ""
  @State private var port = "22"
  @State private var username = ""
  @State private var signIn = SignIn.password
  @State private var selectedIdentity: UUID?
  @State private var herdrSocketPath = ""
  @State private var identities: [SSHIdentity] = []
  @State private var generateKeyError: String?

  /// How the host signs in, as the form offers it. `makeHost()` turns it into a
  /// `HostAuthMethod`.
  private enum SignIn: Hashable, CaseIterable {
    case password, key, tailscale

    var title: String {
      switch self {
      case .password: "Password"
      case .key: "Key"
      // Named for the one server Driverr knows takes no credential. "None" alone would read
      // as "no security".
      case .tailscale: "Tailscale SSH (no password)"
      }
    }
  }

  private enum Field: Hashable {
    case name, hostname, port, username
  }
  @FocusState private var focusedField: Field?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name (optional)", text: $name)
            .submitLabel(.next)
            .focused($focusedField, equals: .name)
            .onSubmit { focusedField = .hostname }
            .accessibilityIdentifier("host.name")
          TextField("Hostname or IP", text: $hostname)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.next)
            .focused($focusedField, equals: .hostname)
            .onSubmit { focusedField = .port }
            // Split a pasted `user@host:port` into its three fields.
            .onChange(of: hostname) { _, newValue in applyPastedConnectionString(newValue) }
            .accessibilityIdentifier("host.hostname")
          LabeledContent("Port") {
            TextField("22", text: $port)
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .submitLabel(.next)
              .focused($focusedField, equals: .port)
              .onSubmit { focusedField = .username }
              .accessibilityIdentifier("host.port")
          }
          TextField("Username", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .textContentType(.username)
            .submitLabel(.done)
            .focused($focusedField, equals: .username)
            .onSubmit { focusedField = nil }
            .accessibilityIdentifier("host.username")
        } header: {
          Text("Host")
        } footer: {
          // A footer, not a row: a row inside the card reads as a field to fill in.
          Text("Port must be between 1 and 65535.")
        }

        Section {
          Picker("Sign In", selection: $signIn) {
            ForEach(SignIn.allCases, id: \.self) { choice in
              Text(choice.title).tag(choice)
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("host.signIn")
          .onChange(of: signIn) { _, choice in
            // Default to the first key. An unset picker would save the host as password auth.
            if choice == .key, selectedIdentity == nil { selectedIdentity = identities.first?.id }
          }

          if signIn == .key {
            if let selectedIdentity, !identities.contains(where: { $0.id == selectedIdentity }) {
              // The selected identity was deleted from the Keys screen. Without this the picker
              // looks the same as "no key chosen yet".
              Text("The key this host used was deleted.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("host.keyDeleted")
            }

            if identities.isEmpty {
              Text("No keys yet. Generate one below, or from the Keys screen.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("host.noKeys")
            } else {
              Picker("Key", selection: $selectedIdentity) {
                ForEach(identities) { identity in
                  Text(identity.name).tag(Optional(identity.id))
                }
              }
              .accessibilityIdentifier("host.keyPicker")
            }

            Button {
              Task { await generateKey() }
            } label: {
              Label("Generate a Key", systemImage: "key")
            }
            .accessibilityIdentifier("host.generateKey")
          }
        } header: {
          Text("Authentication")
        } footer: {
          // A footer for the reason the port hint is. None for a key, which needs no word.
          switch signIn {
          case .password:
            Text("You'll be asked for a password when connecting.")
          case .tailscale:
            Text(
              "Tailscale signs you in with your tailnet identity. If the host asks you to "
                + "sign in again, Driverr shows the link while it waits."
            )
          case .key:
            EmptyView()
          }
        }

        Section {
          TextField("herdr socket path (optional)", text: $herdrSocketPath)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("host.herdrSocket")
        } header: {
          Text("herdr")
        } footer: {
          Text(
            "Leave empty to use herdr's default socket. Set this only if herdr listens "
              + "somewhere else on this host — Driverr passes it as HERDR_SOCKET_PATH."
          )
        }
      }
      // On a 13-inch iPad this form is taller than the platform's card, so shrink-only
      // changes nothing today. It is applied because the height depends on text size and
      // on the key rows. See `FittedSheetHeight`.
      .fittedSheetHeight(isEnabled: isRegularWidth)
      .navigationTitle(existing == nil ? "Add Host" : "Edit Host")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .tint(Color.primary)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(makeHost())
            dismiss()
          }
          .disabled(!isValid)
          // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
          .tint(Color.primary)
          .accessibilityIdentifier("host.save")
        }
      }
      .task {
        identities = (try? await environment.identityStore.identities()) ?? []
        if let existing { fill(from: existing) }
      }
      .alert(
        "Couldn't Generate a Key",
        isPresented: Binding(
          get: { generateKeyError != nil },
          set: { if !$0 { generateKeyError = nil } }
        )
      ) {
        Button("OK", role: .cancel) { generateKeyError = nil }
      } message: {
        Text(generateKeyError ?? "")
      }
    }
  }

  private var isValid: Bool {
    guard !hostname.trimmingCharacters(in: .whitespaces).isEmpty,
      !username.trimmingCharacters(in: .whitespaces).isEmpty,
      let portValue = Int(port), (1...65535).contains(portValue)
    else { return false }
    if signIn == .key {
      // Invalid while there is no selection or the selected identity is gone, so the host
      // is never saved as password auth by accident.
      guard let selectedIdentity, identities.contains(where: { $0.id == selectedIdentity })
      else { return false }
    }
    return true
  }

  private func fill(from host: DriverrCore.Host) {
    name = host.name
    hostname = host.hostname
    port = String(host.port)
    username = host.username
    herdrSocketPath = host.herdrSocketPath ?? ""
    switch host.authMethod {
    case .identity(let id):
      signIn = .key
      selectedIdentity = id
    case .password:
      signIn = .password
    case .none:
      signIn = .tailscale
    }
  }

  private func makeHost() -> DriverrCore.Host {
    let socket = herdrSocketPath.trimmingCharacters(in: .whitespaces)
    return DriverrCore.Host(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      hostname: hostname.trimmingCharacters(in: .whitespaces),
      port: Int(port) ?? 22,
      username: username.trimmingCharacters(in: .whitespaces),
      authMethod: authMethod,
      herdrSocketPath: socket.isEmpty ? nil : socket
    )
  }

  private var authMethod: HostAuthMethod {
    switch signIn {
    case .password: .password
    // `isValid` keeps Save off without a selection, so the fallback is never saved.
    case .key: selectedIdentity.map { .identity($0) } ?? .password
    case .tailscale: .none
    }
  }

  /// Generates a key and selects it, as `IdentityListModel.generate()` does on the Keys
  /// screen, so the user does not have to leave the form.
  private func generateKey() async {
    let generated = SSHKeyGenerator.generateEd25519(name: IdentityListModel.defaultKeyName())
    do {
      try await environment.identityStore.add(generated.identity, privateKey: generated.privateKey)
      identities = (try? await environment.identityStore.identities()) ?? []
      selectedIdentity = generated.identity.id
    } catch {
      generateKeyError = (error as? AppError)?.errorDescription ?? "Something went wrong."
    }
  }

  /// Splits a pasted `user@host` or `user@host:port` into the form's three fields.
  ///
  /// Only acts on a `@` with text on both sides, so ordinary typing is untouched.
  private func applyPastedConnectionString(_ text: String) {
    guard let parsed = Self.parseConnectionString(text) else { return }
    username = parsed.username
    hostname = parsed.hostname
    if let parsedPort = parsed.port { port = String(parsedPort) }
  }

  static func parseConnectionString(
    _ text: String
  ) -> (username: String, hostname: String, port: Int?)? {
    guard let atIndex = text.firstIndex(of: "@") else { return nil }
    let user = String(text[..<atIndex])
    var rest = String(text[text.index(after: atIndex)...])
    guard !user.isEmpty, !rest.isEmpty else { return nil }

    var port: Int?
    if let colonIndex = rest.firstIndex(of: ":") {
      let portFragment = String(rest[rest.index(after: colonIndex)...])
      // A colon without a valid port after it stays part of the hostname.
      if let parsedPort = Int(portFragment), (1...65535).contains(parsedPort) {
        port = parsedPort
        rest = String(rest[..<colonIndex])
      }
    }
    guard !rest.isEmpty else { return nil }
    return (user, rest, port)
  }
}

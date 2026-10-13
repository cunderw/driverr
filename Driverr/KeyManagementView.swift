import DriverrCore
import SwiftUI

/// Lists the user's SSH identities, and creates, imports, and deletes them.
///
/// Plain on purpose: system colours and only the three actions.
struct KeyManagementView: View {
  @Environment(\.appEnvironment) private var environment
  @Environment(\.dismiss) private var dismiss

  @State private var model: IdentityListModel?
  @State private var isImporting = false
  @State private var pastedKey = ""
  @State private var pendingDelete: SSHIdentity?
  @State private var hostsUsingPendingDelete: [String] = []

  var body: some View {
    NavigationStack {
      Group {
        if let model {
          content(for: model)
        } else {
          ProgressView()
        }
      }
      .navigationTitle("Keys")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            // Toolbar text takes `Color.primary`. See CLAUDE.md, "Style".
            .tint(Color.primary)
            .accessibilityIdentifier("keys.done")
        }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              Task { await model?.generate() }
            } label: {
              Label("Generate a Key", systemImage: "key")
            }
            .accessibilityIdentifier("keys.generate")

            Button {
              // The sheet opens empty with a Paste button. Reading the pasteboard on the menu
              // tap would put the system paste banner up before the sheet appears.
              pastedKey = ""
              isImporting = true
            } label: {
              Label("Import Key", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("keys.import")
          } label: {
            Label("Add Key", systemImage: "plus")
          }
          .accessibilityIdentifier("keys.add")
        }
      }
      .sheet(isPresented: $isImporting) {
        ImportKeyView(pem: $pastedKey) { pem in
          Task { await model?.importKey(pem: pem) }
        }
      }
      // On the container, not on the `List` inside `content(for:)`: the likeliest first
      // import fails while the list is still empty, and an alert on the non-empty branch has
      // nowhere to render.
      //
      // If this alert seems not to appear on iPad, check the test first. The import sheet
      // slides up when the keyboard settles, so a tap can miss the Import button. See
      // `waitUntilStill` in `UITestSupport.swift`.
      .alert(
        "Key Error",
        isPresented: Binding(
          get: { model?.errorMessage != nil },
          set: { if !$0 { model?.dismissError() } }
        )
      ) {
        Button("OK", role: .cancel) { model?.dismissError() }
      } message: {
        Text(model?.errorMessage ?? "")
      }
      // On the container too, because a `List` row does not own a presentation.
      .confirmationDialog(
        "Delete Key?",
        isPresented: Binding(
          get: { pendingDelete != nil },
          set: { if !$0 { pendingDelete = nil } }
        ),
        presenting: pendingDelete
      ) { identity in
        Button("Delete", role: .destructive) {
          Task { await model?.delete(identity) }
        }
        .accessibilityIdentifier("keys.deleteConfirm")
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        if hostsUsingPendingDelete.isEmpty {
          Text("No host uses this key.")
        } else {
          Text(
            "\(hostsUsingPendingDelete.joined(separator: ", ")) "
              + (hostsUsingPendingDelete.count == 1 ? "uses" : "use")
              + " this key. Deleting it will leave "
              + (hostsUsingPendingDelete.count == 1 ? "that host" : "those hosts")
              + " unable to connect with a key."
          )
        }
      }
    }
    .task {
      if model == nil {
        model = IdentityListModel(store: environment.identityStore, hostStore: environment.hostStore)
      }
      await model?.load()
    }
  }

  @ViewBuilder
  private func content(for model: IdentityListModel) -> some View {
    if model.identities.isEmpty {
      ContentUnavailableView(
        "No Keys",
        systemImage: "key",
        description: Text("Generate a key or import one to authenticate without a password.")
      )
      .accessibilityIdentifier("keys.empty")
    } else {
      List {
        ForEach(model.identities) { identity in
          NavigationLink {
            IdentityDetailView(identity: identity)
          } label: {
            IdentityRow(identity: identity)
          }
          .accessibilityIdentifier("keys.row")
          .swipeActions {
            Button("Delete", role: .destructive) {
              Task {
                hostsUsingPendingDelete = await model.hostNames(usingKey: identity)
                pendingDelete = identity
              }
            }
            .accessibilityIdentifier("keys.delete")
          }
        }
      }
    }
  }
}

private struct IdentityRow: View {
  let identity: SSHIdentity

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(identity.name)
      // The fingerprint, not the key, because it is what a user compares and it fits on a
      // phone. `lineLimit(1)` truncates, so it avoids the hyphenation `groupedFingerprint`
      // works around.
      Text(identity.fingerprint)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

/// Shows the line to paste into a server's `authorized_keys`.
private struct IdentityDetailView: View {
  let identity: SSHIdentity
  @Environment(\.dismiss) private var dismiss
  @State private var didCopy = false

  var body: some View {
    List {
      Section {
        Text(identity.authorizedKeysLine)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
          .accessibilityIdentifier("keys.publicKey")

        Button {
          UIPasteboard.general.string = identity.authorizedKeysLine
          didCopy = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
          }
        } label: {
          Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("keys.copy")

        ShareLink(item: identity.authorizedKeysLine) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("keys.share")
      } header: {
        Text("Public Key")
      } footer: {
        Text("Add this line to ~/.ssh/authorized_keys on the host.")
      }

      Section("Fingerprint") {
        // Grouped, so SwiftUI never hyphenates it. See `groupedFingerprint`.
        Text(groupedFingerprint(identity.fingerprint))
          .font(.footnote.monospaced())
          .textSelection(.enabled)
          .speechSpellsOutCharacters()
      }

      Section("Added") {
        Text(identity.createdAt, style: .date)
      }
    }
    .navigationTitle(identity.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      // A pushed screen inside a sheet loses the sheet's Done, and Back means "show the list",
      // not "finished".
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
          .tint(Color.primary)
          .accessibilityIdentifier("keys.detailDone")
      }
    }
  }
}

private struct ImportKeyView: View {
  @Binding var pem: String
  let onImport: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $pem)
            .font(.footnote.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 200)
            .accessibilityIdentifier("keys.importField")

          Button {
            pem = UIPasteboard.general.string ?? ""
          } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
          }
          .accessibilityIdentifier("keys.importPaste")
        } header: {
          Text("OpenSSH Private Key")
        } footer: {
          // Stated up front, because the likeliest first paste is an RSA or passphrase-protected
          // key, and "invalid key" does not say what to change.
          Text("Driverr supports OpenSSH-format Ed25519 keys — the kind `ssh-keygen -t ed25519` writes.")
            .accessibilityIdentifier("keys.importFormatHint")
        }
      }
      .navigationTitle("Import Key")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .tint(Color.primary)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Import") {
            onImport(pem)
            dismiss()
          }
          .disabled(pem.isEmpty)
          .tint(Color.primary)
          .accessibilityIdentifier("keys.importConfirm")
        }
      }
    }
  }
}
